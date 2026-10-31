# appsense-ops (NEF-3455, P0)

Read/QA [MCP](https://modelcontextprotocol.io) stdio server over the Appsense
**QA** environment (`appsense-qa` only — P0). Gives Hermes agent profiles
(whose first consumer is qa-bob's re-verification queue for NEF-3404/3428/3430)
a safe, audited, read-mostly view of billing-api and pat-api.

## Guarantees (P0 scope)

| Control | Behavior |
|---|---|
| QA-only | Startup fails closed if any base URL host is not `api.qa.appsensesolutions.com`. `APPSENSE_OPS_ALLOW_INSECURE_BASE` escape hatch exists for tests only. |
| Read-mostly | 9 of 10 tools are GETs. `billing_rule_validate` is a POST but side-effect-free by upstream contract. No write tool is registered. |
| Row caps | Server-side `maxRows` (default 50) trims collections and marks `_truncated`. |
| Per-profile allowlist | `APPSENSE_OPS_ALLOWLIST` filters registration AND is re-checked at call time. |
| Kill switch | `APPSENSE_OPS_KILL_SWITCH=1` starts with zero tools registered. |
| Audit sink | One JSONL line per call: `ts, actor, profile, env, tool, args_sha256, rows, latency_ms, status`. **Metadata only — never raw args or response bodies** (tool args can carry PHI-shaped filters). |
| Auth (Phase A, token lane) | `POST {auth}/Login {email,password,returnSecureToken,opaqueId,isRememberMe:false}` -> idToken (3600 s), `Authorization: Bearer` on every call per live QA probe (comment 22595); proactive refresh at `exp-60s` = re-login; 401 -> one forced refresh + one replay. SID-cookie `Login/tokens` lane available via `APPSENSE_OPS_USE_TOKEN_EXCHANGE=1`. Credentials/tokens never logged, never in results, never in audit. |
| Correlation | Every upstream call carries `x_appsense_correlationId: <agent>:<uuid>` (header mandated by the billing controllers). |

## Tools

| Tool | Upstream |
|---|---|
| `billing_claims_summary` | `GET /billingv2/api/v1/dashboard/claims/summary` |
| `billing_claims_by_status` | `GET .../v1/accounting-dashboard/claims-by-status` |
| `billing_eras_by_date` | `GET .../v1/accounting-dashboard/eras` |
| `billing_batch_summary` | `GET .../v1/dashboard/batches/summary` (or `/batches` with filters) |
| `billing_rejection_messages` | `GET .../v1/reports/rejection-messages` (xlsx download + parse) |
| `billing_remittance_search` | `GET .../v1/reports/remit-payment-details` (xlsx download + parse) |
| `billing_rule_validate` | `POST .../v1/EDI/claims/rule-engine/validate` (side-effect-free) |
| `pat_visits_count` | `GET /pat/api/v3/visits` (reads `totalRecords`, page size 1) |
| `pat_visits_window` | `GET /pat/api/v3/visits` (paged) |
| `health_version` | `GET /billingv2/api/ping` + `GET /pat/api/StatusCheck/ping` |

## Setup

```
uv venv && uv pip install -r requirements.txt   # or: pip install -r requirements.txt
```

Env (see `appsense_ops/config.py` for the full list):

- `APPSENSE_OPS_EMAIL` / `APPSENSE_OPS_PASSWORD` — QA service-user (Phase A). Set in the
  profile's env; **never committed**. QA credentials are issued by a human.
- `APPSENSE_OPS_OPAQUE_ID` — int companyId for the Login body (QA service user).
- `APPSENSE_OPS_PROFILE` — name used for the allowlist + audit actor.
- `APPSENSE_OPS_ALLOWLIST` — comma-separated subset of tool names for this
  profile (empty = all).
- `APPSENSE_OPS_AUDIT_PATH` — JSONL sink (default `~/.appsense-ops/audit.jsonl`).

### YAML config file (optional)

Everything except the password can live in a YAML file instead of env vars:
copy [config.example.yaml](config.example.yaml) to `config.yaml` (git-ignored),
edit it, and set `APPSENSE_OPS_CONFIG` to its path. Keys are the env var names
without the `APPSENSE_OPS_` prefix, lowercased (`opaque_id`, `allowlist` as a
YAML list, `kill_switch: true`, ...).

- An env var always overrides the same key in the file.
- `password` and `allow_insecure_base` are **env-only**; a file containing
  either is refused at startup.
- Unknown keys are refused (catches typos like `max_row`).

### Credentials from the Hermes vault (optional)

Instead of `APPSENSE_OPS_EMAIL` / `APPSENSE_OPS_PASSWORD`, the login can live in
the Hermes encrypted vault:

```
hermes vault add --kind login
#   label:      Appsense QA
#   origin:     https://api.qa.appsensesolutions.com
#   identifier: email -> the QA service-user email
#   password:   the QA service-user password
```

Then set `credential_source: hermes_vault` (YAML) or
`APPSENSE_OPS_CREDENTIAL_SOURCE=hermes_vault` (env). At startup the server
decrypts `<hermes home>/vault/` and uses the single login whose origin matches
`AUTH_BASE`.

- Vault dir: `APPSENSE_OPS_VAULT_DIR` / `vault_dir`, else `HERMES_HOME/vault`,
  else `%LOCALAPPDATA%/hermes/vault`, else `~/.hermes/vault`.
- Several logins on that origin: pick one with `vault_label`.
- Setting `EMAIL`/`PASSWORD` too is refused, so a stale `.env` value can't
  shadow the vault.
- Needs `cryptography`; reads Hermes vault format version 1 and fails closed on
  anything else.

Self-check without opening stdio:

```
python -m appsense_ops.server --selfcheck
# appsense-ops 0.1.0 profile=default tools=10 kill_switch=False env=qa credentials=env
```

## Register in a Hermes profile (mcp_servers)

```json
{
  "appsense-ops": {
    "command": "python",
    "args": ["-m", "appsense_ops.server"],
    "cwd": "C:/dev/Platform/appsense-ops",
    "env": {
      "APPSENSE_OPS_PROFILE": "qa-bob",
      "APPSENSE_OPS_ALLOWLIST": "billing_claims_summary,billing_claims_by_status,billing_eras_by_date,billing_batch_summary,billing_rejection_messages,billing_remittance_search,pat_visits_count,pat_visits_window,health_version",
      "APPSENSE_OPS_EMAIL": "<from secret store>",
      "APPSENSE_OPS_PASSWORD": "<from secret store>"
    }
  }
}
```

(Note the allowlist above deliberately omits `billing_rule_validate` for the
qa-bob profile: Bob's re-verification flow is read-only. Add it per-profile if
a profile needs rule checks.)

Same registration with settings in a YAML file and the login in the Hermes
vault (`credential_source: hermes_vault` in `config.yaml`):

```json
{
  "appsense-ops": {
    "command": "python",
    "args": ["-m", "appsense_ops.server"],
    "cwd": "C:/dev/Platform/appsense-ops",
    "env": {
      "APPSENSE_OPS_CONFIG": "C:/dev/Platform/appsense-ops/config.yaml"
    }
  }
}
```

## Development

```
python -m pytest tests -q   # 65 tests; fake AuthHandler+APIs in tests/conftest.py
```

The suite covers: QA-host guard (fail-closed), login/exchange/relogin/keepalive,
param+header mapping against the real controller contracts, 401->one-retry,
row caps, xlsx report download path, allowlist (registration + call time),
kill switch, audit shape + PHI-scan of the audit file, credential-leak scan of
tool results.

## P0 non-goals

Prod access (separate credential, later phase), write tools, the MCP
machine-credential flow (NEF-3456 — this server runs on a service-user login),
per-row schema allowlists beyond row caps.
