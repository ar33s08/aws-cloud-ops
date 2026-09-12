"""Live mode: the thin boto3 shim between the toolkit and the AWS APIs.

This file is the only module of the package that knows about boto3, and even
here the import is deferred: the core toolkit is standard-library-only so
that it can run on any control node, in a CI container, or on a laptop with
no credentials configured. Live mode is opt-in, installable with
``pip install 'aws-cloud-ops[live]'``, and read-only: this module only calls
Describe/Get/List APIs. It never modifies anything; every change to the estate
goes through the Terraform pull request flow (atlantis plan, then atlantis
apply), which is the point of the whole repository.

Credentials come exclusively from the normal AWS credential chain (the
environment, the shared configuration file, an instance profile, or a SSO
session). Nothing here reads, prints, or stores a secret; a developer who
needs a named profile passes it through ``--profile``.
"""

from __future__ import annotations

from cloudops.inventory import Inventory, Host


def _session(region: str | None = None, profile: str | None = None):
    """Purpose: build one boto3 session for all three service clients.

    Returns: the session. Raises ImportError with an installation hint when
    the live extra is absent — the message names the exact pip command.
    """
    try:
        from boto3.session import Session
    except ImportError as exc:                    # pragma: no cover
        raise ImportError(
            "live mode needs the optional dependency boto3; install it with:"
            " pip install 'aws-cloud-ops[live]'"
        ) from exc
    return Session(region_name=region, profile_name=profile)


def describe_fleet(region: str | None = None, profile: str | None = None,
                   *, prefix: str = "") -> Inventory:
    """Purpose: build the live inventory of the estate, from three describe calls.

    Collects the installed versions of the EC2 instances (their images), the
    RDS instances (their engines), the ElastiCache replication groups, and the
    EKS clusters, into one Inventory — the same object shape the canned
    fixtures carry, so that every downstream function works unchanged.

    Returns: a populated Inventory. Side effects: read-only AWS API calls
    (DescribeInstances, DescribeDBInstances, DescribeReplicationGroups,
    ListClusters/DescribeCluster); no state is written anywhere.
    """
    session = _session(region, profile)
    hosts: list[Host] = []

    ec2 = session.client("ec2")
    for reservation in ec2.describe_instances(Filters=[{"Name": "tag:Name",
                                                        "Values": [f"{prefix}*"]}]):
        for instance in reservation.get("Instances", ()):
            if instance.get("InstanceLifecycle") == "spot":
                continue                      # spot fleets get their own scan
            tags = {t["Key"]: t["Value"] for t in instance.get("Tags", ())}
            role = tags.get("PatchRing", "standard").lower()
            image_id = instance.get("ImageId", "")
            hosts.append(Host(
                host_id=instance["InstanceId"],
                service="ec2:ami",
                version=_image_version(ec2, image_id),
                engine=None,
                role=role,
                tags={"Name": tags.get("Name", ""),
                      "Environment": tags.get("Environment", ""),
                      "ImageId": image_id},
            ))

    rds = session.client("rds")
    for db in rds.describe_db_instances().get("DBInstances", ()):
        hosts.append(Host(
            host_id=db["DBInstanceIdentifier"],
            service="rds:db",
            version=db["EngineVersion"],
            engine=db["Engine"].lower(),
            role=db.get("Tags", [{}]) and _tag(db, "PatchRing") or "standard",
            tags={"Environment": _tag(db, "Environment")},
        ))

    elasticache = session.client("elasticache")
    for group in elasticache.describe_replication_groups().get(
            "ReplicationGroups", ()):
        hosts.append(Host(
            host_id=group["ReplicationGroupId"],
            service=f"elasticache:{group.get('CacheEngine', 'redis')}",
            version=group.get("GlobalReplicationGroupInfo", {})
            .get("GlobalNumShards", "0") and "" or group.get("CacheEngineVersion", "")
            .split("#", 1)[0],
            engine=group.get("CacheEngine", "redis").lower(),
            role="standard",
            tags={"Environment": "prod"},
        ))

    eks = session.client("eks")
    for name in eks.list_clusters().get("clusters", ()):
        detail = eks.describe_cluster(name=name)["cluster"]
        hosts.append(Host(
            host_id=detail["name"],
            service="eks",
            version=detail.get("version", ""),
            engine=None,
            role="standard",
            tags={"Environment": "prod"},
        ))

    return Inventory(hosts=hosts)


def _tag(resource: dict, key: str) -> str:
    """Purpose: read one tag value out of an RDS style Tags list."""
    for tag in resource.get("Tags", ()):
        if tag.get("Key") == key:
            return tag.get("Value", "")
    return ""


def _image_version(ec2_client, image_id: str) -> str:
    """Purpose: resolve an AMI id to its human name (the version string the catalog speaks).

    Returns: the image name (e.g. 'amazon-linux-2-amd-64-20240901') or the
    bare id when the image is no longer registered. Side effects: one
    DescribeImages call per distinct id; the result is cached on the client
    object so a fleet of one image costs one call.
    """
    cache = ec2_client.__dict__.setdefault("_image_name_cache", {})
    if image_id in cache:
        return cache[image_id]
    response = ec2_client.describe_images(ImageIds=[image_id], Owners=["amazon"])
    images = response.get("Images", ())
    name = images[0]["Name"] if images else image_id
    cache[image_id] = name
    return name


def describe_patch_compliance(region: str | None = None,
                              profile: str | None = None) -> list[dict]:
    """Purpose: fetch the raw SSM patch compliance reports of the account.

    Returns: the list of report documents, the same shape the canned fixture
    carries (``tests/fixtures/compliance-reports.json``), ready for
    ``cloudops.patch.compliance_scan``. Side effects: read-only calls to
    DescribeInstancePatchStates; no writes.
    """
    session = _session(region, profile)
    ssm = session.client("ssm")
    reports: list[dict] = []
    paginator = ssm.get_paginator("describe_instance_patch_states")
    for page in paginator.paginate():
        for state in page.get("InstancePatchStates", ()):
            operation = state.get("Operation", "patching")
            details = ssm.get_patch_state(InstanceId=state["InstanceId"],
                                         Operation=operation)
            reports.append({
                "host_id": state["InstanceId"],
                "operation": {"patch_group": state.get("PatchGroup", "")},
                "instance_information": details.get("InstanceInformation", {}),
            })
    return reports
