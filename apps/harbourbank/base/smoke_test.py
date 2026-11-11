"""Post-deployment smoke test, run by ArgoCD after every sync (PostSync hook).

Read-only by design - it must be safe in production, so it never moves money:
  1. the API is ready (which includes reaching its database)
  2. it serves the commit this Job's image was built from, in the expected environment
  3. a real database query through the API succeeds
  4. the API can reach the services it calls (GET /dependencies; today: fraud-check).
     Drill 5 (2026-11-11): a NetworkPolicy change cut the API off from fraud-check while every
     pod stayed Ready. Only the API can tell, so it is asked. Images without the endpoint skip this.

Standard library only, so it works with any accounts-api image version.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE_URL = os.environ.get("SMOKE_BASE_URL", "http://accounts-api")


def get(path):
    try:
        with urllib.request.urlopen(BASE_URL + path, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except (urllib.error.URLError, TimeoutError) as exc:   # refused, timed out, DNS
        return 0, str(exc).encode()


def log(level, msg, **fields):
    print(json.dumps({"level": level, "logger": "smoke_test", "msg": msg, **fields}), flush=True)


def main():
    failures = []

    status, body = get("/readyz")
    if status != 200:
        failures.append(f"/readyz returned {status or body.decode()}")

    status, body = get("/info")
    info = json.loads(body) if status == 200 else {}
    if status != 200:
        failures.append(f"/info returned {status or body.decode()}")
    expected = {"git_sha": os.environ["GIT_SHA"], "environment": os.environ["ENVIRONMENT"]}
    for key, want in expected.items():
        if info.get(key) != want:
            failures.append(f"/info {key} is {info.get(key)!r}, expected {want!r}")

    status, body = get("/accounts?account_number=HB0000000000")
    if status != 200 or json.loads(body) != []:
        failures.append(f"account lookup returned {status or body.decode()}")

    status, body = get("/dependencies")
    dependencies = {}
    if status == 404:
        log("INFO", "dependency check skipped: this image has no /dependencies")
    elif status != 200:
        failures.append(f"/dependencies returned {status or body.decode()}")
    else:
        for name, state in json.loads(body).items():
            dependencies[name] = state.get("status")
            if state.get("status") not in ("ok", "not_configured"):
                failures.append(f"accounts-api cannot reach {name}: {state.get('error') or state.get('status')}")

    if failures:
        log("ERROR", "smoke test failed", failures=failures, dependencies=dependencies, **expected)
        sys.exit(1)
    log("INFO", "smoke test passed", dependencies=dependencies, **expected)


if __name__ == "__main__":
    main()
