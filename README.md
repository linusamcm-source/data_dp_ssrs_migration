# SSRS → PBIRS Migration Toolkit

A two-part toolkit that migrates **SQL Server Reporting Services (SSRS)** content
to **Power BI Report Server (PBIRS)**, preserving the encryption key, the
ReportServer databases, stored data-source credentials, and subscriptions.

| Half | Path | Role |
|------|------|------|
| Python orchestrator | `rs_migration/` | The `rs-migration` CLI — drives the end-to-end runbook, talks to PBIRS over REST v2.0, and pushes stored credentials into Azure Key Vault. |
| PowerShell module | `RsMigration/` | Wrapper cmdlets (key/DB backup-restore, point-at-DB, stale-key cleanup, validation) that the orchestrator spawns via `pwsh`. |

The runbook executes these phases in order (impl-doc §6); any failing phase
aborts the rest:

```
key backup (A4) → DB backup (B7) → DB restore (B8) → point-at-DB (B9)
   → key restore (B10) → stale-key cleanup (B11) → REST validation (Phase C)
```

A **dry run** executes only the read-only phases (catalog inventory + REST
validation) and performs **zero** mutating subprocess or SQL calls.

---

## Prerequisites

- **Python 3.10+** (the orchestrator and its tests).
- **PowerShell 7+** (`pwsh`) — runs the wrapper cmdlets and the PowerShell gate.
- PowerShell modules for a real migration: `ReportingServicesTools`, `dbatools`,
  `Az.KeyVault` (see `RsMigration/RsMigration.psd1`).
- For the PowerShell quality gate: `Pester` ≥ 5.0 and `PSScriptAnalyzer`.
- Azure credentials resolvable by `DefaultAzureCredential` (managed identity,
  environment, or `az login`) for Key Vault access.

---

## Quick start

```bat
:: 1. Configure
copy .env.example .env        & rem  then edit .env with your values

:: 2. Install (creates .venv, installs the package + dev tools)
run.bat setup

:: 3. Test
run.bat test

:: 4. Rehearse (read-only), then migrate for real
run.bat dry-run
run.bat migrate
```

On macOS/Linux there is no `run.bat`; use `just` (below) and the `rs-migration`
CLI directly.

---

## Configuration

Copy `.env.example` → `.env` and fill it in. `run.bat` loads `.env` automatically
before `dry-run`/`migrate`. Every variable maps 1:1 to a CLI flag: the env var
supplies the **default**, an explicit flag **overrides** it. A required flag is
mandatory **only when its env var is unset**, so a complete `.env` lets the CLI
run with no flags at all.

> **`.env` rules** (it is parsed by a plain batch loader): `KEY=VALUE`, one per
> line, **no quotes**, **no spaces** around `=`, `#` starts a comment. `.env` is
> git-ignored — never commit real secrets.

| Env var | CLI flag | Req? | Default | Description |
|---------|----------|:----:|---------|-------------|
| `RS_SERVER` | `--server` | ✅ | — | Target PBIRS hostname (no scheme/path). |
| `RS_SCHEME` | `--scheme` |  | `https` | URL scheme: `http` \| `https`. |
| `RS_VAULT` | `--vault` | ✅ | — | Azure Key Vault **name** for stored secrets. |
| `RS_KEY_PATH` | `--key-path` | ✅ | — | Filesystem path of the `.snk` encryption key. |
| `RS_KEY_PASSWORD_SECRET` | `--key-password-secret` | ✅ | — | Key Vault secret **name** holding the key password. |
| `RS_SNK_SECRET` | `--snk-secret` | ✅ | — | Key Vault secret **name** the base64 `.snk` is pushed to. |
| `RS_SOURCE_SQL_INSTANCE` | `--source-sql-instance` | ✅ | — | SOURCE SQL instance backed up FROM (B7). |
| `RS_TARGET_SQL_INSTANCE` | `--target-sql-instance` | ✅ | — | TARGET SQL instance restored ONTO (B8). |
| `RS_DATABASE_SERVER_NAME` | `--database-server-name` | ✅ | — | SQL server PBIRS is pointed at (B9). |
| `RS_DATABASE_NAME` | `--database-name` | ✅ | — | ReportServer DB to bind (B9) and clean (B11). |
| `RS_AZURE_BASE_URL` | `--azure-base-url` | ✅ | — | Blob container URL backups are written to / restored from. |
| `RS_BLOB_MODEL` | `--blob-model` |  | `SAS` | Blob auth: `SAS` \| `StorageKey` \| `ManagedIdentity`. |
| `RS_STALE_MACHINE_NAME` | `--stale-machine-name` | ✅ | — | Stale SOURCE machine whose `dbo.Keys` row is removed (B11). |
| `RS_ACTIVE_MACHINE_NAME` | `--active-machine-name` | ✅ | — | Active TARGET machine that must NEVER be deleted (B11). |
| `RS_REPORTS` | `--report` |  | _(none)_ | Catalog-item ids to render-test. Env is comma-separated; flag is repeatable. |
| `RS_DATA_SOURCES` | `--data-source` |  | _(none)_ | Data-source ids to probe. Env is comma-separated; flag is repeatable. |
| `RS_USERNAME` | `--username` |  | _(none)_ | NTLM username (`domain\user`); enables NTLM when set. |
| `RS_PASSWORD` | `--password` |  | _(none)_ | NTLM password (with `--username`). |
| `RS_DRY_RUN` | `--dry-run` |  | `false` | `1`/`true`/`yes`/`on` ⇒ read-only phases only. |

---

## Commands

### `run.bat` (Windows)

```
run.bat <command> [extra args...]
```

| Command | What it does |
|---------|--------------|
| `setup` | Create `.venv` and install the package + dev tools (`pip install -e .[dev]`). |
| `test` | Run **both** quality gates: Python then PowerShell. |
| `test-py` | Python gate: `pytest` with ≥ 90 % coverage, then `ruff` lint. |
| `test-ps` | PowerShell gate: Pester (≥ 90 % coverage) + PSScriptAnalyzer. |
| `lint` | `ruff` lint only. |
| `dry-run` | Run the runbook read-only (inventory + validation, no writes). |
| `migrate` | Run the **full** mutating migration runbook (reads `.env`). |
| `clean` | Delete caches: `.pytest_cache`, `.ruff_cache`, `__pycache__`, coverage files. |
| `help` | Show usage (default when no command is given). |

Extra args after the command are forwarded to the CLI and override `.env`, e.g.:

```bat
run.bat migrate --scheme http --report Q4Sales --data-source Warehouse
run.bat dry-run --server staging-pbirs.contoso.com
```

### `just` (cross-platform quality gates)

```
just qg-py     # Python gate: bootstraps .venv, pytest ≥90% coverage + ruff
just qg-ps     # PowerShell gate: pwsh -File scripts/qg-ps.ps1
```

### `rs-migration` CLI (direct)

After `run.bat setup` (or `pip install -e .[dev]`):

```bash
rs-migration --help          # full flag list (each flag shows its [env: RS_*])
rs-migration --dry-run       # read-only, params from RS_* env / .env
rs-migration \
  --server pbirs.contoso.com --vault kv-rs-migration \
  --key-path C:\rs\ReportServer.snk \
  --key-password-secret rsKeyPassword --snk-secret rsSnk \
  --source-sql-instance SRC\SQL --target-sql-instance TGT\SQL \
  --azure-base-url https://store.blob.core.windows.net/rs-backups \
  --database-server-name TGT\SQL --database-name ReportServer \
  --stale-machine-name OLD-SSRS --active-machine-name NEW-PBIRS \
  --report Orders --data-source Sales
```

Exit code is `0` on success, non-zero when any phase fails (the failing phase
name is printed).

### PowerShell cmdlets (`RsMigration` module)

Imported with `Import-Module ./RsMigration`. The orchestrator spawns these per
phase, but they can also be run standalone:

| Cmdlet | Key parameters | Phase |
|--------|----------------|-------|
| `Backup-RsMigrationKey` | `-KeyPath -VaultName -PasswordSecretName -SnkSecretName` | A4 |
| `Backup-RsMigrationDatabase` | `-SqlInstance -AzureBaseUrl [-Model]` | B7 |
| `Restore-RsMigrationDatabase` | `-SqlInstance -AzureBaseUrl [-Model]` | B8 |
| `Set-RsMigrationDatabase` | `-DatabaseServerName -Name [-DatabaseCredentialType]` | B9 |
| `Restore-RsMigrationKey` | `-KeyPath -VaultName -PasswordSecretName [-ReportServerInstance]` | B10 |
| `Remove-RsMigrationStaleKey` | `-SqlInstance -Database -MachineName -ActiveMachineName` (supports `-WhatIf`) | B11 |
| `Export-RsMigrationInventory` | `-VaultName -ReportPortalUri [-RsFolder]` | A1 |
| `Set-RsMigrationDataSource` | `-RsItem -RsItemType [-ReportPortalUri]` (supports `-WhatIf`) | re-key |
| `Invoke-RsMigrationValidation` | `-SqlInstance -ReportPortalUri [-Database]` | C |
| `Reset-RsMigrationEncryptedContent` | `[-SqlMajorVersion -Force]` (high-impact, supports `-WhatIf`) | recovery |

---

## Testing

Quality gates enforce **≥ 90 % coverage** on each side.

```bat
run.bat test        :: both gates (Windows)
run.bat test-py     :: Python only
run.bat test-ps     :: PowerShell only
```

```bash
just qg-py          # Python gate (any OS)
just qg-ps          # PowerShell gate (any OS with pwsh)

# Or run the Python tests directly inside the venv:
.venv/bin/python -m pytest --cov=rs_migration --cov-fail-under=90 tests/python
.venv/bin/ruff check rs_migration tests/python
```

- Python tests: `tests/python/` (`pytest` + `pytest-cov`, mocks the REST wire,
  Key Vault, and the `pwsh` subprocess boundary).
- PowerShell tests: `tests/pester/` (Pester 5), gated by `scripts/qg-ps.ps1`.

---

## Project layout

```
rs_migration/        Python orchestrator + REST client
  runbook.py         rs-migration CLI + end-to-end phase orchestration
  rest_client.py     PBIRS REST v2.0 client (XSRF + NTLM)
  inventory.py       Catalog inventory → Key Vault credential capture
  rekey.py           Re-bind catalog-item data-source credentials over REST
  validate.py        Post-migration REST validation (render/connect/subscriptions)
  keyvault.py        Azure Key Vault read/write helpers
RsMigration/         PowerShell module (Public/ cmdlets, Private/ helpers)
scripts/qg-ps.ps1    PowerShell quality gate
tests/               python/ (pytest) and pester/ (Pester) suites
justfile             qg-py / qg-ps recipes
.env.example         Configuration template (copy to .env)
run.bat              Windows task runner (setup / test / dry-run / migrate / clean)
```
