# harbourbank-gitops

Desired state of the **Harbour Bank** agentic DevOps lab cluster (a fictional bank, synthetic data only).
ArgoCD continuously syncs the cluster to this repo, so Git is the only way anything changes -
for humans and AI agents alike.

## Layout

| Path | Purpose |
|---|---|
| `bootstrap/` | One-time steps to (re)build the cluster: k3d config, ArgoCD install, root app |
| `platform/` | One ArgoCD `Application` per cluster add-on (watched by the `root` app) |
| `platform/values/` | Helm values for those add-ons |
| `platform/manifests/` | Plain manifests deployed alongside add-ons (e.g. SealedSecrets) |
| `apps/harbourbank/base/` | accounts-api, its Postgres (CloudNativePG) and the migration Job |
| `apps/harbourbank/overlays/` | dev / qa / prod differences; each folder becomes an ArgoCD app (`platform/harbourbank.yaml`) |

## Change control

`main` accepts changes only through pull requests; anything that reaches production
(see `.github/CODEOWNERS`) needs a code owner's approval (every PR needs 1 approval). CI's deploy key is the one
direct writer, for dev image bumps. Promotion PRs (dev -> qa -> prod) are opened by the
`promote` workflow. Settings are applied by `./bootstrap/github-governance.sh` (repo admin).

## Daily stop / start

State survives a stop: ArgoCD, Grafana, Loki logs and the sealed-secrets key all live in the node containers' volumes.

```bash
./bootstrap/lab-stop.sh    # end of day (~10s)
./bootstrap/lab-start.sh   # next day: starts the cluster, waits until every ArgoCD app is Synced/Healthy (~30s-2min)
```

Both scripts also start and stop the **image caches** (`bootstrap/image-cache.sh`): two local
pull-through registries, for ghcr.io and Docker Hub, on the cluster network with no host port.
Each image is downloaded once and served to all three nodes; if a cache is down, nodes pull from
the internet as before. The mirror settings live in `bootstrap/k3d-config.yaml`.

Start Docker Desktop first. Don't `k3d cluster delete` - that destroys the sealed-secrets key, so the
committed SealedSecrets could no longer be decrypted.

## Rebuild from scratch

```bash
./bootstrap/bootstrap.sh
```

## Harbour Bank environments

| Env | URL | Changed by |
|---|---|---|
| dev | <http://accounts-dev.localhost:8080> | CI, on every merge to `harbourbank-app` main |
| qa | <http://accounts-qa.localhost:8080> | promotion PR |
| prod | <http://accounts.localhost:8080> | promotion PR approved by a code owner |

Rollout order inside each environment (ArgoCD sync waves): database healthy -> migration Job succeeds -> API.

## Customer simulator

Each environment has synthetic customers (`apps/harbourbank/base/customer_simulator.py`): they check
balances, read statements, make deposits and pay each other, each account mostly paying a stable circle
of payees, a couple of times an hour. Now and then fraud happens, so fraud-check has real work:

| Scenario | About every | What it is |
|---|---|---|
| **Scam** | 10 min (`SIM_SCAM_EVERY_SECONDS`) | The real customer is tricked (a fake "prize release fee") into one large payment to someone they have never paid before. |
| **Account takeover** | 30 min (`SIM_TAKEOVER_EVERY_SECONDS`) | A criminal has got into a customer's online banking (stolen password, phished one-time code, malware) and empties the account fast: many small transfers in quick succession to one new payee. |

**Account takeover, in more detail.** The criminal logs in as the customer, correctly, so each transfer
looks ordinary on its own (around 60.00). Only the pattern gives it away: an account that normally makes a
couple of transfers an hour suddenly makes a dozen in a minute, all to the same new payee. The simulator
sends 12 transfers of 40.00-90.00, 1-3 seconds apart. fraud-check's "too many transfers in an hour" rule
blocks from the 10th transfer in an hour, so the first 9 or 10 go through and the rest are rejected
`fraud_suspected`: speed rules limit the loss rather than prevent it entirely.

Both scenarios pay a **mule account**: an account that receives stolen money to move it on. Every scenario
opens a fresh one for the mule customer (`mule@fraud.sim.harbourbank.example`, outside the everyday
customers). Each run logs `"msg": "fraud scenario"` with what the bank actually did, the ground truth to
compare with fraud-check's decisions. `0` switches a scenario off.

## UIs

| UI | URL |
|---|---|
| ArgoCD | <http://argocd.localhost:8080> |
| Grafana | <http://grafana.localhost:8080> |
| Prometheus | <http://prometheus.localhost:8080> |
| Alertmanager | <http://alertmanager.localhost:8080> |
