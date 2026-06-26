# SSRS → PBIRS Migration Toolkit

A single **PowerShell module** that migrates **SQL Server Reporting Services
(SSRS)** content to **Power BI Report Server (PBIRS)**, preserving the
encryption key, the ReportServer databases, stored data-source credentials, and
subscriptions.

| Module          | Path             | Role                                                                                                                                                                          |
| --------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RsMigration` | `RsMigration/` | All migration cmdlets (key/DB backup-restore, point-at-DB, stale-key cleanup, selective subscription import, REST validation), sequenced end-to-end by`Invoke-RsMigration`. |

`Invoke-RsMigration` is the runbook: it calls the toolkit's own per-phase cmdlets
**in-process** (no child processes) in order, aborting on the first failure:

```
1 key backup → 2 DB backup → 3 backup copy → 4 DB restore
   → 5 point-at-DB → 6 key restore → 7 stale-key cleanup
   → 8 subscription import → 9 REST validation
```

A **dry run** executes only the read-only phases — a catalog inventory of the
SOURCE followed by REST validation of the TARGET — and mutates nothing.

---

## Security model

Every connection runs under **integrated Windows security** as the current
Windows identity (e.g. `MYSTATE\lc.admin`):

- SQL access (via **dbatools**) and REST access (via **ReportingServicesTools**
  and `Invoke-RestMethod -WebSession`) use the caller's own credentials — no SQL
  logins, no usernames, no passwords, and no external secret store.
- The **only** secret is the encryption-key password. It is never stored in
  `.env`; it is passed as a `[SecureString] -KeyPassword` and prompted
  interactively (`Read-Host -AsSecureString`) when omitted. Unattended callers
  must supply it explicitly.

## Transfer model

Backups move over **SMB fileshares**, not any cloud object store:

- **Phase 2** — `Backup-RsMigrationDatabase` runs `Backup-DbaDatabase` to write
  `ReportServer.bak` / `ReportServerTempDB.bak` to the **source** share
  (BACKUP TO DISK).
- **Phase 3** — the runbook then copies those `.bak` files **share → share**
  (source share → target share).
- **Phase 4** — `Restore-RsMigrationDatabase` runs `Restore-DbaDatabase` to restore
  them from the **target** share (RESTORE FROM DISK), keeping the original
  database names.

The encryption-key `.snk` is likewise written to / read from the share. Share
**roots** and file **names** are always separate inputs (`-SourceSharePath` +
`-KeyFile`, etc.); the cmdlets join `<share>` + `<file>` themselves, so no
full path is ever hard-coded.

---

## Prerequisites

- **PowerShell 7+** (`pwsh`) — runs the cmdlets and the quality gate.
- PowerShell modules for a real migration: **`ReportingServicesTools`** and
  **`dbatools`** (declared in `RsMigration/RsMigration.psd1`).
- For the quality gate: **`Pester`** ≥ 5.0 and **`PSScriptAnalyzer`**.
- Rights on the SOURCE and TARGET hosts (SQL, report portals, and SMB shares)
  for the Windows identity you run as.

---

## Quick start

```bat
:: 1. Configure
copy .env.example .env        & rem  then edit .env with your values

:: 2. Test (PowerShell quality gate)
run.bat test

:: 3. Rehearse (read-only), then migrate for real
run.bat dry-run
run.bat migrate
```

On macOS/Linux there is no `run.bat`; import the module and call the cmdlets
directly under `pwsh` (the mutating phases assume Windows report-server hosts):

```powershell
Import-Module ./RsMigration/RsMigration.psd1
Invoke-RsMigration -DryRun `
  -SourceReportPortalUri https://ssrs-source/reports `
  -TargetReportPortalUri https://pbirs-target/reports `
  # ...remaining parameters (see table below)
```

---

## Configuration

Copy `.env.example` → `.env` and fill it in. `run.bat` loads `.env` automatically
before `dry-run`/`migrate` and threads each variable into the matching
`Invoke-RsMigration` parameter.

> **`.env` rules** (it is parsed by a plain batch loader): `KEY=VALUE`, one per
> line, **no quotes**, **no spaces** around `=`, `#` starts a comment. `.env` is
> git-ignored — never commit a real one.

| `.env` (RS_*)               | `Invoke-RsMigration` parameter | Req? | Description                                                                                     |
| ----------------------------- | -------------------------------- | :--: | ----------------------------------------------------------------------------------------------- |
| `RS_SOURCE_PORTAL_URI`      | `-SourceReportPortalUri`       |  ✅  | SOURCE report-portal root URL (dry-run inventory).                                              |
| `RS_TARGET_PORTAL_URI`      | `-TargetReportPortalUri`       |  ✅  | TARGET report-portal root URL (subscription import + validation).                               |
| `RS_SOURCE_SQL_INSTANCE`    | `-SourceSqlInstance`           |  ✅  | SOURCE SQL instance backed up FROM (phase 2).                                                        |
| `RS_TARGET_SQL_INSTANCE`    | `-TargetSqlInstance`           |  ✅  | TARGET SQL instance restored ONTO (phase 4).                                                         |
| `RS_DATABASE_SERVER_NAME`   | `-DatabaseServerName`          |  ✅  | SQL server PBIRS is pointed at (phase 5).                                                            |
| `RS_DATABASE_NAME`          | `-DatabaseName`                |  ✅  | ReportServer DB to bind (phase 5) and clean (phase 7).                                                   |
| `RS_SOURCE_SHARE`           | `-SourceSharePath`             |  ✅  | SOURCE SMB share root —`.bak` files and `.snk` are written here.                           |
| `RS_TARGET_SHARE`           | `-TargetSharePath`             |  ✅  | TARGET SMB share root — backups are copied here, then restored from here.                      |
| `RS_KEY_FILE`               | `-KeyFile`                     |  ✅  | Encryption-key`.snk` file **name** (joined onto the source share).                      |
| `RS_REPORTSERVER_BAK`       | `-ReportServerBak`             |  ✅  | ReportServer backup file**name**.                                                         |
| `RS_REPORTSERVERTEMPDB_BAK` | `-ReportServerTempDbBak`       |  ✅  | ReportServerTempDB backup file**name**.                                                   |
| `RS_STALE_MACHINE_NAME`     | `-MachineName`                 |  ✅  | Stale SOURCE machine whose`dbo.Keys` row is removed (phase 7).                                    |
| `RS_ACTIVE_MACHINE_NAME`    | `-ActiveMachineName`           |  ✅  | Active TARGET machine that must NEVER be deleted (phase 7).                                         |
| `RS_REPORTS`                | `-ReportItem`                  |  ✅  | Catalog item paths to render-test. Comma-separated in`.env`; split into an array.             |
| `RS_DATA_SOURCES`           | `-DataSource`                  |  ✅  | Data-source paths to probe. Comma-separated in`.env`; split into an array.                    |
| `RS_INCLUDE_SUBSCRIPTIONS`  | `-IncludeSubscription`         |      | Allow-list of subscription names to import.**Empty ⇒ import ALL.**                       |
| `RS_DRY_RUN`                | `-DryRun`                      |      | `1`/`true`/`yes`/`on` ⇒ read-only phases only.                                         |
| _(prompted)_                | `-KeyPassword`                 |      | `[SecureString]` protecting the `.snk`. **Never** in `.env`; prompted when omitted. |

---

## Subscriptions

`Import-RsMigrationSubscription` recreates catalog subscriptions from the source
portal onto the target portal over the PBIRS REST v2.0 API:

- **Selective** — `-IncludeSubscription` is an allow-list of subscription names;
  anything not listed is skipped. Leave it empty (the `.env` default) to import
  every subscription.
- **Idempotent refresh** — each subscription is keyed on its content (owner,
  path, schedule, delivery), not its server-assigned `Id`. Re-running the import
  updates an existing match in place instead of creating a duplicate, so the
  step is safe to repeat.

---

## Commands

### `run.bat` (Windows)

```
run.bat <command>
```

| Command     | What it does                                                       |
| ----------- | ------------------------------------------------------------------ |
| `test`    | PowerShell gate: Pester (≥ 90 % coverage) + PSScriptAnalyzer.     |
| `dry-run` | Run the runbook read-only (inventory + validation, no writes).     |
| `migrate` | Run the**full** mutating migration runbook (reads `.env`). |
| `clean`   | Delete coverage artifacts (`coverage.xml`, `.coverage`).       |
| `help`    | Show usage (default when no command is given).                     |

### `just` (cross-platform quality gate)

```
just qg-ps     # PowerShell gate: pwsh -File scripts/qg-ps.ps1
```

### `Invoke-RsMigration` (direct)

```powershell
Import-Module ./RsMigration/RsMigration.psd1

# Read-only rehearsal:
Invoke-RsMigration -DryRun -SourceReportPortalUri ... -TargetReportPortalUri ... # (+ params)

# Full migration (prompts for the key password as a SecureString):
Invoke-RsMigration `
  -SourceSqlInstance SRC\SQL -TargetSqlInstance TGT\SQL `
  -SourceSharePath \\src\FileShare -TargetSharePath \\tgt\FileShare `
  -KeyFile ReportServer.snk `
  -ReportServerBak ReportServer.bak -ReportServerTempDbBak ReportServerTempDB.bak `
  -DatabaseServerName TGT\SQL -DatabaseName ReportServer `
  -MachineName OLD-SSRS -ActiveMachineName NEW-PBIRS `
  -ReportItem '/Sales/Orders' -DataSource '/Sales/DS' `
  -SourceReportPortalUri https://ssrs-source/reports `
  -TargetReportPortalUri https://pbirs-target/reports
```

The runbook throws a terminating error naming the failing phase, so a
non-zero/throwing result identifies exactly where it stopped.

### Standalone cmdlets (`RsMigration` module)

`Invoke-RsMigration` sequences phases 1–9; the data-source and recovery cmdlets
are **standalone** (never called by the runbook). Each can also be run on its own:

| Cmdlet                                | Key parameters                                                                       | Phase       |
| ------------------------------------- | ------------------------------------------------------------------------------------ | ----------- |
| `Backup-RsMigrationKey`             | `-KeyPath -KeyPassword [-ReportServerInstance -ReportServerVersion -ComputerName]` | 1           |
| `Backup-RsMigrationDatabase`        | `-SqlInstance -SourceSharePath -ReportServerBak -ReportServerTempDbBak`            | 2           |
| `Restore-RsMigrationDatabase`       | `-SqlInstance -TargetSharePath -ReportServerBak -ReportServerTempDbBak`            | 4           |
| `Set-RsMigrationDatabase`           | `-DatabaseServerName -Name [-DatabaseCredentialType]` (supports `-WhatIf`)       | 5           |
| `Restore-RsMigrationKey`            | `-KeyPath -KeyPassword [-ReportServerInstance]` (local-restart only)               | 6           |
| `Remove-RsMigrationStaleKey`        | `-SqlInstance -Database -MachineName -ActiveMachineName`                           | 7           |
| `Import-RsMigrationSubscription`    | `-SourceReportPortalUri -TargetReportPortalUri [-IncludeSubscription]`             | 8           |
| `Invoke-RsMigrationValidation`      | `-ReportItem -DataSource -SqlInstance [-Database] -ReportPortalUri`                | 9 / dry-run |
| `Export-RsMigrationInventory`       | `-ReportPortalUri [-RsFolder]`                                                     | dry-run     |
| `Set-RsMigrationDataSource`         | `-RsItem -RsItemType [-ReportPortalUri -Credential -WebSession]`                   | standalone  |
| `Reset-RsMigrationEncryptedContent` | `[-SqlMajorVersion -Force]` (high-impact, supports `-WhatIf`)                    | standalone  |

---

## Testing

The quality gate enforces **≥ 90 % coverage**.

```bat
run.bat test        :: PowerShell gate (Windows)
```

```bash
just qg-ps          # PowerShell gate (any OS with pwsh)
```

- PowerShell tests: `tests/pester/` (Pester 5), gated by `scripts/qg-ps.ps1`,
  which also runs `PSScriptAnalyzer`.

---

## Project layout

```
RsMigration/          PowerShell module
  RsMigration.psd1    Module manifest (requires ReportingServicesTools, dbatools)
  RsMigration.psm1    Dot-sources Public/ + Private/ and exports the public cmdlets
  Public/             Exported cmdlets (Invoke-RsMigration + per-phase cmdlets)
  Private/            Internal helpers (REST session, path join, backup copy, …)
scripts/qg-ps.ps1     PowerShell quality gate (Pester + PSScriptAnalyzer)
tests/pester/         Pester 5 test suite
justfile              qg-ps recipe
.env.example          Configuration template (copy to .env)
run.bat               Windows task runner (test / dry-run / migrate / clean)
```
