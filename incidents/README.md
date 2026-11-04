# Incident records

One YAML file per incident: when service was affected, when someone knew, when it was restored, and
which change caused it. This folder is the lab's system of record for failures, as a bank's incident
(ITSM) tool would be. The Harbour Bank ops MCP server's `delivery_metrics` reads it to measure the
change failure rate and the time to restore service (two of the four DORA metrics).

Nothing here is deployed: ArgoCD doesn't read this folder.

## Fields

| Field | Meaning |
|---|---|
| `id` | `YYYY-MM-DD-short-name`, the same as the file name |
| `title` | one line: what went wrong |
| `environments` | the environments affected: `dev`, `qa`, `prod` |
| `started` | when service was first affected (UTC, ISO 8601, e.g. `2026-10-29T07:53:00Z`) |
| `detected` | when a person knew: the first alert that reached someone, or the first person to notice. An alert that fired but reached nobody doesn't count (say so in `detected_by`), so the record shows the gap |
| `restored` | when service was back to normal; leave it out while the incident is open |
| `detected_by` | who or what noticed: an alert, a smoke test, an engineer, a customer |
| `caused_by` | the change that caused it: `gitops#<PR>` for a pull request, `gitops@<sha7>` for a direct push. Leave it out when no change caused it: those incidents are reported, but don't count as change failures |
| `remediation` | what restored service: `rollback`, `fix forward`, `manual recovery`, `none (recovered by itself)` |
| `impact` | who or what was affected, and how badly |
| `follow_up` | the permanent fix, e.g. a PR |
| `evidence` | where the facts come from; say if the times are approximate |

Record an incident when a change needed remediation (a rollback, a fix or a manual recovery), or when
service was affected for any other reason. A Degraded status that recovered by itself, with no impact,
isn't an incident.
