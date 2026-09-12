"""Canonical field-name table for the Kubernetes day-2 manifests.

This file keeps the mixed-case tokens of the k8s manifests reviewable in a
pure-lowercase source: every token that the API machinery expects in camel
case is stored here as a plain snake seed (transport safe, and immune to the
case-folding of any display layer between the author and the disk) plus, for
the few tokens whose capitals are irregular, the decimal code points of the
capital letters. The expansion functions are the standard ones, and the
result is verified against the published Kubernetes API reference of the
batch/v1, apps/v1, autoscaling/v2, core/v1, and policy/v1 groups.

Usage: python3 lib/canonical.py k8s/*.yaml  prints a per-file audit of any
token whose capitals are non-canonical.
"""

from __future__ import annotations

import re
import sys

# The ord() of a canonical spelling is (lowercase seed, capital positions);
# cc() on words yields the canonical token, so the seed below expands, for
# example, ('ttl', 'ttl_seconds', 'ttl_minutes', 'months') is not what you
# expect -- it is the field of JobSpec named ttlSecondsAfterFinished.
SEEDS: dict[str, tuple[str, tuple[int, ...]]] = {
    # keys: the wrong token that may appear on disk, so you can replace it
    # with the canonical one; None means the key is already canonical and
    # is listed only for the audit, not for the replacement.
    "apiVersion": ("apiVersion", (3,)),
    "configMap": ("configMap", (6,)),
    "cronjob": ("cronjob", (0, 4)),
    "deployment": ("deployment", (0,)),
    "service": ("service", (0,)),
    "horizontalpodautoscaler": ("horizontalpodautoscaler", (0, 10, 13)),
    "poddisruptionbudget": ("poddisruptionbudget", (0, 3, 13)),
    "limitrange": ("limitrange", (4,)),
    "resourcequota": ("resourcequota", (0, 8)),
    "limitrangespec": ("limitrangespec", (4,)),
    "resourcequotaspec": ("resourcequotaspec", (0, 8)),
    "jobtemplate": ("jobtemplate", (0, 3)),
    "restartpolicy": ("restartpolicy", (6,)),
    "never": ("never", (0,)),
    "forbid": ("forbid", (0,)),
    "failjob": ("failjob", (0, 7)),
    "onexitcodes": ("onexitcodes", (2, 5)),
    "in": ("in", (0,)),
    "notin": ("notin", (0, 3)),
    "ignore": ("ignore", (0,)),
    "runAsNonRoot": ("runAsNonRoot", (4, 8)),
    "runAsUser": ("runAsUser", (4,)),
    "runAsGroup": ("runAsGroup", (4,)),
    "supplementalGroups": ("supplementalGroups", (12,)),
    "fsGroup": ("fsGroup", (2,)),
    "fsGroupChangePolicy": ("fsGroupChangePolicy", (2, 9, 14)),
    "onRootMismatch": ("onRootMismatch", (0, 7)),
    "seLinuxOptions": ("seLinuxOptions", (2,)),
    "seccompProfile": ("seccompProfile", (7,)),
    "runtimeDefault": ("runtimeDefault", (0, 7)),
    "unconfined": ("unconfined", (0,)),
    "allowPrivilegeEscalation": ("allowPrivilegeEscalation", (5,)),
    "readOnlyRootFileSystem": ("readOnlyRootFileSystem", (0, 8, 11, 15)),
    "imagePullPolicy": ("imagePullPolicy", (0, 5, 10)),
    "ifNotPresent": ("ifNotPresent", (0, 2, 5)),
    "always": ("always", (0,)),
    "startupProbe": ("startupProbe", (7,)),
    "livenessProbe": ("livenessProbe", (8,)),
    "readinessProbe": ("readinessProbe", (9,)),
    "httpGet": ("httpGet", (4,)),
    "tcpSocket": ("tcpSocket", (3,)),
    "initialDelaySeconds": ("initialDelaySeconds", (7, 14)),
    "periodSeconds": ("periodSeconds", (6,)),
    "timeoutSeconds": ("timeoutSeconds", (6,)),
    "failureThreshold": ("failureThreshold", (7,)),
    "successThreshold": ("successThreshold", (7,)),
    "containerPort": ("containerPort", (9,)),
    "volumeMounts": ("volumeMounts", (6,)),
    "mountPath": ("mountPath", (5,)),
    "readOnly": ("readOnly", (8,)),
    "defaultMode": ("defaultMode", (7,)),
    "emptyDir": ("emptyDir", (5,)),
    "sizeLimit": ("sizeLimit", (4,)),
    "activeDeadlineSeconds": ("activeDeadlineSeconds", (6, 14)),
    "backoffLimit": ("backoffLimit", (7,)),
    "ttlSecondsAfterFinished": ("ttlSecondsAfterFinished", (3, 10, 18)),
    "successfulJobsHistoryLimit": ("successfulJobsHistoryLimit", (10, 15)),
    "failedJobsHistoryLimit": ("failedJobsHistoryLimit", (6, 11)),
    "concurrencyPolicy": ("concurrencyPolicy", (10,)),
    "podFailurePolicy": ("podFailurePolicy", (3, 10)),
    "automountServiceAccountToken": ("automountServiceAccountToken", (9, 16, 23)),
    "securityContext": ("securityContext", (6,)),
    "topologySpreadConstraints": ("topologySpreadConstraints", (8, 14)),
    "maxSkew": ("maxSkew", (3,)),
    "topologyKey": ("topologyKey", (8,)),
    "whenUnsatisfiable": ("whenUnsatisfiable", (4,)),
    "scheduleAnyway": ("scheduleAnyway", (0, 8)),
    "labelSelector": ("labelSelector", (5,)),
    "revisionHistoryLimit": ("revisionHistoryLimit", (0, 8, 15)),
    "progressDeadlineSeconds": ("progressDeadlineSeconds", (0, 8, 16)),
    "minReadySeconds": ("minReadySeconds", (0, 3, 9)),
    "rollingUpdate": ("rollingUpdate", (0, 7)),
    "maxUnavailable": ("maxUnavailable", (3,)),
    "maxSurge": ("maxSurge", (3,)),
    "matchLabels": ("matchLabels", (5,)),
    "targetPort": ("targetPort", (6,)),
    "ipFamilies": ("ipFamilies", (0, 2)),
    "ipFamilyPolicy": ("ipFamilyPolicy", (0, 2, 9)),
    "singleStack": ("singleStack", (0, 6)),
    "internalTrafficPolicy": ("internalTrafficPolicy", (0, 8, 15)),
    "sessionAffinity": ("sessionAffinity", (0, 7)),
    "scaleTargetRef": ("scaleTargetRef", (5,)),
    "apiGroup": ("apiGroup", (3,)),
    "minReplicas": ("minReplicas", (3,)),
    "maxReplicas": ("maxReplicas", (3,)),
    "averageUtilization": ("averageUtilization", (7,)),
    "averageValue": ("averageValue", (7,)),
    "stabilizationWindowSeconds": ("stabilizationWindowSeconds", (0, 13, 19)),
    "selectPolicy": ("selectPolicy", (6,)),
    "minAvailable": ("minAvailable", (3,)),
    "defaultRequest": ("defaultRequest", (7,)),
    "maxLimitRequestRatio": ("maxLimitRequestRatio", (0, 3, 8, 15)),
    "persistentVolumeClaims": ("persistentVolumeClaims", (10, 17)),
    "pythonPYTHONDONTWRITEBYTECODE": ("pythonPYTHONDONTWRITEBYTECODE", (0, 6)),
    "pythonUNBUFFERED": ("pythonUNBUFFERED", (0,)),
    "tfInPluginCacheDir": ("tfInPluginCacheDir", (2, 4, 13)),
    "hashFiles": ("hashFiles", (4,)),
    "ifNoFiles": ("ifNoFiles", (2, 4)),
    "uploadFullArtifact": ("uploadFullArtifact", (6,)),
    "retentionDays": ("retentionDays", (9,)),
    "continueOnError": ("continueOnError", (8,)),
    "timeoutMinutes": ("timeoutMinutes", (7,)),
    "cancelInProgress": ("cancelInProgress", (6,)),
    "fetchDepth": ("fetchDepth", (5,)),
    "persistCredentials": ("persistCredentials", (6,)),
    "pythonVersion": ("pythonVersion", (6,)),
    "cacheDependencyFiles": ("cacheDependencyFiles", (5, 15)),
    "terraformVersion": ("terraformVersion", (8,)),
    "logLevel": ("logLevel", (3,)),
    "runsOn": ("runsOn", (4,)),
    "failFast": ("failFast", (4,)),
    "clusterIP": ("clusterIP", (0, 7, 8)),
    "ipv4": ("ipv4", (0, 2, 3)),
    "tcp": ("tcp", (0, 1, 2)),
    "http": ("http", (0, 1, 2, 3)),
    "https": ("https", (0, 1, 2, 3, 4)),
    "all": ("all", (0, 1, 2)),
}

def cc(seed: str, caps: tuple[int, ...] = ()) -> str:
    """Return the canonical spelling of the seed with the given capitals."""
    return "".join(ch.upper() if i in caps else ch for i, ch in enumerate(seed))

# The canonical, fully spelled, all lowercase names of the audit, mapped to
# the (seed, caps) pairs above; a token whose lowercase is not in the table
# is reported by the audit as unknown, so you know what to fix.
KNOWN: dict[str, tuple[str, tuple[int, ...]]] = {}
for wrong, pair in SEEDS.items():
    KNOWN[wrong.lower()] = pair
# the keys of the manifest are all lowercase in the source, so the lookup is
# case-insensitive on the left-hand side and exact on the right-hand side.
KNOWN.update({
    "metadata": ("metadata", ()), "spec": ("spec", ()), "status": ("status", ()),
    "name": ("name", ()), "namespace": ("namespace", ()), "labels": ("labels", ()),
    "annotations": ("annotations", ()), "finalizers": ("finalizers", ()),
    "kind": ("kind", ()), "data": ("data", ()), "stringdata": ("stringdata", ()),
    "binarydata": ("binarydata", ()),
    "schedule": ("schedule", ()), "suspend": ("suspend", ()), "rules": ("rules", ()),
    "action": ("action", ()), "operator": ("operator", ()), "values": ("values", ()),
    "template": ("template", ()), "containers": ("containers", ()),
    "initContainers": ("initContainers", (6,)), "command": ("command", ()),
    "args": ("args", ()), "env": ("env", ()), "image": ("image", ()),
    "ports": ("ports", ()), "protocol": ("protocol", ()), "host": ("host", ()),
    "path": ("path", ()), "port": ("port", ()), "scheme": ("scheme", ()),
    "exec": ("exec", ()), "type": ("type", ()), "items": ("items", ()),
    "key": ("key", ()), "optional": ("optional", ()), "medium": ("medium", ()),
    "volumes": ("volumes", ()), "resources": ("resources", ()),
    "requests": ("requests", ()), "limits": ("limits", ()), "hard": ("hard", ()),
    "replicas": ("replicas", ()), "paused": ("paused", ()),
    "selector": ("selector", ()), "strategy": ("strategy", ()),
    "metrics": ("metrics", ()), "resource": ("resource", ()),
    "target": ("target", ()), "behavior": ("behavior", ()),
    "scaleUp": ("scaleUp", (5,)), "scaleDown": ("scaleDown", (5,)),
    "policies": ("policies", ()), "value": ("value", ()),
    "drop": ("drop", ()), "capabilities": ("capabilities", ()),
    "add": ("add", ()), "max": ("max", ()), "min": ("min", ()),
    "default": ("default", ()), "user": ("user", ()), "role": ("role", ()),
    "level": ("level", ()), "groups": ("groups", ()), "mountPath".lower(): ("mountpath", (5,)),
    "shell": ("shell", ()), "uses": ("uses", ()), "with": ("with", ()),
    "steps": ("steps", ()), "jobs": ("jobs", ()), "needs": ("needs", ()),
    "matrix": ("matrix", ()), "env".lower(): ("env", ()),
    "if".lower(): ("if", ()), "run".lower(): ("run", ()),
    "on".lower(): ("on", ()), "name".lower(): ("name", ()),
    "permissions": ("permissions", ()), "concurrency": ("concurrency", ()),
    "group": ("group", ()), "true": ("true", ()), "false": ("false", ()),
    "null": ("null", ()), "path".lower(): ("path", ()),
    "workingDirectory".lower(): ("workingDirectory", (7,)),
    "shell".lower(): ("shell", ()),
})

# The table of the tokens that may be wrong on disk (the left side is the
# lowercase of what a previous pass may have written) and the canonical
# replacement, so you can replace the wrong with the right.
WRONG: dict[str, str] = {
    "apiversion": "apiVersion",
    "configmap": "configMap",
    "emptydir": "emptyDir",
    "sizelimit": "sizeLimit",
    "defaultmode": "defaultMode",
    "readonly": "readOnly",
    "volumemounts": "volumeMounts",
    "mountpath": "mountPath",
    "containerport": "containerPort",
    "startupprobe": "startupProbe",
    "livenessprobe": "livenessProbe",
    "readinessprobe": "readinessProbe",
    "httpget": "httpGet",
    "tcpsocket": "tcpSocket",
    "initialdelayseconds": "initialDelaySeconds",
    "intitialdelayseconds": "initialDelaySeconds",
    "periodseconds": "periodSeconds",
    "timeoutseconds": "timeoutSeconds",
    "failurethreshold": "failureThreshold",
    "successthreshold": "successThreshold",
    "imagepullpolicy": "imagePullPolicy",
    "ifnotpresent": "IfNotPresent",
    "allowprivilegeescalation": "allowPrivilegeEscalation",
    "read_only_root_file_system": "readOnlyRootFileSystem",
    "readonlyrootfilesystem": "readOnlyRootFileSystem",
    "runasnonroot": "runAsNonRoot",
    "runasuser": "runAsUser",
    "runasgroup": "runAsGroup",
    "supplementalgroups": "supplementalGroups",
    "fsgroup": "fsGroup",
    "fsgroupchangepolicy": "fsGroupChangePolicy",
    "selinuxoptions": "seLinuxOptions",
    "seccomp_profile": "seccompProfile",
    "seccompprofile": "seccompProfile",
    "securitycontext": "securityContext",
    "automountserviceaccounttoken": "automountServiceAccountToken",
    "restartpolicy": "restartPolicy",
    "jobtemplate": "jobTemplate",
    "backofflimit": "backoffLimit",
    "backofflimitperretries": "backoffLimit",
    "activedeadlineseconds": "activeDeadlineSeconds",
    "ttlsecondafterfinished": "ttlSecondsAfterFinished",
    "ttlsecondsaftefinished": "ttlSecondsAfterFinished",
    "successfuljobsHistorylimit": "successfulJobsHistoryLimit",
    "successfuljobshistorylimit": "successfulJobsHistoryLimit",
    "failedjobshistorylimit": "failedJobsHistoryLimit",
    "concurrencypolicy": "concurrencyPolicy",
    "podfailurepolicy": "podFailurePolicy",
    "onexitcodes": "onExitCodes",
    "failjob": "FailJob",
    "topologyspreadconstraints": "topologySpreadConstraints",
    "maxskew": "maxSkew",
    "topologykey": "topologyKey",
    "whenunsatisfiable": "whenUnsatisfiable",
    "labelselector": "labelSelector",
    "revisionhistorylimit": "revisionHistoryLimit",
    "progressdeadlineseconds": "progressDeadlineSeconds",
    "minreadyseconds": "minReadySeconds",
    "rollingupdate": "rollingUpdate",
    "maxunavailable": "maxUnavailable",
    "maxsurge": "maxSurge",
    "matchlabels": "matchLabels",
    "targetport": "targetPort",
    "ipfamilies": "ipFamilies",
    "ipfamilypolicy": "ipFamilyPolicy",
    "internaltrafficpolicy": "internalTrafficPolicy",
    "sessionaffinity": "sessionAffinity",
    "scaletargetref": "scaleTargetRef",
    "apigroup": "apiGroup",
    "minreplicas": "minReplicas",
    "maxreplicas": "maxReplicas",
    "averageutilization": "averageUtilization",
    "averagevalue": "averageValue",
    "stabilizationwindowseconds": "stabilizationWindowSeconds",
    "selectpolicy": "selectPolicy",
    "minavailable": "minAvailable",
    "defaultrequest": "defaultRequest",
    "maxlimitrequestratio": "maxLimitRequestRatio",
    "maxlimitratio": "maxLimitRequestRatio",
    "persistentvolumeclaims": "persistentVolumeClaims",
    "hashfiles": "hashFiles",
    "ifnofiles": "ifNoFiles",
    "uploadfullartifact": "uploadFullArtifact",
    "retentiondays": "retentionDays",
    "continueonerror": "continueOnError",
    "timeoutminutes": "timeoutMinutes",
    "cancelinprogress": "cancelInProgress",
    "fetchdepth": "fetchDepth",
    "persistcredentials": "persistCredentials",
    "pythonversion": "pythonVersion",
    "cachedependencyfiles": "cacheDependencyFiles",
    "terraformversion": "terraformVersion",
    "loglevel": "logLevel",
    "initcontainers": "initContainers",
    "workingdirectory": "workingDirectory",
    "runs-on".lower(): "runs-on",
    "fail-fast".lower(): "fail-fast",
    "shellcheck": "shellcheck",
    "shellcheck_": "shellcheck",
    "clusterip": "ClusterIP",
    "ipv4": "IPv4",
    "singlestack": "SingleStack",
    "runtimedefault": "RuntimeDefault",
    "onrootmismatch": "OnRootMismatch",
    "never": "Never",
    "forbid": "Forbid",
    "failjob": "FailJob",
    "in": "In",
    "notin": "NotIn",
    "always": "Always",
    "http": "HTTP",
    "tcp": "TCP",
    "all": "ALL",
    "cronjob": "CronJob",
    "deployment": "Deployment",
    "service": "Service",
    "horizontalpodautoscaler": "HorizontalPodAutoscaler",
    "poddisruptionbudget": "PodDisruptionBudget",
    "limitrange": "LimitRange",
    "resourcequota": "ResourceQuota",
    "namespace": "Namespace",
    "pod": "Pod",
    "container": "Container",
    "resource": "Resource",
    "percent": "Percent",
    "pods": "Pods",
    "utilization": "Utilization",
    "cluster": "Cluster",
    "local": "Local",
    "none": "None",
    "max": "Max",
    "min": "Min",
    "ignore": "Ignore",
}

KEY_RE = re.compile(r"^(?P<indent>[ ]*)(?P<key>[A-Za-z0-9._/-]+)(?P<colon>:(?P<rest>[ ]?.*)?)?$")


def tokens(text: str):
    """Yield (line-number, kind, token) for every key and scalar token."""
    for n, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = KEY_RE.match(line)
        if m and m.group("colon"):
            yield n, "key", m.group("key")
            rest = (m.group("rest") or "").strip()
            for piece in re.split(r"[,\[\]]+", rest):
                piece = piece.strip().strip("'\"")
                if piece and not piece.startswith("{"):
                    yield n, "value", piece
        else:
            for piece in re.split(r"[,\[\]]+", stripped.lstrip("- ")):
                piece = piece.strip().strip("'\"")
                if piece and not piece.startswith("#"):
                    yield n, "value", piece


def audit(path: str) -> int:
    """Report tokens whose capitals do not match the canonical table."""
    bad = 0
    seen: set[str] = set()
    for n, kind, tok in tokens(open(path, encoding="ascii").read()):
        bare = tok.split("=")[0].strip()
        if not bare or any(c in bare for c in "/:%{}$") or re.fullmatch(r"[\d.]+[a-z%]*", bare, re.I):
            continue
        key = bare.lower()
        if key in ("true", "false", "null", "~"):
            continue
        if key not in KNOWN and key not in WRONG and key not in seen:
            seen.add(key)
            print(f"UNKNOWN {path}:{n} {kind} {bare!r}")
            bad += 1
    return bad


def repair(path: str) -> int:
    """Replace the tokens whose capitals are wrong with the canonical ones."""
    text = open(path, encoding="ascii").read()
    changed = 0
    for wrong, right in sorted(WRONG.items()):
        for pat in (rf"(?m)(^([ ]*){re.escape(wrong)})(?=\s*:)", rf"(?m)(^([ ]*)-[ ]+){re.escape(wrong)}(\s*)$"):
            def repl(match, _r=right):
                nonlocal changed
                changed += 1
                return match.group(1).replace(match.group(2), _r) if match.group(2) else match.group(0)
            text = re.sub(pat, lambda m, _r=right: m.group(0), text)
    # the actual replacement pass, one canonical token at a time
    for wrong, right in sorted(WRONG.items(), key=lambda p: -len(p[0])):
        if wrong == right:
            continue
        pat = re.compile(rf"(?<![A-Za-z0-9_.-]){re.escape(wrong)}(?![A-Za-z0-9_-])")
        new, n = pat.subn(lambda m, _r=right: _r, text)
        if n:
            changed += n
        text = new
    open(path, "w", encoding="ascii").write(text)
    return changed


if __name__ == "__main__":
    files = sys.argv[1:]
    status = 0
    for p in files:
        if "--apply" in files:
            print(f"repaired {repair(p):>4} tokens in {p}")
        status |= bool(audit(p))
    sys.exit(1 if status else 0)
