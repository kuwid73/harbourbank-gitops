"""Does every NetworkPolicy pod selector match a pod this environment actually runs?

Reads one environment's rendered manifests (one JSON document per line) on stdin.

Drill 5 (2026-11-11): a policy was "tightened" to require a label the Deployment carried but its
pods did not. Kubernetes accepts a selector that matches nothing, so accounts-api was silently cut
off from fraud-check. A selector that matches no pod template is almost always that mistake.

Checked: each policy's own podSelector, and every same-namespace podSelector in its ingress `from`
and egress `to`. Not checked: peers with a namespaceSelector or ipBlock (other namespaces' pods
aren't rendered here).
"""
import json
import sys


def pod_templates(docs):
    """(what, labels) for every kind of pod these manifests create."""
    for d in docs:
        kind, name, spec = d.get("kind"), d.get("metadata", {}).get("name"), d.get("spec") or {}
        if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
            yield f"{kind}/{name}", spec.get("template", {}).get("metadata", {}).get("labels") or {}
        elif kind == "CronJob":
            template = spec.get("jobTemplate", {}).get("spec", {}).get("template", {})
            yield f"{kind}/{name}", template.get("metadata", {}).get("labels") or {}
        elif kind == "Cluster" and d.get("apiVersion", "").startswith("postgresql.cnpg.io/"):
            # CloudNativePG creates the database pods itself, with these labels
            yield f"{kind}/{name}", {"cnpg.io/cluster": name, "cnpg.io/podRole": "instance"}


def matches(selector, labels):
    for key, value in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != value:
            return False
    for e in selector.get("matchExpressions") or []:
        key, op, values = e["key"], e["operator"], e.get("values") or []
        ok = {"In": labels.get(key) in values, "NotIn": labels.get(key) not in values,
              "Exists": key in labels, "DoesNotExist": key not in labels}[op]
        if not ok:
            return False
    return True


def main():
    docs = [json.loads(line) for line in sys.stdin if line.strip()]
    templates = list(pod_templates(docs))
    problems = checked = 0
    for d in docs:
        if d.get("kind") != "NetworkPolicy":
            continue
        name, spec = d["metadata"]["name"], d.get("spec") or {}
        selectors = [("podSelector (the pods it protects)", spec.get("podSelector") or {})]
        for direction, peers_key in (("ingress", "from"), ("egress", "to")):
            for n, rule in enumerate(spec.get(direction) or []):
                for peer in rule.get(peers_key) or []:
                    if "podSelector" in peer and "namespaceSelector" not in peer:
                        selectors.append((f"{direction}[{n}].{peers_key} podSelector", peer["podSelector"] or {}))
        for where, selector in selectors:
            checked += 1
            if not any(matches(selector, labels) for _, labels in templates):
                problems += 1
                print(f"   FAILED: NetworkPolicy/{name} {where} {json.dumps(selector)} matches no pod.")
                print("           Pods here carry: " + "; ".join(
                    f"{what} {json.dumps(labels)}" for what, labels in templates))
    print(f"   {checked} selector(s) checked, {problems} matching no pod")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
