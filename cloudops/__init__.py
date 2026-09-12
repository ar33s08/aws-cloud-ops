#!/usr/bin/env python3
"""cloudops — operations toolkit for AWS platform engineers.

The package is organised like a well-structured manual of the estate:

* `cloudops.inventory` — loading and validating the fleet inventory
  (canned sample data or live describe results from AWS APIs, via boto3);
* `cloudops.eol`       — end-of-life and end-of-support comparison logic,
  version classification, and the recommended-action report;
* `cloudops.patch`     — patch baselines, patch groups, and the compliance queue;
* `cloudops.drift`     — detection of differences between the live inventory
  and the state file of the estate;
* `cloudops.report`    — representation of the results (table, csv, json, md);
* `cloudops.cli`       — the command-line interface (init, scan, report,
  drift, patch-queue, snapshot, upgrade, version).

All modules of the core package use only the Python standard library.
`import boto3` happens only in `cloudops.aws_live`, and only when the user
asks for live mode (``pip install 'aws-cloud-ops[live]' --upgrade'``).
"""

__version__ = "1.0.0"
__author__ = "Arees Manesia"
__license__ = "Apache-2.0"

from cloudops.eol import EolStatus, compare_versions, classify_status
from cloudops.inventory import Inventory, Host
from cloudops.patch import PatchBaseline, PatchGroup, compliance_scan
from cloudops.drift import detect_drift, DriftFinding

__all__ = [
    "__version__",
    "EolStatus", "compare_versions", "classify_status",
    "Inventory", "Host",
    "PatchBaseline", "PatchGroup", "compliance_scan",
    "detect_drift", "DriftFinding",
]
