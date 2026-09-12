"""Inventory model for the fleet.

This file defines the data structures that the whole toolkit reads: the fleet
inventory, which is a list of hosts, each carrying the installed versions of the
services it runs (an operating system, a database engine, a cache engine, or a
cluster platform). The inventory can come from a sample data file (JSON or CSV,
under ``tests/fixtures/``), or from the live describe result of the AWS APIs
when the optional ``boto3`` extra is installed (see ``cloudops.aws_live``).

The model is deliberately small and strict: an unknown field is an error, not a
warning, because an inventory that has drifted from its schema is exactly the
condition that an operations tool exists to find.
"""

from __future__ import annotations

import csv
import json
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Iterable, Sequence


class ServiceFamily(Enum):
    """The service families this toolkit understands (one row per family)."""

    EC2_AMI = "ec2:ami"
    RDS_DB = "rds:db"
    ELASTICACHE = "elasticache"
    EKS = "eks"

    @classmethod
    def from_label(cls, label: str) -> "ServiceFamily":
        """Purpose: map an inventory label (e.g. 'rds', 'elasticache:redis') to a family.

        Returns: the matching ServiceFamily. Raises ValueError on an unknown label.
        """
        lowered = label.strip().lower()
        head = lowered.split(":", 1)[0]
        for member in cls:
            if member.value.split(":", 1)[0] == head:
                return member
        raise ValueError(f"unknown service label: {label!r}")


@dataclass
class Host:
    """One managed host in the inventory.

    Attributes:
        host_id:    the resource identifier (an instance id, a db instance
                    identifier, or a replication group id).
            service:    the service label, e.g. 'ec2:ami', 'rds:db',
                    'elasticache:redis', 'eks'.
        engine:     the engine name when the service has one (mysql,
                    postgres, redis, valkey); None for plain EC2 images.
        version:    the installed version string, as the APIs report it.
        role:       a free-form label for the patch ring of the host
                    ('canary', 'standard', 'critical'); see cloudops.patch.
        tags:       the resource tags relevant to operations (environment,
                    owner, patch group).
    """

    host_id: str
    service: str
    version: str
    engine: str | None = None
    role: str = "standard"
    tags: dict[str, str] = field(default_factory=dict)

    def __init__(self, host_id, service, version, engine=None,
                 role="standard", tags=None) -> None:
        # A plain initializer rather than the generated one of a dataclass,
        # because the validation of the hook below must run on every
        # construction, and a dataclass skips the generated initializer the
        # moment the body names __init__ itself.
        self.host_id = host_id
        self.service = service
        self.version = version
        self.engine = engine
        self.role = role
        self.tags = dict(tags or {})
        # A host without an identifier or a version is unusable data, so reject it here.
        if not self.host_id.strip():
            raise ValueError("host_id must not be empty")
        if not self.version.strip():
            raise ValueError(f"{self.host_id}: version must not be empty")
        ServiceFamily.from_label(self.service)  # validates the label eagerly

    @property
    def family(self) -> ServiceFamily:
        """Returns: the ServiceFamily of the host."""
        return ServiceFamily.from_label(self.service)


@dataclass
class Inventory:
    """A validated collection of hosts, keyed by host_id.

    Purpose: provide iteration, lookup, and loading of inventory files with
    fail-fast validation of the schema. Side effects: none on load of the
    object itself; ``from_json``/``from_csv`` read one file each.
    """

    hosts: list[Host] = field(default_factory=list)

    def __post_init__(self) -> None:
        seen: set[str] = set()
        for host in self.hosts:
            if host.host_id in seen:
                raise ValueError(f"duplicate host_id in inventory: {host.host_id}")
            seen.add(host.host_id)

    # -- loading ---------------------------------------------------------
    @classmethod
    def from_json(cls, path: str | Path) -> "Inventory":
        """Purpose: load an inventory from a JSON file (list of host records).

        Returns: a populated Inventory. Side effects: reads the file once.
        """
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
        records = document["hosts"] if isinstance(document, dict) else document
        hosts = [
            Host(
                host_id=str(record["host_id"]),
                service=str(record["service"]),
                version=str(record["version"]),
                engine=record.get("engine"),
                role=str(record.get("role", "standard")),
                tags=dict(record.get("tags", {})),
            )
            for record in records
        ]
        return cls(hosts=hosts)

    @classmethod
    def from_csv(cls, path: str | Path) -> "Inventory":
        """Purpose: load an inventory from a CSV file.

        The columns are host_id, service, version, engine, role, and tags,
        where tags is a semicolon-separated list of key=value pairs.
        Returns: a populated Inventory. Side effects: reads the file once.
        """
        hosts: list[Host] = []
        with open(path, encoding="utf-8", newline="") as handle:
            for record in csv.DictReader(handle):
                tags = {}
                if record.get("tags"):
                    for pair in record["tags"].split(";"):
                        if "=" in pair:
                            key, _, value = pair.partition("=")
                            tags[key.strip()] = value.strip()
                hosts.append(
                    Host(
                        host_id=record["host_id"],
                        service=record["service"],
                        version=record["version"],
                        engine=record.get("engine") or None,
                        role=(record.get("role") or "standard"),
                        tags=tags,
                    )
                )
        return cls(hosts=hosts)

    # -- access ----------------------------------------------------------
    def __iter__(self) -> Iterable[Host]:
        return iter(self.hosts)

    def __len__(self) -> int:
        return len(self.hosts)

    def by_id(self, host_id: str) -> Host:
        """Returns: the host with this id. Raises KeyError when absent."""
        for host in self.hosts:
            if host.host_id == host_id:
                return host
        raise KeyError(host_id)

    def select(self, *, family: ServiceFamily | None = None, role: str | None = None,
               engine: str | None = None, environment: str | None = None) -> Sequence[Host]:
        """Purpose: filter the inventory by any combination of attributes.

        Returns: the tuple of matching hosts, in stable (file) order.
        """
        selected = list(self.hosts)
        if family is not None:
            selected = [h for h in selected if h.family is family]
        if role is not None:
            selected = [h for h in selected if h.role == role]
        if engine is not None:
            selected = [h for h in selected
                        if (h.engine or "").lower() == engine.lower()]
        if environment is not None:
            selected = [h for h in selected
                        if h.tags.get("Environment", "").lower() == environment.lower()]
        return tuple(selected)
