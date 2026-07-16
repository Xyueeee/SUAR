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

_supabase_url = os.getenv("SUPABASE_URL")
_supabase_secret_key = os.getenv("SUPABASE_SECRET_KEY")
if not _supabase_url or not _supabase_secret_key:
    raise RuntimeError(
        "SUPABASE_URL and SUPABASE_SECRET_KEY must be configured"
    )

supabase: Client = create_client(
    _supabase_url,
    _supabase_secret_key,
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
    row = {
        "device_id": device_id,
        "application_mode": mode,
        "application_version": version or "unknown",
    }
    if hardware_id is not None:
        row["hardware_id"] = hardware_id

    if touch_lastseen:
        # The device's own sync refreshes mutable registration details. Omitted
        # fields retain their existing values, and database defaults populate
        # registration timestamps on the first insert.
        row["last_seen_at"] = _now_iso()
        supabase.table("device").upsert(
            row,
            on_conflict="device_id",
            default_to_null=False,
        ).execute()
    else:
        # Relay-driven registration only ensures the owning victim exists.
        # ignore_duplicates makes the insert race-safe without overwriting a
        # real device's current mode/version/last-seen metadata.
        supabase.table("device").upsert(
            row,
            on_conflict="device_id",
            ignore_duplicates=True,
            default_to_null=False,
        ).execute()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/bundles")
def get_bundles():
    """Legacy public listing kept for backward compat (RLS already exposes
    these read-only). The admin web uses /admin/bundles instead."""
    result = (
        supabase.table("distress_bundle")
        .select("*")
        .order("created_at", desc=True)
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
                supabase.table("distress_bundle")
                .select("distress_bundle_id,updated_at")
                .eq("distress_bundle_id", bundle.bundleId)
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
                if not _is_newer(bundle.updatedAt, existing.data[0].get("updated_at")):
                    supabase.table("sync_record").upsert(
                        {"distress_bundle_id": bundle.bundleId, "synced_at": _now_iso(), "server_status": "duplicate"},
                        on_conflict="distress_bundle_id",
                    ).execute()
                    duplicates += 1
                    continue
                supabase.table("distress_bundle").update(
                    {
                        "priority_score": bundle.priorityScore,
                        "priority_tier": bundle.priorityTier,
                        "estimated_lat": lat,
                        "estimated_lng": lng,
                        "accuracy_meters": bundle.accuracyMeters,
                        "estimated_altitude": bundle.estimatedAltitude,
                        "hop_count": bundle.hopCount,
                        "updated_at": bundle.updatedAt.isoformat(),
                    }
                ).eq("distress_bundle_id", bundle.bundleId).execute()
                if bundle.sensorReadings:
                    # The refreshed copy carries the CURRENT readings snapshot —
                    # replace the stored one (delete + insert, mirroring the
                    # on-device SQLiteRepository.saveBundle), otherwise only the
                    # very first push's readings ever land and re-inserting
                    # would pile up duplicates (sensor_reading_id is generated).
                    supabase.table("sensor_reading").delete().eq("distress_bundle_id", bundle.bundleId).execute()
                    supabase.table("sensor_reading").insert(
                        [
                            {
                                "distress_bundle_id": bundle.bundleId,
                                "sensor_type": r.sensorType,
                                "raw_value": r.rawValue,
                                "normalised_value": r.normalisedValue,
                                "recorded_at": r.recordedAt.isoformat(),
                            }
                            for r in bundle.sensorReadings
                        ]
                    ).execute()
                supabase.table("sync_record").upsert(
                    {"distress_bundle_id": bundle.bundleId, "synced_at": _now_iso(), "server_status": "duplicate"},
                    on_conflict="distress_bundle_id",
                ).execute()
                duplicates += 1
                continue

            ensure_device(bundle.deviceId, "victim", version="unknown", touch_lastseen=False)

            supabase.table("distress_bundle").insert(
                {
                    "distress_bundle_id": bundle.bundleId,
                    "device_id": bundle.deviceId,
                    "priority_score": bundle.priorityScore,
                    "priority_tier": bundle.priorityTier,
                    "estimated_lat": lat,
                    "estimated_lng": lng,
                    "accuracy_meters": bundle.accuracyMeters,
                    "estimated_altitude": bundle.estimatedAltitude,
                    "hop_count": bundle.hopCount,
                    "is_synced": True,
                    "created_at": bundle.createdAt.isoformat(),
                    "updated_at": bundle.updatedAt.isoformat(),
                }
            ).execute()

            if bundle.sensorReadings:
                supabase.table("sensor_reading").insert(
                    [
                        {
                            "distress_bundle_id": bundle.bundleId,
                            "sensor_type": r.sensorType,
                            "raw_value": r.rawValue,
                            "normalised_value": r.normalisedValue,
                            "recorded_at": r.recordedAt.isoformat(),
                        }
                        for r in bundle.sensorReadings
                    ]
                ).execute()

            if bundle.relayLogs:
                supabase.table("relay_log").insert(
                    [
                        {
                            "distress_bundle_id": bundle.bundleId,
                            "device_id": r.deviceId,
                            "next_hop_device_id": r.nextHopDeviceId,
                            "hop_sequence": r.hopSequence,
                            "protocol": r.protocol,
                            "relayed_at": r.relayedAt.isoformat(),
                        }
                        for r in bundle.relayLogs
                    ]
                ).execute()

            supabase.table("sync_record").upsert(
                {"distress_bundle_id": bundle.bundleId, "synced_at": _now_iso(), "server_status": "success"},
                on_conflict="distress_bundle_id",
            ).execute()
            inserted += 1

        except Exception as exc:
            logger.error(f"Bundle {bundle.bundleId} failed: {exc}")
            try:
                supabase.table("sync_record").upsert(
                    {"distress_bundle_id": bundle.bundleId, "synced_at": _now_iso(), "server_status": "error"},
                    on_conflict="distress_bundle_id",
                ).execute()
            except Exception as inner_exc:
                logger.error(f"Could not record error sync_record for {bundle.bundleId}: {inner_exc}")
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
    rows = supabase.table("notice").select("*").eq("is_active", True).order("created_at", desc=True).execute().data
    now = datetime.now(timezone.utc)

    def _unexpired(r):
        exp = r.get("expires_at")
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
    return supabase.table("geofence").select("*").eq("is_active", True).order("created_at", desc=True).execute().data


@app.get("/appdocs")
def public_docs(category: str | None = Query(None)):
    """Unified content docs (guides + prep) — one tree structure per doc.

    NOTE: must NOT be '/docs' — FastAPI reserves '/docs' for its Swagger UI,
    which would shadow this route and return HTML instead of JSON.
    """
    q = supabase.table("app_doc").select("*").eq("is_published", True)
    if category:
        q = q.eq("category", category)
    return q.order("order_index").order("updated_at", desc=True).execute().data


@app.get("/triage-config")
def public_triage_config():
    """Admin-set default triage weights/tiers/rules. A device with its own
    local Triage Logic edits (Settings > Debugging Options) keeps those —
    this is only the fallback default for devices that never touched it, or
    the value their "Reset" button reverts to."""
    rows = supabase.table("triage_config").select("*").eq("triage_config_id", 1).execute().data
    return rows[0] if rows else None


@app.get("/debug-lock")
def public_debug_lock():
    """Password gate in front of Settings > Debugging Options. Returns only
    the hash (never the plaintext) — this is a low-stakes "keep casual users
    out of dev tools" fence, not a real auth boundary, so shipping the hash
    to the device (so the gate still works offline) is an acceptable
    tradeoff here."""
    rows = supabase.table("debug_lock").select("enabled,password_hash").eq("debug_lock_id", 1).execute().data
    return rows[0] if rows else {"enabled": True, "password_hash": None}


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
        supabase.table("distress_bundle")
        .select("distress_bundle_id,device_id,priority_tier,priority_score,created_at,updated_at,estimated_lat,estimated_lng")
        .order("created_at", desc=True)
        .execute()
        .data
    )

    tiers = Counter(b["priority_tier"] for b in bundles)
    # is_synced is hard-coded True on every insert (see /sync) and never
    # flipped back — a row can't exist here unless it already synced, so
    # counting "unsynced" rows always returns 0. "Active" (touched in the
    # last 24h, the same idle window the bundle-reuse logic uses) is the
    # actually meaningful freshness signal — whether this event is still
    # ongoing or has gone quiet.
    now = datetime.now(timezone.utc)
    active = 0
    for b in bundles:
        try:
            if (now - datetime.fromisoformat(b["updated_at"])) < timedelta(hours=24):
                active += 1
        except (ValueError, TypeError, KeyError):
            continue
    located = sum(1 for b in bundles if b.get("estimated_lat") is not None and b.get("estimated_lng") is not None)

    # Activity over the last 14 days, keyed by UTC date.
    today = datetime.now(timezone.utc).date()
    days = [(today - timedelta(days=i)).isoformat() for i in range(13, -1, -1)]
    per_day = defaultdict(int)
    for b in bundles:
        try:
            d = datetime.fromisoformat(b["created_at"]).date().isoformat()
            per_day[d] += 1
        except (ValueError, TypeError, KeyError):
            continue
    activity = [{"date": d, "count": per_day.get(d, 0)} for d in days]

    per_device = Counter(b["device_id"] for b in bundles)

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
        "sensorReadingCount": _count("sensor_reading"),
        "geofenceCount": _count("geofence", "is_active", True),
        "noticeCount": _count("notice", "is_active", True),
        # Guides/tips + prep plans both moved to the unified "app_doc" table
        # (one tree-structure editor for survival/first_aid/prep); the legacy
        # appcontent/prepplan tables were dropped in the snake_case rename
        # migration once verified dead.
        "contentCount": _count("app_doc", "category", "survival")
        + _count("app_doc", "category", "first_aid"),
        "prepPlanCount": _count("app_doc", "category", "prep"),
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
    q = supabase.table("distress_bundle").select("*")
    if tier:
        q = q.eq("priority_tier", tier)
    if synced is not None:
        q = q.eq("is_synced", synced)
    if device:
        q = q.eq("device_id", device)
    return q.order("created_at", desc=True).limit(limit).execute().data


@app.get("/admin/bundles/{bundle_id}")
def admin_bundle_detail(bundle_id: str, _=Depends(require_admin)):
    bundle = supabase.table("distress_bundle").select("*").eq("distress_bundle_id", bundle_id).execute().data
    if not bundle:
        raise HTTPException(status_code=404, detail="Bundle not found")
    readings = supabase.table("sensor_reading").select("*").eq("distress_bundle_id", bundle_id).order("recorded_at").execute().data
    relays = supabase.table("relay_log").select("*").eq("distress_bundle_id", bundle_id).order("hop_sequence").execute().data
    sync = supabase.table("sync_record").select("*").eq("distress_bundle_id", bundle_id).execute().data
    return {
        "bundle": bundle[0],
        "sensorReadings": readings,
        "relayLogs": relays,
        "syncRecord": sync[0] if sync else None,
    }


_BUNDLE_EDITABLE = {"priority_tier", "priority_score", "estimated_lat", "estimated_lng", "is_synced"}


@app.patch("/admin/bundles/{bundle_id}")
def admin_update_bundle(bundle_id: str, payload: dict = Body(...), _=Depends(require_admin)):
    row = {k: v for k, v in payload.items() if k in _BUNDLE_EDITABLE}
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    for key, lo, hi in (("estimated_lat", -90, 90), ("estimated_lng", -180, 180)):
        v = row.get(key)
        if v is not None and (not isinstance(v, (int, float)) or not lo <= v <= hi):
            raise HTTPException(status_code=400, detail=f"{key} must be between {lo} and {hi}")
    row["updated_at"] = _now_iso()
    try:
        res = supabase.table("distress_bundle").update(row).eq("distress_bundle_id", bundle_id).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Bundle not found")
    return res.data[0]


@app.delete("/admin/bundles/{bundle_id}")
def admin_delete_bundle(bundle_id: str, _=Depends(require_admin)):
    # Sensor readings / relay logs / sync record cascade on FK delete.
    supabase.table("distress_bundle").delete().eq("distress_bundle_id", bundle_id).execute()
    return {"deleted": bundle_id}


# --------------------------------------------------------------------------- #
# Admin: devices                                                               #
# --------------------------------------------------------------------------- #
@app.get("/admin/devices")
def admin_list_devices(_=Depends(require_admin)):
    devices = supabase.table("device").select("*").order("last_seen_at", desc=True).execute().data
    bundles = supabase.table("distress_bundle").select("device_id,priority_tier").execute().data
    tier_by_device: dict[str, Counter] = defaultdict(Counter)
    for b in bundles:
        tier_by_device[b["device_id"]][b["priority_tier"]] += 1
    for d in devices:
        tc = tier_by_device.get(d["device_id"], Counter())
        d["bundleCount"] = sum(tc.values())
        d["tierCounts"] = {t: tc[t] for t in ["Critical", "High", "Moderate", "Low"] if tc[t]}
    return devices


@app.patch("/admin/devices/{device_id}")
def admin_update_device(device_id: str, payload: dict = Body(...), _=Depends(require_admin)):
    row = {k: v for k, v in payload.items() if k in {"application_mode", "application_version"}}
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    try:
        res = supabase.table("device").update(row).eq("device_id", device_id).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Device not found")
    return res.data[0]


@app.delete("/admin/devices/{device_id}")
def admin_delete_device(device_id: str, _=Depends(require_admin)):
    # WARNING: distress_bundle.device_id cascades — deletes that device's bundles.
    supabase.table("device").delete().eq("device_id", device_id).execute()
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
    # Read at most one byte beyond the limit so an oversized upload cannot be
    # buffered in full before it is rejected.
    data = await file.read(_MAX_IMG_BYTES + 1)
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
# geofence / notice / app_doc share an identical CRUD shape, so one registrar
# covers them instead of ~100 lines of copy-paste. (The legacy appcontent /
# prepplan resources were removed once the unified app_doc table replaced
# them; the dead cloud tables themselves were dropped in the rename migration.)
_ADMIN_RESOURCES = {
    "geofences": dict(
        table="geofence", pk="geofence_id",
        fields=["name", "hazard_type", "shape", "geometry", "severity", "is_active"],
        versioned=False,
    ),
    "notices": dict(
        table="notice", pk="notice_id",
        fields=["title", "subtitle", "body", "severity", "is_active", "expires_at", "structure"],
        versioned=False,
    ),
    "docs": dict(
        table="app_doc", pk="app_doc_id",
        fields=["category", "title", "structure", "is_published", "order_index", "use_percent"],
        versioned=True,
    ),
}


def _register_crud(name: str, cfg: dict) -> None:
    table, pk, fields, versioned = cfg["table"], cfg["pk"], cfg["fields"], cfg["versioned"]

    def list_all(_=Depends(require_admin)):
        return supabase.table(table).select("*").order("created_at", desc=True).execute().data

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
        row["updated_at"] = _now_iso()
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
    "w_motion", "w_battery", "w_mic", "w_barometer", "w_light", "w_proximity",
    "score_cap", "critical_threshold", "high_threshold", "moderate_threshold",
    "fall_enabled", "fall_boost", "fall_latch_seconds",
    "faint_enabled", "faint_boost", "faint_immobile_seconds",
    "low_battery_enabled", "low_battery_threshold", "low_battery_boost",
    "critical_battery_enabled", "critical_battery_threshold", "critical_battery_boost",
    "battery_comfort_level", "pressure_max_deviation_hpa", "mic_min_db", "mic_max_db",
    "dark_below_lux", "bright_above_lux", "battery_fast_drain_per_min",
}
_TRIAGE_BOOL_FIELDS = {
    "fall_enabled", "faint_enabled", "low_battery_enabled", "critical_battery_enabled",
}

# Upper/lower bounds per field, mirroring RANGES in frontend/web/js/views/system.js.
# The console guards these too, but that is a convenience — this is the trust
# boundary, and a partial PATCH straight to the API would otherwise happily
# store a 500% battery threshold as the default for every device.
_TRIAGE_RANGES = {
    "w_motion": (0, 100), "w_battery": (0, 100), "w_mic": (0, 100),
    "w_barometer": (0, 100), "w_light": (0, 100), "w_proximity": (0, 100),
    "score_cap": (1, 1000),
    "critical_threshold": (0, 1000), "high_threshold": (0, 1000), "moderate_threshold": (0, 1000),
    "fall_boost": (0, 500), "fall_latch_seconds": (1, 3600),
    "faint_boost": (0, 500), "faint_immobile_seconds": (1, 3600),
    "low_battery_threshold": (0, 100), "low_battery_boost": (0, 500),
    "critical_battery_threshold": (0, 100), "critical_battery_boost": (0, 500),
    "battery_comfort_level": (0, 100),
    "pressure_max_deviation_hpa": (0.1, 500),
    "mic_min_db": (0, 200), "mic_max_db": (0, 200),
    "dark_below_lux": (0, 200000), "bright_above_lux": (0, 200000),
    "battery_fast_drain_per_min": (0.01, 100),
}


@app.get("/admin/triage-config")
def admin_get_triage_config(_=Depends(require_admin)):
    rows = supabase.table("triage_config").select("*").eq("triage_config_id", 1).execute().data
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
        else:
            lo, hi = _TRIAGE_RANGES.get(k, (None, None))
            if lo is not None and not (lo <= v <= hi):
                raise HTTPException(status_code=400, detail=f"{k} must be between {lo} and {hi} (got {v})")
        row[k] = v
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    # Tier classification on the device is a first-match-wins cascade
    # (critical, then high, then moderate — see tierForScore in
    # triage_calculator.dart), so the thresholds must strictly descend or
    # whole tiers become unreachable. Merge with the stored row so a partial
    # PATCH can't sneak an inversion past the check.
    _tiers = ("critical_threshold", "high_threshold", "moderate_threshold")
    if any(k in row for k in _tiers):
        merged = {k: row[k] for k in _tiers if k in row}
        if len(merged) < 3:  # partial PATCH — fill gaps from the stored row
            stored = supabase.table("triage_config").select(",".join(_tiers)).eq("triage_config_id", 1).execute().data
            merged = {**(stored[0] if stored else {}), **merged}
        c, h, m = (merged.get(k) for k in _tiers)
        if None not in (c, h, m) and not (c > h > m):
            raise HTTPException(
                status_code=400,
                detail="Tier thresholds must descend: Critical > High > Moderate "
                       f"(got {c} / {h} / {m})",
            )
    row["updated_at"] = _now_iso()
    try:
        res = supabase.table("triage_config").update(row).eq("triage_config_id", 1).execute()
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
    rows = supabase.table("debug_lock").select("enabled,updated_at").eq("debug_lock_id", 1).execute().data
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
        row["password_hash"] = hashlib.sha256(password.encode()).hexdigest()
    if not row:
        raise HTTPException(status_code=400, detail="No editable fields supplied")
    row["updated_at"] = _now_iso()
    try:
        res = supabase.table("debug_lock").update(row).eq("debug_lock_id", 1).execute()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not res.data:
        raise HTTPException(status_code=404, detail="Debug lock row missing")
    return {"enabled": res.data[0]["enabled"]}
