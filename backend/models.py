"""Pydantic request/response models for the SUAR sync API."""
from datetime import datetime
from typing import List, Literal, Optional

from pydantic import BaseModel


class DeviceModel(BaseModel):
    deviceId: str
    applicationMode: Literal["victim", "helper"]
    applicationVersion: str


class SensorReadingModel(BaseModel):
    sensorType: Literal["accelerometer", "barometer", "microphone", "battery"]
    rawValue: float
    normalisedValue: float
    recordedAt: datetime


class RelayLogModel(BaseModel):
    deviceId: str
    nextHopDeviceId: Optional[str] = None
    hopSequence: int
    protocol: Literal["BLE", "WiFiDirect", "HTTPS"]
    relayedAt: datetime


class BundleModel(BaseModel):
    bundleId: str
    deviceId: str
    priorityScore: float
    priorityTier: Literal["Critical", "High", "Moderate", "Low", "None"]
    estimatedLat: Optional[float] = None
    estimatedLng: Optional[float] = None
    hopCount: int = 0
    createdAt: datetime
    updatedAt: datetime
    sensorReadings: List[SensorReadingModel] = []
    relayLogs: List[RelayLogModel] = []


class SyncRequest(BaseModel):
    device: DeviceModel
    bundles: List[BundleModel] = []


class SyncResponse(BaseModel):
    received: int
    inserted: int
    duplicates: int
    errors: int
