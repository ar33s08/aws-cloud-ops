"""Drift detection between the live inventory and the state file of the estate.

This file answers the question that keeps a platform engineer honest: does the
live estate still look the way the configuration claims it looks? The comparison
takes three inputs:

1. the desired state — the resource attributes that the Terraform state file
   records (a sanitized export under ``tests/fixtures/state-export.json``);
2. the live state — the same attributes as the AWS describe APIs report them
   (canned as ``tests/fixtures/live-describe.json``; obtained via boto3 in live
   mode through ``cloudops.aws_live``);
3. the ignore list — the attributes on which the two are allowed to differ
   (timestamps, generated ids, ``modify_date``), declared per resource type in
   the table below, never hardcoded into a comparison loop.

The output is a list of ``DriftFinding`` values: the resource address, the
attribute, the expected value, the observed value, and the severity. A
difference in a security-relevant attribute (a security group opened beyond the
configuration, an unencrypted volume) is CRITICAL and feeds the page of the
on-call operator; a cosmetic difference is INFORMATIONAL and only appears in the
weekly report.

A drift finding is not a change request; it is the evidence for one: open a
pull request against the configuration, let Atlantis run the plan, and resolve
the drift by the pull request, not by the console. The procedure for
remediation is ``UPGRADE-RUNBOOKS.md`` (section 'Drift remediation').
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping, Sequence

# Attributes that legitimately differ between a state file and a describe
# response; extend deliberately, via this table, never inline.
DEFAULT_IGNORE = {
    "*": ("modify_date", "create_date", "arn", "id", "tags_all", "tags_to_add"),
    "aws_instance": ("public_ip", "private_ip", "key_name", "password_data"),
    "aws_db_instance": ("endpoint", "port", "resource_id"),
    "aws_elasticache_replication_group": ("global_shard_count",),
}


@dataclass(frozen=True)
class DriftFinding:
    """One difference between the recorded state and the live state.

    Attributes:
        address:     the Terraform address of the resource (aws_instance.web).
        attribute:   the attribute that differs.
        expected:    the value recorded in the state file.
        observed:    the value the APIs report.
        severity:    INFORMATIONAL, WARNING, or CRITICAL.
        remediation: what the operator should do, as a pointer to a runbook
                     or to the pull request that owns the resource.
    """

    address: str
    attribute: str
    expected: Any
    observed: Any
    severity: str
    remediation: str


# Attributes whose difference is never cosmetic; a change here went around the
# configuration, which is a process incident as much as a technical one. The
# set is kept explicit rather than inferred, so that a review can read exactly
# which attributes are treated as security-relevant.
CRITICAL_ATTRS = frozenset({
    "security_groups", "vpc_security_group_ids", "encrypted",
    "associate_public_ip_on_launch", "iam_instance_profile", "engine_version",
    "storage_encrypted", "at_rest", "metadata_options", "http_tokens",
    "metadata_options.http_tokens", "monitoring_role_arn", "snapshot_identifier",
})


def _get(mapping: Mapping, dotted: str) -> Any:
    """Purpose: read a dotted path out of nested mappings.

    For example ``_get(attrs, "metadata_options.http_tokens")``.

    Returns: the value, or the sentinel string ``<absent>`` when any step is
    missing — which is itself information, because a missing block is a finding.
    """
    # Flat first: a configuration may name an attribute with the dotted name
    # itself (metadata_options.http_tokens as one key); then walk the nesting.
    if dotted in mapping:
        return mapping[dotted]
    current: Any = mapping
    for step in dotted.split("."):
        if not isinstance(current, Mapping) or step not in current:
            return "<absent>"
        current = current[step]
    return current


def detect_drift(state_export: Sequence[dict], live_describe: Sequence[dict], *,
                 extra_ignore: Mapping[str, Sequence[str]] | None = None) -> list[DriftFinding]:
    """Purpose: compare the state file of the estate with the live describe result.

    Both inputs are lists of resource records of the shape {address, type,
    attributes}; the records are joined on ``address``. A resource present on
    one side but not on the other is itself a CRITICAL finding (an unmanaged
    or a deleted resource). The ignore list merges DEFAULT_IGNORE with the
    caller's ``extra_ignore`` per resource type.

    Returns: the findings, CRITICAL first, then WARNING, then INFORMATIONAL.
    Side effects: none — this function only reads its arguments; it never
    touches the network or the credentials.
    """
    live_by_id = {r["address"]: r for r in live_describe}
    state_by_id = {r["address"]: r for r in state_export}
    ignore = {key: tuple(value) for key, value in DEFAULT_IGNORE.items()}
    for key, value in (extra_ignore or {}).items():
        ignore[key] = tuple(value)

    findings: list[DriftFinding] = []

    for address, record in state_by_id.items():
        live = live_by_id.get(address)
        if live is None:
            findings.append(DriftFinding(
                address, "<resource>", "present", "<absent>", "CRITICAL",
                "resource in the state file, not in the live estate:"
                " restore from backup or remove from the state",
            ))
            continue
        rtype = record.get("type", "*")
        skip = set(ignore.get("*", ())) | set(ignore.get(rtype, ()))
        for name, expected in record["attributes"].items():
            if name in skip:
                continue
            observed = _get(live["attributes"], name)
            if _normalise(expected) == _normalise(observed):
                continue
            severity = "CRITICAL" if name in CRITICAL_ATTRS else "WARNING"
            findings.append(DriftFinding(
                address, name, expected, observed, severity,
                f"open a pull request that owns {address};"
                f" atlantis plan/apply is the only apply path",
            ))

    for address, live in live_by_id.items():
        if address not in state_by_id:
            findings.append(DriftFinding(
                address, "<resource>", "<unmanaged>", "present", "CRITICAL",
                "resource in the live estate, not in the state file:"
                " import it or schedule its removal",
            ))

    order = {"CRITICAL": 0, "WARNING": 1, "INFORMATIONAL": 2}
    findings.sort(key=lambda f: (order.get(f.severity, 9), f.address, f.attribute))
    return findings


def _normalise(value: Any) -> Any:
    """Purpose: bring values of both sides into a comparable shape.

    Lists are compared as sorted collections of their normalised items (the
    APIs do not promise an order), booleans as booleans, and numbers as their
    string form, so that a string '1' from one API does not read as a change
    against a 1 from the other. Side effects: none.
    """
    if isinstance(value, Mapping):
        return {k: _normalise(v) for k, v in sorted(value.items())}
    if isinstance(value, (list, tuple, set, frozenset)):
        return sorted(str(_normalise(v)) for v in value)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    return value
