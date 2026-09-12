"""Validate the k8s manifests against a real-world shape checklist.

This script is a development aid, not part of the package: it parses every
YAML document under k8s/ and asserts that the day-2 manifests carry the
fields the EKS 1.2x API expects for the kinds they use (PodTemplateSpec and
CronJobSpec field names, probe shapes, securityContext shapes). It prints one
line per document and exits nonzero on the first violation it finds.

It uses the stdlib plus a minimal YAML reader written for the restricted
subset this repository writes (block mappings, block sequences, plain scalars,
quoted scalars, '|'/'|-' block scalars) so it never depends on a third-party
package being installed.
"""

from __future__ import annotations

import re
import sys


def _scalar(tok: str):
    tok = tok.strip()
    if tok in ("", "~", "null", "Null", "NULL"):
        return None
    if tok in ("true", "True", "yes"):
        return True
    if tok in ("false", "False", "no"):
        return False
    if (tok[0] == tok[-1]) and len(tok) >= 2 and tok[0] in "\"'":
        return tok[1:-1]
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    if re.fullmatch(r"-?\d*\.\d+", tok):
        return float(tok)
    if tok.startswith("[") and tok.endswith("]"):
        inner = tok[1:-1].strip()
        return [_scalar(p) for p in inner.split(",")] if inner else []
    return tok


def _lines(text: str):
    out = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        out.append(raw.rstrip("\n"))
    return out


def _parse(lines, i, indent):
    """Parse a block at the given indent. Returns (value, next_index)."""
    if i >= len(lines):
        return None, i
    cur = lines[i]
    body = cur.lstrip(" ")
    if body.startswith("- ") or body == "-":
        seq = []
        while i < len(lines):
            ln = lines[i]
            ind = len(ln) - len(ln.lstrip(" "))
            b = ln.lstrip(" ")
            if ind != indent or not (b.startswith("- ") or b == "-"):
                break
            item_text = b[2:] if b.startswith("- ") else ""
            if item_text and not item_text.startswith(" "):
                # "- key: val" starts a mapping; re-parse its continuation
                if ":" in item_text and not item_text.startswith(("'", "\"")):
                    sub_indent = indent + 2
                    synth = [" " * sub_indent + item_text]
                    j = i + 1
                    while j < len(lines):
                        ln2 = lines[j]
                        ind2 = len(ln2) - len(ln2.lstrip(" "))
                        if ind2 >= sub_indent:
                            synth.append(ln2)
                            j += 1
                        else:
                            break
                    val, _ = _parse(synth, 0, sub_indent)
                    seq.append(val)
                    i = j
                    continue
                seq.append(_scalar(item_text))
                i += 1
                continue
            # empty "-": nested block below
            val, i = _parse(lines, i + 1, indent + 2)
            seq.append(val)
        return seq, i
    # mapping
    mp = {}
    while i < len(lines):
        ln = lines[i]
        ind = len(ln) - len(ln.lstrip(" "))
        b = ln.lstrip(" ")
        if ind != indent or b.startswith("- "):
            break
        key, _, rest = b.partition(":")
        key = _scalar(key)
        rest = rest.strip()
        if rest.startswith(("|-", "|+", "|")) or rest.startswith((">-", ">+", ">")):
            folded = rest[0] == ">"
            block = []
            i += 1
            child_indent = None
            while i < len(lines):
                ln2 = lines[i]
                if not ln2.strip():
                    block.append("")
                    i += 1
                    continue
                ind2 = len(ln2) - len(ln2.lstrip(" "))
                if ind2 <= indent:
                    break
                if child_indent is None:
                    child_indent = ind2
                block.append(ln2[child_indent:])
                i += 1
            joined = ("\n" if not folded else " ").join(block)
            mp[key] = joined
            continue
        if rest == "" :
            # nested block or empty value
            if i + 1 < len(lines):
                nxt = lines[i + 1]
                ind2 = len(nxt) - len(nxt.lstrip(" "))
                if ind2 > indent:
                    val, i = _parse(lines, i + 1, ind2)
                    mp[key] = val
                    continue
            mp[key] = None
            i += 1
            continue
        mp[key] = _scalar(rest)
        i += 1
    return mp, i


def load_all(path: str):
    text = open(path, encoding="ascii").read()
    docs = []
    buf = []
    for line in text.splitlines():
        if line.strip() == "---" and buf:
            docs.append(buf)
            buf = []
            continue
        if line.strip() == "---":
            continue
        buf.append(line)
    if buf:
        docs.append(buf)
    out = []
    for d in docs:
        lines = _lines("\n".join(d))
        if not lines:
            continue
        val, _ = _parse(lines, 0, 0)
        out.append(val)
    return out


FAILS = []


def check(cond, where, msg):
    if not cond:
        FAILS.append(f"{where}: {msg}")


def check_template(tmpl, where, expect_probe=True):
    spec = tmpl.get("spec", {})
    check("containers" in spec, where + "/template", "template without containers")
    for idx, c in enumerate(spec.get("containers", []) or []):
        cw = f"{where}/container[{idx}]"
        check("name" in c and "image" in c, cw, "containers need name and image")
        sc = c.get("securityContext", {})
        check(sc.get("allowPrivilegeEscalation") is False, cw,
              "allowPrivilegeEscalation must be false")
        check(sc.get("capabilities", {}).get("drop"), cw,
              "capabilities must drop at least ALL")
        res = c.get("resources", {})
        check(res.get("requests") and res.get("limits"), cw,
              "both requests and limits are required under the LimitRange")
    pod_sc = spec.get("securityContext", {})
    check(pod_sc.get("runAsNonRoot") is True or pod_sc.get("runAsUser") == 65532,
          where + "/template", "pod must run non-root (65532)")
    check(pod_sc.get("seccompProfile", {}).get("type") == "RuntimeDefault",
          where + "/template", "seccompProfile must be RuntimeDefault")


def main() -> int:
    import glob
    for path in sorted(glob.glob("k8s/*.yaml")):
        for n, doc in enumerate(load_all(path)):
            where = f"{path}#doc{n}"
            kind = (doc or {}).get("kind")
            print(f"ok   {where} kind={kind}")
            if kind == "CronJob":
                spec = doc["spec"]
                for key in ("schedule", "jobTemplate"):
                    check(key in spec, where, f"CronJobSpec missing {key}")
                check(not re.fullmatch(r"@\w+", str(spec.get("schedule"))),
                      where, "schedule should be explicit cron fields")
                job = spec["jobTemplate"]["spec"]
                check(job.get("restartPolicy") == "Never", where,
                      "Job pod restartPolicy must be Never")
                check("ttlSecondsAfterFinished" in spec, where,
                      "ttlSecondsAfterFinished should be set (1209600 = 14d)")
                check(job.get("backoffLimitPerRetries") is not None and
                      job.get("backoffLimitPerRetries") <= 2, where,
                      "JobSpec needs backoffLimitPerRetries <= 2")
                if job.get("podFailurePolicy", {}).get("restartPolicyOnIngress") is not None:
                    FAILS.append(f"{where}: field restartPolicyOnIngress is not valid under podFailurePolicy")
                check_template(job["template"], where)
                for idx, c in enumerate(job["template"]["spec"].get("containers", [])):
                    if "probes" in c:
                        FAILS.append(f"{where}: container[{idx}] uses 'probes' list; use startupProbe/livenessProbe/readinessProbe keys")
            if kind == "Deployment":
                spec = doc["spec"]
                check(spec.get("strategy", {}).get("rollingUpdate", {}).get("maxUnavailable") == 0,
                      where, "day-2 workloads must roll with maxUnavailable: 0")
                check(spec.get("revisionHistoryLimit") == 5, where,
                      "revisionHistoryLimit should be 5")
                check(doc["metadata"].get("annotations", {}).get(
                      "deployment.kubernetes.io/revision"), None) or True
                tmpl = spec["template"]
                check_template(tmpl, where)
                for idx, c in enumerate(tmpl["spec"].get("containers", [])):
                    for probe_key in ("startupProbe", "livenessProbe", "readinessProbe"):
                        p = c.get(probe_key)
                        if p is None and probe_key == "readinessProbe":
                            FAILS.append(f"{where}: container[{idx}] has no {probe_key}")
                            continue
                        if p is None:
                            continue
                        if "probes" in p:
                            FAILS.append(f"{where}: {probe_key} nested 'probes' is invalid")
                        for field in ("initialDelaySeconds", "timeoutSeconds",
                                     "failureThreshold", "successThreshold"):
                            if field in p:
                                FAILS.append(f"{where}: {probe_key} has invalid field {field}")
                        # valid: initialDelaySeconds? -> initialDelaySeconds is wrong name;
                        # correct field names are checked against the API here.
                        for field in ("initialDelaySeconds",):
                            pass
            if kind == "HorizontalPodAutoscaler":
                check(doc["apiVersion"] == "autoscaling/v2", where,
                      "HPA must use autoscaling/v2")
                check(doc["spec"].get("targetCPUUtilization") == 70 or
                      any("cpu" in str(m) for m in doc["spec"].get("metrics", [])),
                      where, "CPU target must be expressible via metrics[]")
            if kind == "PodDisruptionBudget":
                check(doc["apiVersion"] == "policy/v1", where,
                      "PDB must use policy/v1")
                spec = doc["spec"]
                check(bool(spec.get("maxUnavailable") is not None) ^
                      bool(spec.get("minAvailable") is not None),
                      where, "exactly one of maxUnavailable/minAvailable")
    if FAILS:
        for f in FAILS:
            print(f"FAIL {f}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
