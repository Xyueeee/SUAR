"""Pydantic request/response models for the SUAR sync API."""
from datetime import datetime
from typing import List, Literal, Optional

from pydantic import BaseModel, Field


class DeviceModel(BaseModel):
    deviceId: str = Field(min_length=1, max_length=256)
    applicationMode: Literal["victim", "helper"]
    applicationVersion: str = Field(min_length=1, max_length=128)
    # Settings.Secure.ANDROID_ID — survives a reinstall (same signing key,
    # same device), unlike deviceId (a random UUID regenerated whenever the
    # app's local storage is cleared). Optional: older app builds, and
    # non-Android platforms, never send it.
    hardwareId: Optional[str] = Field(default=None, max_length=512)


class SensorReadingModel(BaseModel):
    sensorType: Literal["accelerometer", "barometer", "microphone", "battery"]
    rawValue: float = Field(ge=-1e15, le=1e15, allow_inf_nan=False)
    normalisedValue: float = Field(ge=0, le=1, allow_inf_nan=False)
    recordedAt: datetime


class RelayLogModel(BaseModel):
    deviceId: str = Field(min_length=1, max_length=256)
    nextHopDeviceId: Optional[str] = Field(default=None, max_length=256)
    hopSequence: int = Field(ge=0, le=1_000_000)
    protocol: Literal["BLE", "WiFiDirect", "HTTPS"]
    relayedAt: datetime


class BundleModel(BaseModel):
    bundleId: str = Field(min_length=1, max_length=256)
    deviceId: str = Field(min_length=1, max_length=256)
    priorityScore: float = Field(ge=0, le=1, allow_inf_nan=False)
    priorityTier: Literal["Critical", "High", "Moderate", "Low", "None"]
    estimatedLat: Optional[float] = Field(
        default=None, ge=-90, le=90, allow_inf_nan=False
    )
    estimatedLng: Optional[float] = Field(
        default=None, ge=-180, le=180, allow_inf_nan=False
    )
    accuracyMeters: Optional[float] = Field(
        default=None, ge=0, le=100_000_000, allow_inf_nan=False
    )
    estimatedAltitude: Optional[float] = Field(
        default=None, ge=-1_000_000, le=1_000_000, allow_inf_nan=False
    )
    hopCount: int = Field(default=0, ge=0, le=1_000_000)
    createdAt: datetime
    updatedAt: datetime
    sensorReadings: List[SensorReadingModel] = Field(
        default_factory=list, max_length=64
    )
    relayLogs: List[RelayLogModel] = Field(
        default_factory=list, max_length=1024
    )


class SyncRequest(BaseModel):
    device: DeviceModel
    bundles: List[BundleModel] = Field(default_factory=list, max_length=5000)


class SyncResponse(BaseModel):
    received: int
    inserted: int
    duplicates: int
    errors: int
