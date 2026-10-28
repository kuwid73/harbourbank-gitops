"""Synthetic customer traffic for Harbour Bank (simulated customers, synthetic data only).

  python customer_simulator.py run         create the customers if needed, then act like them forever
  python customer_simulator.py salary-day  pay every customer at once, then everyone pays rent and bills

Like a well-behaved banking client, every money movement carries an Idempotency-Key and a
failed request (timeout, 5xx) is retried with the SAME key, so a retry can never pay twice.
Salary-day keys are derived from the run's name: if Kubernetes re-runs a crashed salary job,
the API replays the payments already made instead of paying them again.

Standard library only: runs from the accounts-api image with this file mounted from a ConfigMap.
"""
import json
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

API_URL = os.environ.get("API_URL", "http://accounts-api")
CUSTOMERS = int(os.environ.get("SIM_CUSTOMERS", "20"))
REQUESTS_PER_SECOND = float(os.environ.get("SIM_REQUESTS_PER_SECOND", "1"))
SALARY_CONCURRENCY = int(os.environ.get("SALARY_CONCURRENCY", "20"))
RUN_ID = os.environ.get("RUN_ID") or f"manual-{uuid.uuid4().hex[:8]}"
# Marks simulated customers; .example is reserved and can never be a real address
DOMAIN = "sim.harbourbank.example"
KEY_NAMESPACE = uuid.UUID("5f0c2a1e-3b7d-4c55-9a8e-6d2b1f4e8c90")

FIRST_NAMES = ["Amara", "Bastian", "Chiara", "Dmitri", "Elif", "Farid", "Greta", "Hiro", "Ines", "Jonas",
               "Kalani", "Leila", "Mateo", "Nadia", "Oskar", "Priya", "Quentin", "Rosa", "Sven", "Tariq",
               "Uma", "Viktor", "Wen", "Ximena", "Yusuf", "Zara"]
LAST_NAMES = ["Abara", "Brandt", "Castell", "Dimitrova", "Eriksen", "Fontaine", "Gallo", "Haddad", "Ivanova",
              "Jansen", "Kowalski", "Lindqvist", "Moreau", "Nakamura", "Okafor", "Petrov", "Quinn", "Rossi",
              "Silva", "Tanaka", "Ueda", "Varga", "Weber", "Xu", "Yilmaz", "Zimmer"]
PAYMENT_REFERENCES = ["Coffee", "Dinner split", "Groceries", "Concert tickets", "Birthday gift",
                      "Loan repayment", "Shared taxi", "Football club fees", "Book club", "Car pool"]

stats = Counter()
stats_lock = threading.Lock()


def log(level, msg, **fields):
    print(json.dumps({"level": level, "logger": "customer_simulator", "msg": msg, **fields}), flush=True)


def count(label):
    with stats_lock:
        stats[label] += 1


def call(method, path, body=None, key=None):
    headers = {"Content-Type": "application/json", "X-Request-ID": f"sim-{uuid.uuid4().hex}"}
    if key:
        headers["Idempotency-Key"] = key
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(API_URL + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b"null")
        except ValueError:
            return exc.code, None
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        return 0, {"error": type(exc).__name__}


def move_money(action, path, body, key=None):
    """POST a money movement; retry once with the same key if the outcome is unknown."""
    key = key or str(uuid.uuid4())
    status, data = call("POST", path, body, key)
    if status == 0 or status >= 500:
        count(f"{action} retried")
        time.sleep(1)
        status, data = call("POST", path, body, key)
    outcome = str(status)
    if isinstance(data, dict) and (data.get("reject_reason") or data.get("error")):
        outcome += f" {data.get('reject_reason') or data.get('error')}"
    count(f"{action} {outcome}")
    return status, data


def stable_key(*parts):
    return str(uuid.uuid5(KEY_NAMESPACE, "/".join(str(p) for p in parts)))


def paged(path):
    items, offset = [], 0
    sep = "&" if "?" in path else "?"
    while True:
        status, page = call("GET", f"{path}{sep}limit=200&offset={offset}")
        if status != 200:
            raise RuntimeError(f"GET {path} returned {status}")
        items += page
        if len(page) < 200:
            return items
        offset += 200


def load_population():
    """Simulated customers and their active accounts: {customer_id: [account, ...]}."""
    customers = [c for c in paged("/customers") if c["email"].endswith("@" + DOMAIN) and c["active"]]
    ids = {c["id"] for c in customers}
    population = {c["id"]: [] for c in customers}
    for account in paged("/accounts"):
        if account.get("customer_id") in ids and account["status"] == "active":
            population[account["customer_id"]].append(account)
    return customers, population


def ensure_customers():
    """Create the simulated customers (idempotent: finds the ones that already exist)."""
    customers, population = load_population()
    existing = {c["email"] for c in customers}
    created = 0
    for i in range(CUSTOMERS):
        first, last = FIRST_NAMES[i % len(FIRST_NAMES)], LAST_NAMES[(i * 7) % len(LAST_NAMES)]
        email = f"{first}.{last}.{i}@{DOMAIN}".lower()
        if email in existing:
            continue
        status, _ = call("POST", "/customers", {"full_name": f"{first} {last}", "email": email})
        if status not in (201, 409):
            raise RuntimeError(f"creating customer returned {status}")
        created += 1
    if created:
        customers, population = load_population()
    for customer in customers:            # also repairs a customer left without accounts by a crash
        if population[customer["id"]]:
            continue
        currencies = ["USD", "EUR"] if random.random() < 0.2 else ["USD"]
        for currency in currencies:
            status, account = call("POST", "/accounts", {"customer_id": customer["id"], "currency": currency})
            if status == 201:
                move_money("deposit", f"/accounts/{account['id']}/deposits",
                           {"amount_cents": random.randint(500, 5000) * 100, "reference": "Opening deposit"},
                           key=stable_key("opening", account["id"]))
    customers, population = load_population()
    log("INFO", "customers ready", customers=len(customers), created=created,
        accounts=sum(len(a) for a in population.values()))
    return population


# --- everyday behaviour --------------------------------------------------------------

def pick_account(population, currency=None):
    accounts = [a for accs in population.values() for a in accs if currency in (None, a["currency"])]
    return random.choice(accounts) if accounts else None


def check_balance(population):
    customer_id = random.choice(list(population))
    status, _ = call("GET", f"/accounts?customer_id={customer_id}")
    count(f"balance {status}")


def view_statement(population):
    status, _ = call("GET", f"/accounts/{pick_account(population)['id']}/statement?limit=20")
    count(f"statement {status}")


def pay_someone(population):
    source = pick_account(population)
    target = pick_account(population, source["currency"])
    if target is None or target["id"] == source["id"]:
        return
    # Mostly small payments; now and then a large one that may exceed the balance
    amount = random.randint(5, 300) if random.random() < 0.9 else random.randint(2000, 6000)
    move_money("transfer", "/transfers", {"from_account_id": source["id"], "to_account_id": target["id"],
                                          "amount_cents": amount * 100,
                                          "reference": random.choice(PAYMENT_REFERENCES)})


def cash_deposit(population):
    account = pick_account(population)
    move_money("deposit", f"/accounts/{account['id']}/deposits",
               {"amount_cents": random.randint(20, 500) * 100, "reference": "Cash deposit"})


def wrong_currency(population):
    """A customer mistake: sending USD to a EUR account (rejected: currency_mismatch)."""
    source, target = pick_account(population, "USD"), pick_account(population, "EUR")
    if source and target:
        move_money("transfer", "/transfers", {"from_account_id": source["id"], "to_account_id": target["id"],
                                              "amount_cents": 1000, "reference": "Holiday money"})


ACTIONS = [(check_balance, 35), (view_statement, 25), (pay_someone, 30), (cash_deposit, 8), (wrong_currency, 2)]


def run():
    log("INFO", "customer simulator starting", api_url=API_URL, customers=CUSTOMERS,
        requests_per_second=REQUESTS_PER_SECOND)
    while call("GET", "/readyz")[0] != 200:
        log("INFO", "waiting for accounts-api to be ready")
        time.sleep(5)
    population = ensure_customers()
    functions, weights = zip(*ACTIONS, strict=True)
    next_report = next_refresh = time.monotonic() + 60
    while True:
        try:
            random.choices(functions, weights)[0](population)
        except Exception as exc:  # noqa: BLE001 - keep simulating; the API is what's being observed
            count(f"simulator error {type(exc).__name__}")
        time.sleep(random.expovariate(REQUESTS_PER_SECOND))    # Poisson arrivals, like real customers
        now = time.monotonic()
        if now >= next_report:
            with stats_lock:
                log("INFO", "last minute", outcomes=dict(sorted(stats.items())))
                stats.clear()
            next_report = now + 60
        if now >= next_refresh:   # pick up account changes (e.g. frozen in the UI)
            try:
                population = load_population()[1]
            except RuntimeError as exc:
                log("WARNING", "could not refresh customers", error=str(exc))
            next_refresh = now + 300


# --- salary day ------------------------------------------------------------------------

def salary_day():
    started = time.monotonic()
    # Seeded by the run's name: a re-run of the same job computes the same payroll, so its
    # stable keys replay the original payments (a different amount would be a key conflict)
    rng = random.Random(RUN_ID)
    _, population = load_population()
    payroll = {cid: next((a for a in accs if a["currency"] == "USD"), None) for cid, accs in population.items()}
    payroll = {cid: acc for cid, acc in payroll.items() if acc}
    salaries = {cid: rng.randint(2500, 9000) * 100 for cid in payroll}
    log("INFO", "salary run starting", run_id=RUN_ID, employees=len(payroll), concurrency=SALARY_CONCURRENCY)

    with ThreadPoolExecutor(SALARY_CONCURRENCY) as pool:
        for cid, account in payroll.items():
            pool.submit(move_money, "salary", f"/accounts/{account['id']}/deposits",
                        {"amount_cents": salaries[cid], "reference": f"Salary {RUN_ID}"},
                        stable_key(RUN_ID, "salary", cid))

    # Everyone pays rent (about 30% of salary) and a few bills to other customers, all at once
    customer_ids = list(payroll)
    with ThreadPoolExecutor(SALARY_CONCURRENCY) as pool:
        for cid, account in payroll.items():
            payments = [("Rent", salaries[cid] * 3 // 10)]
            payments += [(bill, rng.randint(40, 250) * 100)
                         for bill in rng.sample(["Electricity", "Water", "Phone", "Internet", "Insurance"], 3)]
            for n, (reference, amount) in enumerate(payments):
                payee = payroll[rng.choice([c for c in customer_ids if c != cid])]
                pool.submit(move_money, "bill", "/transfers",
                            {"from_account_id": account["id"], "to_account_id": payee["id"],
                             "amount_cents": amount, "reference": reference},
                            stable_key(RUN_ID, "bill", cid, n))

    outcomes = dict(sorted(stats.items()))
    # "<action> <status> [reason]": anything but 2xx or a business rejection (422) failed
    failed = sum(v for k, v in outcomes.items()
                 if k.split()[1].isdigit() and not k.split()[1].startswith(("2", "422")))
    log("INFO" if not failed else "ERROR", "salary run finished", run_id=RUN_ID, outcomes=outcomes,
        failed_requests=failed, duration_seconds=round(time.monotonic() - started, 1))
    return 1 if failed else 0


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "run"
    if mode == "run":
        run()
    elif mode == "salary-day":
        sys.exit(salary_day())
    else:
        sys.exit(f"unknown mode {mode!r}; use 'run' or 'salary-day'")
