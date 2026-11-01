# appsense-ops — Client Deployment Guide (v0.1.0)

Read-only QA tools over Appsense pat-api + billing-api, served over MCP (stdio).
This guide deploys the **NEF-3455 P0 build**, which is **fail-closed to the QA
gateway** (`api.qa.appsensesolutions.com`) — production Appsense access is a
separate phase and is refused by the code.

Bundle contents:
- `appsense_ops-0.1.0-py3-none-any.whl` — the server package (built from develop `7930281`)
- `config.example.yaml` — template; copy to `config.yaml` and edit
- `DEPLOY.md` — this guide

> **Superseded by the release pipeline:** clients should now download the
> current bundle from https://data-application-technologies-llc.github.io/appsense-ops-site/
> — this folder documents the manual path. Multi-environment support (`env:` qa/prod/dev)
> ships in 0.2.0; see DEPLOY.md section 8 in the released bundle.

## 0. Deployment decisions (Eric, 2026-10-30 — binding)

1. **QA-only is confirmed** for the initial client rollout: this P0 build talks to
   `api.qa.appsensesolutions.com` only; production Appsense stays a phase-2 code change.
2. **Per-client service accounts** are provisioned by Eric before each install —
   never ship the shared `qa-bob` account to a client machine.
3. **Hermes vault flow is mandatory** on client machines: `credential_source:
   hermes_vault`, with a vault login bound to `https://api.qa.appsensesolutions.com`.
   The env-var fallback below exists only for machines without Hermes and needs
   Eric's explicit sign-off per machine.

---

## 1. Prerequisites (client computer)

| Requirement | Detail |
|---|---|
| Python | **3.11 or newer** (3.11–3.14 tested) |
| Network | Outbound HTTPS to `api.qa.appsensesolutions.com:443` |
| Credentials | A **per-client QA service account** (email + password + company/opaque ID). Do **not** reuse the `qa-bob` account — its password was shared in chat and was rotated. |
| Credential store | Recommended: Hermes vault (if Hermes is installed). Fallback: environment variables. |

## 2. Install

```bat
py -3.11 -m venv C:\appsense-ops\.venv
C:\appsense-ops\.venv\Scripts\python.exe -m pip install C:\path\to\appsense_ops-0.1.0-py3-none-any.whl
```

Verify the entry point exists and the fail-closed guard works on a clean machine:

```bat
C:\appsense-ops\.venv\Scripts\appsense-ops.exe --selfcheck
```

Expected: `appsense-ops 0.1.0 profile=... tools=N kill_switch=False env=qa ...`
(or a clean `appsense-ops: config error: ...` line if not yet configured — that
is the fail-closed path working; it must never print a traceback).

## 3. Configure

Create `C:\appsense-ops\config.yaml` from **`config.client-template.yaml`** (in this
bundle — fill every `<ANGLE_BRACKET>` value; it is loader-verified to fail cleanly
until the vault login exists) or from `config.example.yaml`:

```yaml
profile: <client-name>          # allowlist selector; see section 6
opaque_id: <client companyId>   # int, sent as opaqueId in the Login body
credential_source: env          # or hermes_vault (section 4)
email: <client-service-account@...>   # only with credential_source: env
allowlist:                      # least privilege — list only needed tools
  - health_version
  - billing_claims_summary
  - billing_eras_by_date
  - billing_batch_summary
  - billing_rejection_messages
  - billing_remittance_search
  - pat_visits_count
  - pat_visits_window
max_rows: 50
timeout_s: 30
kill_switch: false
```

Rules enforced by the code:
- `password` and `allow_insecure_base` are **refused** in the config file —
  passwords live only in the environment or the Hermes vault.
- Any base URL other than `api.qa.appsensesolutions.com` is refused (P0 is
  QA-only). There is no supported way to point this build at production.
- An env var always overrides the same key in the file.

If not using the vault, set the password as an environment variable **for the
server process only** (in the MCP client registration, section 5):

```
APPSENSE_OPS_PASSWORD=...        # never in a file that gets copied around
```

## 4. Credentials — preferred: Hermes vault (if Hermes is on the client)

```bat
hermes vault add --kind login
```

Store the service account with origin/URL `https://api.qa.appsensesolutions.com`,
then set in `config.yaml`:

```yaml
credential_source: hermes_vault
# vault_label: Appsense QA   # only if several logins share that origin
```

With `credential_source: hermes_vault`, `APPSENSE_OPS_EMAIL`/`PASSWORD` must be
absent (the code refuses to let a stale env password shadow the vault).

## 5. Register as an MCP server

**Hermes Agent:**

```bat
hermes config set mcp_servers.appsense-ops "{\"command\": \"C:/appsense-ops/.venv/Scripts/python.exe\", \"args\": [\"-m\", \"appsense_ops.server\"], \"cwd\": \"C:/appsense-ops\", \"env\": {\"APPSENSE_OPS_CONFIG\": \"C:/appsense-ops/config.yaml\"}, \"connect_timeout\": 60}"
```

Note `cwd` is required — `hermes mcp add` has no `--cwd` flag, so set it via
`hermes config set` (or write the whole entry with `hermes config set`).
Restart Hermes afterwards; MCP tools load at startup only.

**Generic MCP client (e.g. Claude Desktop)** — `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "appsense-ops": {
      "command": "C:\\appsense-ops\\.venv\\Scripts\\python.exe",
      "args": ["-m", "appsense_ops.server"],
      "cwd": "C:\\appsense-ops",
      "env": { "APPSENSE_OPS_CONFIG": "C:\\appsense-ops\\config.yaml" }
    }
  }
}
```

(If using env-credentials instead of the vault, add
`APPSENSE_OPS_PASSWORD` to `env` here — this keeps it out of files on disk.)

## 6. Verify (acceptance checklist)

1. `appsense-ops --selfcheck` → prints version, profile, tool count, `env=qa`, no traceback.
2. In the MCP client, tools list shows **exactly the allowlisted tools**.
3. Call `health_version` → returns JSON with `server`, `env: qa`, `services`, `profile`.
   (Pre-auth pings may report `down (401/403)` — the QA gateway auth-walls its
   open routes; that is expected. Judge liveness by an authenticated call.)
4. Call `pat_visits_count` with a small window (`start_date`/`end_date` in
   **MM/dd/yyyy**) → returns `total_visits`. This proves the full
   login → token → API path.
5. Call `billing_claims_summary` with `from_date_time`/`to_date_time` in
   **`yyyy-MM-ddTHH:mm:ssZ`** format (trailing Z — the server's "MM/dd/yyyy"
   validation message is misleading; bare ISO is rejected).
6. Audit sink: `~/.appsense-ops/audit.jsonl` (or `audit_path` from config) is
   being appended with metadata-only rows — verify it exists after the first call.

## 7. Security notes

- The server is **read-only by construction**; every call is audit-logged with
  metadata only (no PHI in audit rows).
- Passwords/tokens are never logged, never returned in tool results.
- Kill switch: set `APPSENSE_OPS_KILL_SWITCH=1` (env) to disable all tools
  without uninstalling.
- The `qa-bob` shared account should not be used on client machines; provision
  one service account per client and least-privilege allowlists per profile.
- Malformed dates produce upstream 500s with stack traces (known Appsense-side
  defect, noted to the platform team) — the local server never crashes; it
  returns a capped error string.

## 8. Production and dev Appsense environments

Set `env: prod` (or `env: dev`) in `config.yaml` — the canonical gateway hosts
are pinned in code (`api.appsensesolutions.com` for prod, `api.dev.` for dev),
and every base URL is checked against the configured environment's host at
startup. Credentials come from a Hermes vault login **bound to that
environment's origin** (`https://api.appsensesolutions.com` for prod) — one
vault login per environment, exactly like the QA flow. Never point a QA config
at a prod host or vice versa: the env/host mismatch refuses to start, and
`APPSENSE_OPS_ALLOW_INSECURE_BASE=1` (test-only) disables the https guard
along with the host check.
