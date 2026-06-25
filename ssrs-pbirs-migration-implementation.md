# SSRS → PBIRS Reporting Services Database Migration — Implementation Document

**Purpose:** a code-generatable implementation spec for migrating an encrypted SQL Server Reporting Services (native mode) catalog to Power BI Report Server (PBIRS) across Azure VMs, preserving stored credentials by migrating the symmetric encryption key. Every cmdlet/parameter below was verified against the actual source of `microsoft/reportingservicestools` and `dataplat/dbatools` (repomix packs), with version facts web-verified June 2026.

**Grounding sources**

- Strategy doc: `compass_artifact_wf-d579d1b6-…md` (decision rationale + Microsoft Learn citations).
- `microsoft/reportingservicestools` — packed `scratchpad/rstools.md`. File paths cited inline (`Functions/Admin/…`, `Functions/CatalogItems/Rest/…`).
- `dataplat/dbatools` — packed `scratchpad/dbatools.md`. File paths cited inline (`public/…`).
- Web-verified June 2026: PBIRS GA = **January 2026** line (build `15.0.112x`); SQL 2022 **CU17** managed-identity backup-to-URL; canonical native-mode migration + scale-out `Keys` cleanup.

---

## 1. Scope

### In scope

- Back up / restore the SSRS **encryption key** (`.snk` + password) — the only way encrypted content survives a host change.
- Move `ReportServer` + `ReportServerTempDB` between Azure VMs via native **BACKUP/RESTORE TO URL** (Azure Blob).
- Re-bind encrypted content on the target by **restoring the symmetric key**.
- Secrets in **Azure Key Vault**.
- PowerShell engine (`ReportingServicesTools` + `dbatools`) + Python orchestrator (REST v2.0, validation).
- Lost-key fallback path (`rskeymgmt -d` + scripted re-key).

### Out of scope (and why)

- **ADF for the catalog / key** — ADF does row-level copy; it cannot extract or re-key the OS-bound symmetric key, and copied encrypted blobs are useless on a new host. ADF is correct *only* for migrating the underlying **report data sources** (warehouses/marts) — a separate workstream.
- **Moving `msdb` SQL Agent subscription jobs** — the report server recreates them on startup; Microsoft advises *not* to move them.

### Assumptions (state-and-proceed — correct any that are wrong; see §12)

1. Source = SSRS native mode; target = PBIRS (instance name always `PBIRS`). SSRS→PBIRS is always a migration, never in-place upgrade.
2. Both VMs are Azure IaaS, same region as the staging storage account.
3. Target catalog engine ≥ **SQL Server 2014 SP3** (PBIRS requirement).
4. You **have** the key + password (primary path). Lost-key path documented as fallback.
5. Target version ≥ source (schema auto-upgrades forward only).

---

## 2. Why the key is the crux (one paragraph)

SSRS encrypts stored data-source credentials, connection strings, and subscription secrets inside `ReportServer` with a **symmetric key**, itself encrypted by the **public key of an OS-generated asymmetric pair whose private key is held by the Report Server service account**. Restore the DB onto a new host and its *different* key pair cannot decrypt the symmetric key → all encrypted content is inaccessible and report-server initialization fails the installation-ID/public-key match. Fix: **restore the backed-up symmetric key** on the target — it is decrypted from the password-protected `.snk`, re-encrypted with the target service's public key, and re-stored, re-binding existing content. This is exactly why ADF cannot do it and why the `.snk` + password are mission-critical.

---

## 3. Version & topology facts (web-verified June 2026)

| Item                 | Value                                                                                                                  | Note                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Target product       | Power BI Report Server                                                                                                 | instance name`PBIRS`; WMI version namespace **v15**               |
| Latest GA            | **PBIRS January 2026** line, build `15.0.112x` (e.g. `15.0.1121.115` / v`1.26.9663.10539`, 12 Jun 2026 CU) | releases Jan/May/Sept; Download id 105943.**Confirm GA at deploy.** |
| Catalog DB engine    | **SQL Server 2014 SP3+** (AS 2014 SP3+)                                                                          | PBIRS requirement                                                         |
| SQL 2025 key support | PBIRS`15.0.1119.121` (1 Dec 2025) + `15.0.1120.113` (21 Jan 2026, Enterprise Core)                                 | only if using SQL 2025 product keys                                       |
| Source floor         | SSRS 2008+ as source; SQL 2022 RS → PBIRS**May 2025+**                                                          |                                                                           |
| SSRS EOL             | SSRS 2022 security updates through**11 Jan 2033**; no SSRS after 2022                                            | consolidate on PBIRS                                                      |

**Collation gotcha:** wide-gap restores can fail on legacy `ntext`/collation mismatches (documented 2012→2019). Workaround = **stepped migration** (e.g. 2012 → 2017 → 2019/PBIRS) or `rs.exe` content rebuild.

---

## 4. Azure backup-transport design

Move `.bak` files VM→VM via native **BACKUP/RESTORE TO URL** to a Blob container in the **same region**. Pick a credential model by SQL build:

| Model                      | When                     | SQL`CREDENTIAL` shape                                                                    | Blob                                | dbatools mapping                                                                                                                                                 |
| -------------------------- | ------------------------ | ------------------------------------------------------------------------------------------ | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SAS** (default)    | portable                 | name = container URL,`IDENTITY='SHARED ACCESS SIGNATURE'`, `SECRET=<sas no leading ?>` | **block** (supports striping) | `New-DbaCredential -Name <URL> -Identity 'SHARED ACCESS SIGNATURE' -SecurePassword <sas>`                                                                      |
| **Storage key**      | legacy                   | name = friendly,`IDENTITY=<container URL>`, `SECRET=<access-key>`                      | **page** (single file)        | `New-DbaCredential -Name <friendly> -Identity <URL> -SecurePassword <key>`                                                                                     |
| **Managed identity** | **SQL 2022 CU17+** | `IDENTITY='Managed Identity'`, no secret                                                 | block                               | `New-DbaCredential -Name <URL> -Identity 'Managed Identity'` (needs `Storage Blob Data Contributor` + SQL IaaS ext + Entra; trace flag 4675 to troubleshoot) |

> Verified in `public/New-DbaCredential.ps1` examples (SAS/access-key/managed-identity blocks) and `public/Backup-DbaDatabase.ps1` line ~559 (`-StorageBaseUrl` aliases `AzureBaseUrl`; `-StorageCredential` aliases `AzureCredential`). SAS uses block blob; `-StorageCredential` (access key) forces page blob, single file, ignores `BlockSize`/`MaxTransferSize`.

**Rules:** credential name/URL matched by prefix; back up `WITH COMPRESSION, CHECKSUM, COPY_ONLY`; the **`.snk` travels separately** (different container) into **Key Vault**, never beside the `.bak`; open outbound **TCP 443**; watch proxies killing multi-thread backups and TLS mismatches. SQL IaaS *Automated Backup* covers only default instance `MSSQLSERVER` — hence native backup is driven explicitly.

---

## 5. Decision matrix — which path

| Condition                                                     | Path                                                                                               |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Key + password available, non-trivial credential count        | **DB restore + key restore** (primary, §6)                                                  |
| Cross-version restore throws LOB/collation error              | **stepped migration** or **`rs.exe` content copy**                                   |
| Want clean catalog / consolidating servers / wide version gap | **`rs.exe` content rebuild** + scripted re-key (re-enter all stored creds)                 |
| Key or password unrecoverable                                 | **`rskeymgmt -d`** + scripted `Set-RsRestItemDataSource` re-key from Key Vault inventory |
| Need underlying report**data** moved                    | **ADF** SQL connector + self-hosted IR (separate workstream)                                 |

`rskeymgmt -s` (reset key on a *working* server) ≠ `-d` (destroys encrypted content). Do not conflate.

---

## 6. End-to-end runbook (primary key-migration path)

### Phase A — Pre-migration (no downtime, repeatable)

A1. **Inventory** reports, shared/embedded data sources (+ `CredentialRetrieval` mode + connection strings), subscriptions, roles, custom config (`RSReportServer.config`, execution account, SMTP). Persist; push every secret to **Key Vault**.
A2. **Size target** from `ExecutionLog3` + CPU/RAM.
A3. **Provision target VM**; install PBIRS **"report server only"** — do *not* configure yet.
A4. **Back up the encryption key** on the source → `.snk` + password to Key Vault.
A5. **Dry-run** the whole of Phase B against a copy; render reports. Repeat — all pre-outage.

### Phase B — Migration (outage window)

B6. **Quiesce source** (disable `IsWebServiceEnabled` / stop subscriptions).
B7. **Back up** `ReportServer` + `ReportServerTempDB` **TO URL** (`COPY_ONLY, COMPRESSION, CHECKSUM`).
B8. **Restore FROM URL** on target, **identical DB names**.
B9. **Point PBIRS at the restored DB** (`Set-RsDatabase -IsExistingDatabase`).
B10. **Restore the encryption key** on the target — **run locally on the target host**.
B11. **Configure** Web Service/Portal URLs, SSL, SMTP, execution account; **delete the stale source row** from the scale-out `Keys` table.

### Phase C — Post-migration validation

C12. Render-test every report (browser + scripted); confirm each data source connects; export PDF/Excel.
C13. Confirm subscriptions exist + SQL Agent jobs auto-recreated in `msdb`; fire a test subscription.
C14. Verify folder/role security; re-apply if lost.
C15. Verify PBIX + AS data sources; authors use matching Power BI Desktop for Report Server.
C16. Cut over DNS/LB (CNAME alias avoids client URL change); keep source as rollback until UAT sign-off, then decommission.

**Rollback:** source untouched until cutover → re-point DNS. Retain `.snk`, `.bak`, Key Vault secrets until sign-off.

---

## 7. PowerShell engine — concrete, code-verified cmdlet sequence

> All cmdlet names/params below exist in the packed source. `ReportingServicesTools` encryption-key cmdlets are **local-host only** (WMI `MSReportServer_ConfigurationSetting`) — run them **on the report-server host**, not remotely.

### 7.1 Module layout to generate

```
RsMigration/
  RsMigration.psd1                 # RequiredModules: ReportingServicesTools, dbatools, Az.KeyVault
  Public/
    Backup-RsMigrationKey.ps1      # wraps Backup-RsEncryptionKey  (run on SOURCE)
    Backup-RsMigrationDatabase.ps1 # wraps New-DbaCredential + Backup-DbaDatabase -> URL
    Restore-RsMigrationDatabase.ps1# wraps New-DbaCredential + Restore-DbaDatabase <- URL
    Set-RsMigrationDatabase.ps1    # wraps Set-RsDatabase -IsExistingDatabase
    Restore-RsMigrationKey.ps1     # wraps Restore-RsEncryptionKey (run LOCALLY on TARGET)
    Remove-RsMigrationStaleKey.ps1 # delete stale Keys row (T-SQL via Invoke-DbaQuery)
    Export-RsMigrationInventory.ps1# Get-RsRestItemDataSource over all items -> Key Vault
    Invoke-RsMigrationValidation.ps1
  Private/ Get-KeyVaultSecret.ps1 ; Resolve-RsConnection.ps1
```

### 7.2 A4 — back up the key (on SOURCE host)

```powershell
# ReportingServicesTools\Functions\Admin\Backup-RsEncryptionKey.ps1
# Params: -Password (mand), -KeyPath (mand), -ReportServerInstance (alias SqlServerInstance),
#         -ReportServerVersion ([Microsoft.ReportingServicesTools.SqlServerVersion]), -ComputerName, -Credential
$keyPwd = (Get-AzKeyVaultSecret -VaultName rsVault -Name rsKeyPwd -AsPlainText)
Backup-RsEncryptionKey -ReportServerInstance 'SSRS' -ReportServerVersion 'SQLServer2019' `
    -Password $keyPwd -KeyPath 'C:\rs\ReportServer.snk'
# -> internally: New-RsConfigurationSettingObjectHelper -> $wmi.BackupEncryptionKey($Password)
#    -> [IO.File]::WriteAllBytes($KeyPath, $result.KeyFile); throws if $result.HRESULT -ne 0
# Then: Set-AzKeyVaultSecret -VaultName rsVault -Name rsSnk -SecretValue (file bytes, base64)
```

### 7.3 B7 — back up databases TO URL (SAS / block blob)

```powershell
$sas = ConvertTo-SecureString (Get-AzKeyVaultSecret -VaultName rsVault -Name blobSas -AsPlainText) -AsPlainText -Force
$container = 'https://rsmigsa.blob.core.windows.net/rsmig'
New-DbaCredential -SqlInstance SOURCEVM -Name $container -Identity 'SHARED ACCESS SIGNATURE' -SecurePassword $sas -Force
Backup-DbaDatabase -SqlInstance SOURCEVM -Database ReportServer,ReportServerTempDB `
    -AzureBaseUrl $container -Type Full -CopyOnly -CompressBackup -Checksum
# public\Backup-DbaDatabase.ps1: -StorageBaseUrl(alias AzureBaseUrl), -CopyOnly, -Type, -CompressBackup, -Checksum, -FileCount(striping)
```

### 7.4 B8 — restore FROM URL on TARGET (same DB names)

```powershell
New-DbaCredential -SqlInstance TARGETVM -Name $container -Identity 'SHARED ACCESS SIGNATURE' -SecurePassword $sas -Force
Restore-DbaDatabase -SqlInstance TARGETVM -Path "$container/ReportServer.bak"        -DatabaseName ReportServer        -WithReplace
Restore-DbaDatabase -SqlInstance TARGETVM -Path "$container/ReportServerTempDB.bak"   -DatabaseName ReportServerTempDB  -WithReplace
# public\Restore-DbaDatabase.ps1: -Path (URL), -WithReplace, -ReplaceDbNameInFile, -AzureCredential, -DestinationDataDirectory/-LogDirectory
```

### 7.5 B9 — point PBIRS at the restored DB

```powershell
# ReportingServicesTools\Functions\Admin\Set-RsDatabase.ps1
# -IsExistingDatabase => configure-only, do NOT create. -DatabaseCredentialType: Windows|SQL|ServiceAccount
# ReportServerVersion enum literal for PBIRS is 'PowerBIReportServer' (numeric Value__ = 15).
Set-RsDatabase -DatabaseServerName 'TARGETSQL' -Name 'ReportServer' -IsExistingDatabase `
    -DatabaseCredentialType ServiceAccount -ReportServerInstance 'PBIRS' -ReportServerVersion PowerBIReportServer
# Internally (WMI): with -IsExistingDatabase it SKIPS GenerateDatabaseCreationScript, then runs
#   GenerateDatabaseRightsScript($user,$Name,$IsRemoteDatabaseServer,$isWindowsAccount) via Invoke-Sqlcmd,
#   then SetDatabaseConnection($DatabaseServerName,$Name,$DatabaseCredentialType.Value__,$user,$pwd).
# IMPORTANT: Set-RsDatabase does NOT restart the report server. The restored-DB connection only takes
# effect after a service restart -- restart PowerBIReportServer here, OR rely on B10's key-restore restart.
Restart-Service -Name 'PowerBIReportServer'   # if B10 has not yet run
```

### 7.6 B10 — restore the key on TARGET (LOCAL execution)

```powershell
# ReportingServicesTools\Functions\Admin\Restore-RsEncryptionKey.ps1
# Service name is derived in-code: PBIRS -> 'PowerBIReportServer', SSRS -> 'SQLServerReportingServices'.
# Run WITHOUT -Credential, locally on the target host, so the simple local service-restart path is used.
Restore-RsEncryptionKey -ReportServerInstance 'PBIRS' -Password $keyPwd -KeyPath 'C:\rs\ReportServer.snk'
# -> $wmi.RestoreEncryptionKey($keyBytes, $keyBytes.Length, $Password); HRESULT-checked; restarts PowerBIReportServer
```

**Why local:** when `-Credential` is supplied the cmdlet restarts the service via `Get-WmiObject Win32_Service` stop/start (remote path) — fragile. Local run avoids it. (Confirmed in `Restore-RsEncryptionKey.ps1`.)

### 7.7 B11 — delete stale scale-out key row

```powershell
# After restore the Keys table lists BOTH old + new instances -> Standard edition errors "scale-out not supported".
Invoke-DbaQuery -SqlInstance TARGETSQL -Database ReportServer -Query @"
DELETE FROM dbo.Keys WHERE MachineName = N'SOURCEVM' AND InstallationID IS NOT NULL;
"@   # verify the exact stale row first: SELECT Client, MachineName, InstallationID FROM dbo.Keys;
```

### 7.8 Lost-key fallback (delete + scripted re-key)

```powershell
& 'C:\Program Files\Microsoft SQL Server\MSRS15.PBIRS\Reporting Services\ReportServer\bin\rskeymgmt.exe' -d   # destroys encrypted content (run local on target)
# then re-enter every stored credential from Key Vault inventory via REST (see §8 / §7.9)
```

### 7.9 Content-level alternative (when not restoring the DB)

- SOAP: `Out-RsCatalogItem`/`Out-RsFolderContent` → `Write-RsCatalogItem`/`Write-RsFolderContent`.
- REST v2.0: `Out-RsRestCatalogItem` → `Write-RsRestCatalogItem`.
- `rs.exe` + `ssrs_migration.rss` copies catalog content server→server but **does not migrate passwords** — re-key afterward.

---

## 8. Re-keying data sources (REST v2.0) — code-verified

Used in the **lost-key path** and in post-migration credential fixes. From `Functions/CatalogItems/Rest/Set-RsRestItemDataSource.ps1`:

- **Get** first: `$ds = Get-RsRestItemDataSource -RsItem '/path'` (REST `…/DataSources`, `$expand=DataSources`, returns `.DataSources`).
- **HTTP method** is type-dependent: **`PUT`** for `Report`/`DataSet`, **`PATCH`** for `PowerBIReport`. Body is a **JSON array** (`ConvertTo-Json -Depth 3`).

**Paginated report (embedded/shared data source):**

```powershell
$ds = Get-RsRestItemDataSource -RsItem '/Sales/Orders' -ReportPortalUri https://target/reports
$ds[0].CredentialRetrieval = 'Store'           # Integrated | Store | Prompt | None
$ds[0].CredentialsInServer  = New-RsRestCredentialsInServerObject -Username 'dom\svc' -Password $pw -WindowsCredentials
Set-RsRestItemDataSource -RsItem '/Sales/Orders' -RsItemType Report -DataSources $ds
```

**Power BI report (`DataModelDataSource`):**

```powershell
$ds = Get-RsRestItemDataSource -RsItem '/Sales/Exec' -ReportPortalUri https://target/reports
$ds[0].DataModelDataSource.AuthType = 'Windows'   # Windows | UsernamePassword | Impersonate | Key
$ds[0].DataModelDataSource.Username = 'dom\svc'
$ds[0].DataModelDataSource.Secret   = $pw          # required for Windows/UsernamePassword/Impersonate; Key needs Secret only
Set-RsRestItemDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport -DataSources $ds
```

The cmdlet **validates** these combinations and throws if `CredentialRetrieval=Store` lacks `CredentialsInServer`, or a `DataModel` source lacks `AuthType`/`Username`/`Secret` — encode the same preconditions in any generated wrapper.

### 8.1 Python orchestrator (orchestration + validation)

```
rs_migration/
  keyvault.py    # azure-keyvault-secrets + azure-identity
  rest_client.py # requests + requests_ntlm.HttpNtlmAuth ; base http(s)://<server>/Reports/api/v2.0/
                 # XSRF: GET /api/v2.0/me first, read XSRF-TOKEN cookie, send it as X-XSRF-TOKEN header
                 #       on every PUT/PATCH/POST (mirrors ReportingServicesTools' New-RsRestSession)
  inventory.py   # GET /CatalogItems, per-item /DataSources -> push secrets to Key Vault
  rekey.py       # PUT(Report)/PATCH(PowerBIReport) /…/DataSources  (mirror §8 method+payload rules)
  validate.py    # render every report, probe each datasource, confirm subscriptions+jobs
  runbook.py     # drive PowerShell (key/db) + T-SQL + REST end-to-end
```

**REST re-key nuance (encode it):** a Power BI report data source needs `CredentialRetrieval="store"` **and** both `CredentialsInServer` (UserName/Password/UseAsWindowsCredentials) **and** `DataModelDataSource` Username/Secret, else scheduled refresh fails. `SetItemDataSources`/PUT expects an **array** and requires `CredentialRetrieval` even though the published schema understates it.

---

## 9. Stored-credential modes (reference)

| Mode                                           | Symmetric-key protected? | Migration impact                                               |
| ---------------------------------------------- | ------------------------ | -------------------------------------------------------------- |
| **Stored** (reversible encryption in DB) | **Yes**            | breaks on key-less migration; needed for subscriptions/refresh |
| Windows integrated                             | No                       | needs Kerberos delegation (double-hop)                         |
| Prompt                                         | No                       | user supplies at runtime                                       |
| No credentials                                 | No                       | unattended execution account                                   |

Only **stored** values break key-less → exactly what the key restore (or §8 re-key) must cover.

---

## 10. Definition of done

- [ ] Every report renders on target (scripted).
- [ ] Every data source connects.
- [ ] Subscriptions present; `msdb` Agent jobs auto-recreated; test subscription fires.
- [ ] Folder/role security matches source.
- [ ] PBIX + AS data sources verified.
- [ ] Stale source row removed from `dbo.Keys`.
- [ ] Source retained until UAT sign-off; rollback = DNS re-point.

---

## 11. Risk register

| Risk                                                         | Mitigation                                                                                               |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| Lost`.snk`/password                                        | store in Key Vault at A4; if truly lost →`rskeymgmt -d` + §8 re-key                                  |
| Cross-version LOB/collation failure                          | stepped migration or`rs.exe` content copy                                                              |
| `Restore-RsEncryptionKey` remote-restart fragility         | run locally on target (no`-Credential`)                                                                |
| Subscriptions fail to recreate (often an encryption symptom) | explicit C13 validation                                                                                  |
| Scale-out "not supported" on Standard                        | delete stale`dbo.Keys` row (B11)                                                                       |
| Proxy/TLS killing blob backup                                | same-region SA, outbound 443, verify TLS                                                                 |
| New DB connection not live                                   | `Set-RsDatabase` does NOT restart RS — restart `PowerBIReportServer` (or let B10 key-restore do it) |
| Wrong version literal                                        | enum`PowerBIReportServer` = numeric 15 (= SQLServer2019); 2016=13, 2017=14, 2022=16                    |

---

## 12. Open questions (confirm before code generation)

1. **Exact source/target versions** (e.g. SSRS 2019 → PBIRS Jan 2026)? Drives stepped-migration need.
2. **Backup-to-URL credential model**: SAS (default), storage key, or managed identity (SQL 2022 CU17+)?
3. **Credential inventory size** — confirms key-restore is the right default vs delete-and-rekey.
4. **ADF data-source migration in scope** as a parallel workstream, or catalog-only?
5. **Language split** — PowerShell-only, or PowerShell + Python orchestrator as drafted?

---

## 13. Appendix — cmdlet ⇄ source map (verified)

| Step         | Cmdlet                               | Source file                                                           | Mechanism                                                                                                                    |
| ------------ | ------------------------------------ | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| A4           | `Backup-RsEncryptionKey`           | `rstools: Functions/Admin/Backup-RsEncryptionKey.ps1`               | WMI`MSReportServer_ConfigurationSetting.BackupEncryptionKey($pwd)` → write `.KeyFile` bytes                             |
| B10          | `Restore-RsEncryptionKey`          | `rstools: Functions/Admin/Restore-RsEncryptionKey.ps1`              | WMI`.RestoreEncryptionKey(bytes,len,pwd)`; service name PBIRS→`PowerBIReportServer`                                     |
| (conn)       | `New-RsConfigurationSettingObject` | `rstools: Functions/Utilities/New-RsConfigurationSettingObject.ps1` | WMI namespace`root\Microsoft\SqlServer\ReportServer\RS_<inst>\v<ver>\Admin`, class `MSReportServer_ConfigurationSetting` |
| B9           | `Set-RsDatabase`                   | `rstools: Functions/Admin/Set-RsDatabase.ps1`                       | `-IsExistingDatabase` configure-only; `-DatabaseCredentialType` Windows/SQL/ServiceAccount                               |
| B7           | `Backup-DbaDatabase`               | `dbatools: public/Backup-DbaDatabase.ps1`                           | `-StorageBaseUrl`(alias `AzureBaseUrl`), `-CopyOnly -Type -CompressBackup -Checksum -FileCount`                        |
| B8           | `Restore-DbaDatabase`              | `dbatools: public/Restore-DbaDatabase.ps1`                          | `-Path <URL> -WithReplace -ReplaceDbNameInFile -AzureCredential`                                                           |
| B7/B8        | `New-DbaCredential`                | `dbatools: public/New-DbaCredential.ps1`                            | SAS:`-Name <URL> -Identity 'SHARED ACCESS SIGNATURE'`; key: `-Identity <URL>`; MI: `-Identity 'Managed Identity'`      |
| B11          | `Invoke-DbaQuery`                  | `dbatools: public/Invoke-DbaQuery.ps1`                              | `DELETE FROM dbo.Keys …`                                                                                                  |
| §8          | `Get-/Set-RsRestItemDataSource`    | `rstools: Functions/CatalogItems/Rest/Set-RsRestItemDataSource.ps1` | REST v2.0; PUT(Report)/PATCH(PowerBIReport); JSON array depth 3                                                              |
| (bulk creds) | `Copy-DbaCredential`               | `dbatools: public/Copy-DbaCredential.ps1`                           | migrate non-storage SQL credentials between instances                                                                        |

> **Verified extraction notes** (`reportingservicestools` module `v0.0.9.1`, `Libraries/library.ps1`):
>
> - `Microsoft.ReportingServicesTools.SqlServerVersion` enum (numeric `Value__` = WMI `v<N>`): `SQLServer2012=11, 2014=12, 2016=13, 2017=14, 2019=15, PowerBIReportServer=15, 2022=16`. `SqlServerAuthenticationType { Windows=0, SQL=1, ServiceAccount=2 }`.
> - `ConnectionHost` defaults are **PBIRS-first**: `Instance="PBIRS"`, `Version=PowerBIReportServer`, `ComputerName="localhost"`. `Connect-RsReportServer` sets these.
> - WMI namespace is literal `RS_<Instance>` — **no `_5f` name-mangling** in this module version (purely `v$($Version.Value__)`).
> - The module has **no `rskeymgmt` wrapper, no `Set-RsDatabaseRoleScript`, no general `Restart-Rs*` cmdlet**. The only service-restart code lives inside `Restore-RsEncryptionKey`. `Set-RsDatabase` rights are granted via the WMI `GenerateDatabaseRightsScript` method (not a separate cmdlet).
> - REST sessions require an **XSRF token**: `GET /api/v2.0/me` → read `XSRF-TOKEN` cookie → send `X-XSRF-TOKEN` header on writes.
