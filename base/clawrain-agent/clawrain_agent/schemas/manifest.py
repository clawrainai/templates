"""Manifest schema — describes what endpoints this agent exposes."""
from dataclasses import dataclass, field, asdict
from typing import List, Optional


@dataclass
class ManifestEndpoint:
    path: str
    label: str
    widget: str  # MetricCard, DataTable, LineChart, StatusGrid, BadgeList
    priority: int
    refresh: int  # seconds
    source: str  # realtime, sqlite, local


@dataclass
class Manifest:
    agent_id: str
    skill: str
    version: str
    endpoints: List[ManifestEndpoint] = field(default_factory=list)

    def to_dict(self):
        return asdict(self)
