"""SUAR cloud sync bridge. Receives bundles from the Helper app, dedupes
by BundleId, and persists into Supabase. See CLAUDE.md Section 8/14."""
import logging
import os
from datetime import datetime, timezone

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from supabase import Client, create_client

from models import SyncRequest, SyncResponse

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("suar-backend")

supabase: Client = create_client(
    os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SECRET_KEY")
)

app = FastAPI(title="SUAR Sync Backend")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_device(device_id: str, mode: str, version: str | None = None, touch_lastseen: bool = True) -> None:
    existing = supabase.table("device").select("deviceid").eq("deviceid", device_id).execute()
    if existing.data:
        if touch_lastseen:
            supabase.table("device").update({"lastseenat": _now_iso()}).eq("deviceid", device_id).execute()
    else:
        supabase.table("device").insert(
            {
                "deviceid": device_id,
                "applicationmode": mode,
                "applicationversion": version,
                "registeredat": _now_iso(),
                "lastseenat": _now_iso(),
            }
        ).execute()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/bundles")
def get_bundles():
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
        )
    except Exception as exc:
        logger.error(f"Device upsert failed for {payload.device.deviceId}: {exc}")
        raise HTTPException(status_code=500, detail="Sync failed")

    inserted = duplicates = errors = 0

    for bundle in payload.bundles:
        try:
            existing = (
                supabase.table("distressbundle")
                .select("bundleid")
                .eq("bundleid", bundle.bundleId)
                .execute()
            )
            if existing.data:
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
                    "estimatedlat": bundle.estimatedLat,
                    "estimatedlng": bundle.estimatedLng,
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
