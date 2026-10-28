"""Post-deployment smoke test, run by ArgoCD after every sync (PostSync hook).

Read-only by design - it must be safe in production, so it never moves money:
  1. the API is ready (which includes reaching its database)
  2. it serves the commit this Job's image was built from, in the expected environment
  3. a real database query through the API succeeds

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

    if failures:
        log("ERROR", "smoke test failed", failures=failures, **expected)
        sys.exit(1)
    log("INFO", "smoke test passed", **expected)


if __name__ == "__main__":
    main()
