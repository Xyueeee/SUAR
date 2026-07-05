"""SUAR cloud sync bridge + admin API.

Two consumers:
  - the Helper app  -> POST /sync (unauthenticated; mesh devices have no admin login)
  - the admin web   -> /admin/* (Supabase-Auth JWT required) + public GET reads

All data is read/written here with the service-role key; the web never touches
Supabase directly except to log in. See CLAUDE.md Section 8/9/14 and
docs/superpowers/specs/2026-06-24-admin-web-design.md.
"""
import hashlib
import logging
import math
import os
import uuid

import httpx
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

from dotenv import load_dotenv
from fastapi import Body, Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from supabase import Client, ClientOptions, create_client

from models import SyncRequest, SyncResponse

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("suar-backend")

# The backend<->Supabase link on this network intermittently drops a TCP connect
# (WinError 10060 ConnectTimeout). A retrying transport re-attempts connect-level
# failures automatically (httpcore retries ConnectError/ConnectTimeout with
# backoff), so a single blip heals before any endpoint sees it — instead of
# crashing every request with a raw 500. Applies to postgrest, auth AND storage
# (supabase passes this one client to all three).
_http_client = httpx.Client(
    timeout=httpx.Timeout(connect=8.0, read=30.0, write=30.0, pool=30.0),
    transport=httpx.HTTPTransport(retries=3),  # 4 attempts total, ~0/0.5/1s backoff
)

supabase: Client = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_SECRET_KEY"),
    options=ClientOptions(httpx_client=_http_client),
)

# Emails allowed into /admin/*. A valid Supabase login is NOT enough — the anon
# key is public, so any self-registered user has a valid token. Only these
# operators are admins. Empty set => no admin access (fail closed).
ADMIN_EMAILS = {e.strip().lower() for e in os.getenv("ADMIN_EMAILS", "").split(",") if e.strip()}

app = FastAPI(title="SUAR Sync + Admin Backend")

# Dev: the static web dashboard is opened from file:// or any local host and
# talks to this API over the ngrok URL, so origins are unpredictable. We auth
# with a Bearer header (no cookies), so wildcard origins are safe here.
# For a real deployment set ALLOWED_ORIGINS in .env (comma-separated) to pin
# the console's origin(s); unset keeps the dev wildcard.
ALLOWED_ORIGINS = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(httpx.TransportError)
def _supabase_unreachable(request: Request, exc: httpx.TransportError):
    """Backstop: if a Supabase call still fails after the transport's retries,
    return a clean 502 instead of a raw 500 + full stack trace in the log. The
    app's public polls (/notices, /geofences, ...) can ignore a 502 and retry;
    nobody gets logged out over it."""
    logger.warning(f"Supabase unreachable for {request.method} {request.url.path}: {exc}")
    return JSONResponse(status_code=502, content={"detail": "Database temporarily unreachable — try again"})


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _is_newer(incoming: datetime, stored_iso: str | None) -> bool:
    """True when `incoming` is strictly newer than the stored ISO timestamp.
    Unparseable/missing stored values count as older (accept the update) —
    never let a bad row block fresher data."""
    if not stored_iso:
        return True
    try:
        stored = datetime.fromisoformat(stored_iso)
    except ValueError:
        return True
    # Treat naive timestamps (device clocks without a zone) as UTC.
    if incoming.tzinfo is None:
        incoming = incoming.replace(tzinfo=timezone.utc)
    if stored.tzinfo is None:
        stored = stored.replace(tzinfo=timezone.utc)
    return incoming > stored


def _sane_coords(lat: float | None, lng: float | None) -> tuple[float | None, float | None]:
    """Drop a fix that is out of WGS84 range (buggy/hostile client) — a bundle
    with no location is better than one that breaks the map."""
    if lat is None or lng is None:
        return None, None
    if -90 <= lat <= 90 and -180 <= lng <= 180:
        return lat, lng
    return None, None


# --------------------------------------------------------------------------- #
# Auth                                                                         #
# --------------------------------------------------------------------------- #
def require_admin(authorization: str = Header(None)):
    """Verify a Supabase Auth JWT passed as `Authorization: Bearer <token>`.

    ponytail: validates by calling GoTrue (one network round-trip per request).
    Fine at admin volume; swap to local JWT-secret (HS256) verification if
    latency ever matters.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1]
    try:
        res = supabase.auth.get_user(token)
    except httpx.TransportError as exc:
        # Backend couldn't REACH Supabase GoTrue (connect/read timeout, DNS,
        # dropped connection) even after the transport's retries. This is NOT an
        # auth failure — returning 401 here made the web sign the operator out
        # mid-edit on a transient network blip. 502 tells the client "upstream
        # is down, your session is fine".
        logger.warning(f"Auth check couldn't reach Supabase: {exc}")
        raise HTTPException(status_code=502, detail="Auth service unreachable — try again")
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    if not res or not res.user:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    # A valid token only proves "some Supabase user" — enforce the admin allowlist.
    if not ADMIN_EMAILS:
        raise HTTPException(status_code=503, detail="Admin allowlist not configured (set ADMIN_EMAILS in backend .env)")
    email = (getattr(res.user, "email", None) or "").lower()
    if email not in ADMIN_EMAILS:
        raise HTTPException(status_code=403, detail="Admin access required")
    return res.user


# --------------------------------------------------------------------------- #
# Sync (Helper app)                                                            #
# --------------------------------------------------------------------------- #
def ensure_device(
    device_id: str,
    mode: str,
    version: str | None = None,
    touch_lastseen: bool = True,
    hardware_id: str | None = None,
) -> None:
    existing = supabase.table("device").select("deviceid").eq("deviceid", device_id).execute()
    if existing.data:
        if touch_lastseen:
            # touch_lastseen=True only on the device's OWN /sync call (not the
            # relay-driven "register this bundle's owning victim" call below) —
            # mode/version can legitimately change after first registration (the
            # same device switches Victim<->Helper mode, or the app updates).
            # Without this the row stayed frozen at whatever mode it FIRST
            # registered with, so a device that started as Victim looked
            # permanently "victim" in the admin console even once it moved to
            # Helper mode and was syncing fine.
            update = {"lastseenat": _now_iso(), "applicationmode": mode}
            if version is not None:
                update["applicationversion"] = version
            if hardware_id is not None:
                update["hardwareid"] = hardware_id
            supabase.table("device").update(update).eq("deviceid", device_id).execute()
    else:
        supabase.table("device").insert(
            {
                "deviceid": device_id,
                "applicationmode": mode,
                "applicationversion": version,
                "hardwareid": hardware_id,
                "registeredat": _now_iso(),
                "lastseenat": _now_iso(),
            }
        ).execute()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/bundles")
def get_bundles():
    """Legacy public listing kept for backward compat (RLS already exposes
    these read-only). The admin web uses /admin/bundles instead."""
    result = (
        supabase.table("distressbundle")
        .select("*")
        .order("createdat", desc=True)
        .limit(100)
        .execute()
    )
    return result.data


@app.post("/sync", response_model=SyncResponse)
def sync(payload: SyncRequest):
    try:
        ensure_device(
            payload.device.deviceId,
            payload.device.applicationMode,
            payload.device.applicationVersion,
            touch_lastseen=True,
            hardware_id=payload.device.hardwareId,
        )
    except Exception as exc:
        logger.error(f"Device upsert failed for {payload.device.deviceId}: {exc}")
        raise HTTPException(status_code=500, detail="Sync failed")

    inserted = duplicates = errors = 0

    for bundle in payload.bundles:
        try:
            lat, lng = _sane_coords(bundle.estimatedLat, bundle.estimatedLng)
            existing = (
                supabase.table("distressbundle")
                .select("bundleid,updatedat")
                .eq("bundleid", bundle.bundleId)
                .execute()
            )
            if existing.data:
                # Re-sync: a bundle's triage score, tier and GPS fix are refined
                # over time, so UPDATE the existing row instead of dropping the
                # newer data as a "duplicate" (that left bundles stuck at the
                # first push's None / 0 / no-location values).
                #
                # Timestamp-based conflict resolution (FR 5.x): the same bundle
                # can arrive via multiple relay paths — a stale copy (older
                # updatedAt than what's stored) must not clobber fresher data.
                if not _is_newer(bundle.updatedAt, existing.data[0].get("updatedat")):
                    supabase.table("syncrecord").upsert(
                        {"bundleid": bundle.bundleId, "syncedat": _now_iso(), "serverstatus": "duplicate"},
                        on_conflict="bundleid",
                    ).execute()
                    duplicates += 1
                    continue
                supabase.table("distressbundle").update(
                    {
                        "priorityscore": bundle.priorityScore,
                        "prioritytier": bundle.priorityTier,
                        "estimatedlat": lat,
                        "estimatedlng": lng,
                        "accuracymeters": bundle.accuracyMeters,
                        "estimatedaltitude": bundle.estimatedAltitude,
                        "hopcount": bundle.hopCount,
                        "updatedat": bundle.updatedAt.isoformat(),
                    }
                ).eq("bundleid", bundle.bundleId).execute()
                supabase.table("syncrecord").upsert(
                    {"bundleid": bundle.bundleId, "syncedat": _now_iso(), "serverstatus": "duplicate"},
                    on_conflict="bundleid",
                ).execute()
                duplicates += 1
                continue

            ensure_device(bundle.deviceId, "victim", version="unknown", touch_lastseen=False)

            supabase.table("distressbundle").insert(
                {
                    "bundleid": bundle.bundleId,
                    "deviceid": bundle.deviceId,
                    "priorityscore": bundle.priorityScore,
                    "prioritytier": bundle.priorityTier,
                    "estimatedlat": lat,
                    "estimatedlng": lng,
                    "accuracymeters": bundle.accuracyMeters,
                    "estimatedaltitude": bundle.estimatedAltitude,
                    "hopcount": bundle.hopCount,
                    "issynced": True,
                    "createdat": bundle.createdAt.isoformat(),
                    "updatedat": bundle.updatedAt.isoformat(),
                }
            ).execute()

            if bundle.sensorReadings:
                supabase.table("sensorreading").insert(
                    [
                        {
                            "bundleid": bundle.bundleId,
                            "sensortype": r.sensorType,
                            "rawvalue": r.rawValue,
                            "normalisedvalue": r.normalisedValue,
                            "recordedat": r.recordedAt.isoformat(),
                        }
                        for r in bundle.sensorReadings
                    ]
                ).execute()

            if bundle.relayLogs:
                supabase.table("relaylog").insert(
                    [
                        {
                            "bundleid": bundle.bundleId,
                            "deviceid": r.deviceId,
                            "nexthopdeviceid": r.nextHopDeviceId,
                            "hopsequence": r.hopSequence,
                            "protocol": r.protocol,
                            "relayedat": r.relayedAt.isoformat(),
                        }
                        for r in bundle.relayLogs
                    ]
                ).execute()

            supabase.table("syncrecord").upsert(
                {"bundleid": bundle.bundleId, "syncedat": _now_iso(), "serverstatus": "success"},
                on_conflict="bundleid",
            ).execute()
            inserted += 1

        except Exception as exc:
            logger.error(f"Bundle {bundle.bundleId} failed: {exc}")
            try:
                supabase.table("syncrecord").upsert(
                    {"bundleid": bundle.bundleId, "syncedat": _now_iso(), "serverstatus": "error"},
                    on_conflict="bundleid",
                ).execute()
            except Exception as inner_exc:
                logger.error(f"Could not record error syncrecord for {bundle.bundleId}: {inner_exc}")
            errors += 1

    return SyncResponse(
        received=len(payload.bundles),
        inserted=inserted,
        duplicates=duplicates,
        errors=errors,
    )


# --------------------------------------------------------------------------- #
# Public reads (also used by the app in a later increment)                     #
# --------------------------------------------------------------------------- #
@app.get("/notices")
def public_notices():
    rows = supabase.table("notice").select("*").eq("isactive", True).order("createdat", desc=True).execute().data
    now = datetime.now(timezone.utc)

    def _unexpired(r):
        exp = r.get("expiresat")
        if not exp:
            return True
        try:
            parsed = datetime.fromisoformat(exp)
            # A naive timestamp (no zone) can't be compared to the aware `now`
            # without raising — treat it as UTC, same policy as _is_newer.
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed > now
        except (ValueError, TypeError):
            # Malformed expiry must not 500 the whole public feed; keep the row.
            return True

    return [r for r in rows if _unexpired(r)]


@app.get("/geofences")
def public_geofences():
    return supabase.table("geofence").select("*").eq("isactive", True).order("createdat", desc=True).execute().data


@app.get("/appdocs")
def public_docs(category: str | None = Query(None)):
    """Unified content docs (guides + prep) — one tree structure per doc.

    NOTE: must NOT be '/docs' — FastAPI reserves '/docs' for its Swagger UI,
    which would shadow this route and return HTML instead of JSON.
    """
    q = supabase.table("appdoc").select("*").eq("ispublished", True)
    if category:
        q = q.eq("category", category)
    return q.order("orderindex").order("updatedat", desc=True).execute().data


@app.get("/triage-config")
def public_triage_config():
    """Admin-set default triage weights/tiers/rules. A device with its own
    local Triage Logic edits (Settings > Debugging Options) keeps those —
    this is only the fallback default for devices that never touched it, or
    the value their "Reset" button reverts to."""
    rows = supabase.table("triageconfig").select("*").eq("id", 1).execute().data
    return rows[0] if rows else None


@app.get("/debug-lock")
def public_debug_lock():
    """Password gate in front of Settings > Debugging Options. Returns only
    the hash (never the plaintext) — this is a low-stakes "keep casual users
    out of dev tools" fence, not a real auth boundary, so shipping the hash
    to the device (so the gate still works offline) is an acceptable
    tradeoff here."""
    rows = supabase.table("debuglock").select("enabled,passwordhash").eq("id", 1).execute().data
    return rows[0] if rows else {"enabled": True, "passwordhash": None}


# --------------------------------------------------------------------------- #
# Admin: identity check (web re-validates the session against the allowlist)   #
# --------------------------------------------------------------------------- #
@app.get("/admin/me")
def admin_me(user=Depends(require_admin)):
    return {"email": getattr(user, "email", None), "id": getattr(user, "id", None)}


# --------------------------------------------------------------------------- #
# Admin: dashboard stats                                                       #
# --------------------------------------------------------------------------- #
@app.get("/admin/stats")
def admin_stats(_=Depends(require_admin)):
    bundles = (
        supabase.table("distressbundle")
        .select("bundleid,deviceid,prioritytier,priorityscore,createdat,updatedat,estimatedlat,estimatedlng")
        .order("createdat", desc=True)
        .execute()
        .data
    )

    tiers = Counter(b["prioritytier"] for b in bundles)
    # issynced is hard-coded True on every insert (see /sync) and never
    # flipped back — a row can't exist here unless it already synced, so
    # counting "unsynced" rows always returns 0. "Active" (touched in the
    # last 24h, the same idle window the bundle-reuse logic uses) is the
    # actually meaningful freshness signal — whether this event is still
    # ongoing or has gone quiet.
    now = datetime.now(timezone.utc)
    active = 0
    for b in bundles:
        try:
            if (now - datetime.fromisoformat(b["updatedat"])) < timedelta(hours=24):
                active += 1
        except (ValueError, TypeError, KeyError):
            continue
    located = sum(1 for b in bundles if b.get("estimatedlat") is not None and b.get("estimatedlng") is not None)

    # Activity over the last 14 days, keyed by UTC date.
    today = datetime.now(timezone.utc).date()
    days = [(today - timedelta(days=i)).isoformat() for i in range(13, -1, -1)]
    per_day = defaultdict(int)
    for b in bundles:
        try:
            d = datetime.fromisoformat(b["createdat"]).date().isoformat()
            per_day[d] += 1
        except (ValueError, TypeError, KeyError):
            continue
    activity = [{"date": d, "count": per_day.get(d, 0)} for d in days]

    per_device = Counter(b["deviceid"] for b in bundles)

    def _count(table, col=None, val=None):
        q = supabase.table(table).select("*", count="exact", head=True)
        if col is not None:
            q = q.eq(col, val)
        return q.execute().count or 0

    return {
        "totalBundles": len(bundles),
        "tierCounts": {
            "Critical": tiers.get("Critical", 0),
            "High": tiers.get("High", 0),
            "Moderate": tiers.get("Moderate", 0),
            "Low": tiers.get("Low", 0),
            "None": tiers.get("None", 0),
        },
        "activeCount": active,
        "inactiveCount": len(bundles) - active,
        "locatedCount": located,
        "deviceCount": _count("device"),
        "sensorReadingCount": _count("sensorreading"),
        "geofenceCount": _count("geofence", "isactive", True),
        "noticeCount": _count("notice", "isactive", True),
        # Guides/tips + prep plans both moved to the unified "appdoc" table
        # (one tree-structure editor for survival/first_aid/prep) — the old
        # appcontent/prepplan tables are dead, always-empty leftovers from
        # before that unification, so counting them always read 0.
        "contentCount": _count("appdoc", "category", "survival")
        + _count("appdoc", "category", "first_aid"),
        "prepPlanCount": _count("appdoc", "category", "prep"),
        "activityByDay": activity,
        "topDevices": [{"deviceId": d, "count": c} for d, c in per_device.most_common(5)],
        "recentBundles": bundles[:8],
    }


# --------------------------------------------------------------------------- #
# Admin: bundles                                                               #
# --------------------------------------------------------------------------- #
@app.get("/admin/bundles")
def admin_list_bundles(
    _=Depends(require_admin),
    tier: str | None = Query(None),
    synced: bool | None = Query(None),
    device: str | None = Query(None),
    limit: int = Query(200, ge=1, le=1000),
):
    q = supabase.table("distressbundle").select("*")
    if tier:
        q = q.eq("prioritytier", tier)
    if synced is not None:
        q = q.eq("issynced", synced)
    if device:
        q = q.eq("deviceid", device)
    return q.order("createdat", desc=True).limit(limit).execute().data


@app.get("/admin/bundles/{bundle_id}")
def admin_bundle_detail(bundle_id: str, _=Depends(require_admin)):
    bundle = supabase.table("distressbundle").select("*").eq("bundleid", bundle_id).execute().data
    if not bundle:
        raise HTTPException(status_code=404, detail="Bundle not found")
    readings = supabase.table("sensorreading").select("*").eq("bundleid", bundle_id).order("recordedat").execute().data
    relays = supabase.table("relaylog").select("*").eq("bundleid", bundle_id).order("hopsequence").execute().data
    sync = supabase.table("syncrecord").select("*").eq("bundleid", bundle_id).execute().data
    return {
        "bundle": bundle[0],
        "sensorReadings": readings,
        "relayLogs": relays,
        "syncRecord": sync[0] if sync else None,
    }


_BUNDLE_EDITABLE = {"prioritytier", "priorityscore", "estimatedlat", "estimatedlng", "issynced"}


@app.patch("/admin/bundles/{bundle_id}")
def admin_update_bundle(bundle_id: str, payload: dict = Body(...), _=Depends(require_admin)):
    row = {k: v for k, v in payload.items() if k in _BUNDLE_EDITABLE}
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    for key, lo, hi in (("estimatedlat", -90, 90), ("estimatedlng", -180, 180)):
        v = row.get(key)
        if v is not None and (not isinstance(v, (int, float)) or not lo <= v <= hi):
            raise HTTPException(status_code=400, detail=f"{key} must be between {lo} and {hi}")
    row["updatedat"] = _now_iso()
    try:
        res = supabase.table("distressbundle").update(row).eq("bundleid", bundle_id).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Bundle not found")
    return res.data[0]


@app.delete("/admin/bundles/{bundle_id}")
def admin_delete_bundle(bundle_id: str, _=Depends(require_admin)):
    # Sensor readings / relay logs / sync record cascade on FK delete.
    supabase.table("distressbundle").delete().eq("bundleid", bundle_id).execute()
    return {"deleted": bundle_id}


# --------------------------------------------------------------------------- #
# Admin: devices                                                               #
# --------------------------------------------------------------------------- #
@app.get("/admin/devices")
def admin_list_devices(_=Depends(require_admin)):
    devices = supabase.table("device").select("*").order("lastseenat", desc=True).execute().data
    bundles = supabase.table("distressbundle").select("deviceid,prioritytier").execute().data
    tier_by_device: dict[str, Counter] = defaultdict(Counter)
    for b in bundles:
        tier_by_device[b["deviceid"]][b["prioritytier"]] += 1
    for d in devices:
        tc = tier_by_device.get(d["deviceid"], Counter())
        d["bundleCount"] = sum(tc.values())
        d["tierCounts"] = {t: tc[t] for t in ["Critical", "High", "Moderate", "Low"] if tc[t]}
    return devices


@app.patch("/admin/devices/{device_id}")
def admin_update_device(device_id: str, payload: dict = Body(...), _=Depends(require_admin)):
    row = {k: v for k, v in payload.items() if k in {"applicationmode", "applicationversion"}}
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    try:
        res = supabase.table("device").update(row).eq("deviceid", device_id).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Device not found")
    return res.data[0]


@app.delete("/admin/devices/{device_id}")
def admin_delete_device(device_id: str, _=Depends(require_admin)):
    # WARNING: distressbundle.deviceid cascades — deletes that device's bundles.
    supabase.table("device").delete().eq("deviceid", device_id).execute()
    return {"deleted": device_id}


# --------------------------------------------------------------------------- #
# Admin: image upload for the content editor                                   #
# --------------------------------------------------------------------------- #
# Images for guide `image` blocks live in a public Supabase Storage bucket; the
# editor uploads here and embeds the returned public URL. The app downloads +
# caches it for offline viewing. Uploads use the service role (bypasses RLS);
# the bucket is public-read so the app needs no auth to fetch.
CONTENT_BUCKET = "content-images"
_ALLOWED_IMG = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
_MAX_IMG_BYTES = 5 * 1024 * 1024


@app.post("/admin/upload")
async def admin_upload(file: UploadFile = File(...), _=Depends(require_admin)):
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")
    if len(data) > _MAX_IMG_BYTES:
        raise HTTPException(status_code=413, detail="Image too large (max 5 MB)")
    ext = os.path.splitext(file.filename or "")[1].lower() or ".png"
    if ext not in _ALLOWED_IMG:
        raise HTTPException(status_code=400, detail=f"Unsupported image type: {ext}")
    path = f"{uuid.uuid4().hex}{ext}"
    try:
        supabase.storage.from_(CONTENT_BUCKET).upload(
            path,
            data,
            {"content-type": file.content_type or "image/png", "upsert": "false"},
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Upload failed: {exc}")
    url = supabase.storage.from_(CONTENT_BUCKET).get_public_url(path)
    return {"url": url.rstrip("?")}


# --------------------------------------------------------------------------- #
# Admin: generic CRUD for the four simple admin-authored tables                #
# --------------------------------------------------------------------------- #
# geofence / notice / appdoc share an identical CRUD shape, so one registrar
# covers them instead of ~100 lines of copy-paste. (The legacy appcontent /
# prepplan resources were removed once the unified appdoc table replaced them;
# the empty cloud tables still exist but nothing reads or writes them.)
_ADMIN_RESOURCES = {
    "geofences": dict(
        table="geofence", pk="geofenceid",
        fields=["name", "hazardtype", "shape", "geometry", "severity", "isactive"],
        versioned=False,
    ),
    "notices": dict(
        table="notice", pk="noticeid",
        fields=["title", "subtitle", "body", "severity", "isactive", "expiresat", "structure"],
        versioned=False,
    ),
    "docs": dict(
        table="appdoc", pk="docid",
        fields=["category", "title", "structure", "ispublished", "orderindex", "usepercent"],
        versioned=True,
    ),
}


def _register_crud(name: str, cfg: dict) -> None:
    table, pk, fields, versioned = cfg["table"], cfg["pk"], cfg["fields"], cfg["versioned"]

    def list_all(_=Depends(require_admin)):
        return supabase.table(table).select("*").order("createdat", desc=True).execute().data

    def create(payload: dict = Body(...), _=Depends(require_admin)):
        row = {k: payload[k] for k in fields if k in payload}
        if not row:
            raise HTTPException(status_code=400, detail="No editable fields supplied")
        try:
            res = supabase.table(table).insert(row).execute()
        except Exception as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        return res.data[0]

    def update(item_id: str, payload: dict = Body(...), _=Depends(require_admin)):
        row = {k: payload[k] for k in fields if k in payload}
        if not row:
            raise HTTPException(status_code=400, detail="No editable fields supplied")
        row["updatedat"] = _now_iso()
        if versioned:
            cur = supabase.table(table).select("version").eq(pk, item_id).execute().data
            row["version"] = (cur[0]["version"] + 1) if cur else 1
        try:
            res = supabase.table(table).update(row).eq(pk, item_id).execute()
        except Exception as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        if not res.data:
            raise HTTPException(status_code=404, detail=f"{name} item not found")
        return res.data[0]

    def delete(item_id: str, _=Depends(require_admin)):
        supabase.table(table).delete().eq(pk, item_id).execute()
        return {"deleted": item_id}

    # Unique function names so FastAPI doesn't warn on duplicate operation IDs.
    slug = name.replace("-", "_")
    list_all.__name__ = f"admin_list_{slug}"
    create.__name__ = f"admin_create_{slug}"
    update.__name__ = f"admin_update_{slug}"
    delete.__name__ = f"admin_delete_{slug}"

    app.get(f"/admin/{name}")(list_all)
    app.post(f"/admin/{name}")(create)
    app.patch(f"/admin/{name}/{{item_id}}")(update)
    app.delete(f"/admin/{name}/{{item_id}}")(delete)


for _name, _cfg in _ADMIN_RESOURCES.items():
    _register_crud(_name, _cfg)


# --------------------------------------------------------------------------- #
# Admin: triage config (single-row settings, not list-based CRUD)              #
# --------------------------------------------------------------------------- #
_TRIAGE_FIELDS = {
    "wmotion", "wbattery", "wmic", "wbarometer", "wlight", "wproximity",
    "scorecap", "criticalthreshold", "highthreshold", "moderatethreshold",
    "fallenabled", "fallboost", "falllatchseconds",
    "faintenabled", "faintboost", "faintimmobileseconds",
    "lowbatteryenabled", "lowbatterythreshold", "lowbatteryboost",
    "criticalbatteryenabled", "criticalbatterythreshold", "criticalbatteryboost",
    "batterycomfortlevel", "pressuremaxdeviationhpa", "micmindb", "micmaxdb",
    "darkbelowlux", "brightabovelux", "batteryfastdrainpermin",
}
_TRIAGE_BOOL_FIELDS = {
    "fallenabled", "faintenabled", "lowbatteryenabled", "criticalbatteryenabled",
}


@app.get("/admin/triage-config")
def admin_get_triage_config(_=Depends(require_admin)):
    rows = supabase.table("triageconfig").select("*").eq("id", 1).execute().data
    return rows[0] if rows else None


@app.patch("/admin/triage-config")
def admin_update_triage_config(payload: dict = Body(...), _=Depends(require_admin)):
    # Every column is NOT NULL, so a JSON null (e.g. NaN serialised client-side)
    # or a wrong type would otherwise surface as a raw PostgREST error.
    row: dict = {}
    for k, v in payload.items():
        if k not in _TRIAGE_FIELDS:
            continue
        if k in _TRIAGE_BOOL_FIELDS:
            if not isinstance(v, bool):
                raise HTTPException(status_code=400, detail=f"{k} must be true or false")
        elif isinstance(v, bool) or not isinstance(v, (int, float)) \
                or not math.isfinite(v) or v < 0:
            raise HTTPException(status_code=400, detail=f"{k} must be a non-negative number")
        row[k] = v
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    # Tier classification on the device is a first-match-wins cascade
    # (critical, then high, then moderate — see tierForScore in
    # triage_calculator.dart), so the thresholds must strictly descend or
    # whole tiers become unreachable. Merge with the stored row so a partial
    # PATCH can't sneak an inversion past the check.
    _tiers = ("criticalthreshold", "highthreshold", "moderatethreshold")
    if any(k in row for k in _tiers):
        merged = {k: row[k] for k in _tiers if k in row}
        if len(merged) < 3:  # partial PATCH — fill gaps from the stored row
            stored = supabase.table("triageconfig").select(",".join(_tiers)).eq("id", 1).execute().data
            merged = {**(stored[0] if stored else {}), **merged}
        c, h, m = (merged.get(k) for k in _tiers)
        if None not in (c, h, m) and not (c > h > m):
            raise HTTPException(
                status_code=400,
                detail="Tier thresholds must descend: Critical > High > Moderate "
                       f"(got {c} / {h} / {m})",
            )
    row["updatedat"] = _now_iso()
    try:
        res = supabase.table("triageconfig").update(row).eq("id", 1).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Triage config row missing")
    return res.data[0]


# --------------------------------------------------------------------------- #
# Admin: debug-options password lock                                          #
# --------------------------------------------------------------------------- #
@app.get("/admin/debug-lock")
def admin_get_debug_lock(_=Depends(require_admin)):
    # Password hash is write-only from the admin's perspective — the console
    # never needs to read it back, only set a new one.
    rows = supabase.table("debuglock").select("enabled,updatedat").eq("id", 1).execute().data
    return rows[0] if rows else {"enabled": True}


@app.patch("/admin/debug-lock")
def admin_update_debug_lock(payload: dict = Body(...), _=Depends(require_admin)):
    row: dict = {}
    if "enabled" in payload:
        if not isinstance(payload["enabled"], bool):
            raise HTTPException(status_code=400, detail="enabled must be true or false")
        row["enabled"] = payload["enabled"]
    password = payload.get("password")
    if password:
        if not isinstance(password, str) or len(password) < 4:
            raise HTTPException(status_code=400, detail="Password must be at least 4 characters")
        row["passwordhash"] = hashlib.sha256(password.encode()).hexdigest()
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    row["updatedat"] = _now_iso()
    try:
        res = supabase.table("debuglock").update(row).eq("id", 1).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Debug lock row missing")
    return {"enabled": res.data[0]["enabled"]}
