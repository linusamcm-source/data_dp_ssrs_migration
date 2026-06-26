# Graph Report - .  (2026-06-26)

## Corpus Check
- Corpus is ~22,652 words - fits in a single context window. You may not need a graph.

## Summary
- 99 nodes · 82 edges · 34 communities (31 shown, 3 thin omitted)
- Extraction: 79% EXTRACTED · 21% INFERRED · 0% AMBIGUOUS · INFERRED: 17 edges (avg confidence: 0.82)
- Token cost: 61,679 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Migration Orchestration & Backup|Migration Orchestration & Backup]]
- [[_COMMUNITY_Migration Runbook Concepts|Migration Runbook Concepts]]
- [[_COMMUNITY_Validation & Rendering|Validation & Rendering]]
- [[_COMMUNITY_Database Transfer (dbatools)|Database Transfer (dbatools)]]
- [[_COMMUNITY_SSRS-PBIRS Platform & Security|SSRS-PBIRS Platform & Security]]
- [[_COMMUNITY_Quality Gate Tooling|Quality Gate Tooling]]
- [[_COMMUNITY_Subscription Import|Subscription Import]]
- [[_COMMUNITY_Encryption Key Management|Encryption Key Management]]
- [[_COMMUNITY_Connection & Key Backup|Connection & Key Backup]]
- [[_COMMUNITY_Service & Database Config|Service & Database Config]]

## God Nodes (most connected - your core abstractions)
1. `Invoke-RsMigration` - 13 edges
2. `RsMigration PowerShell module` - 8 edges
3. `Join-RsMigrationPath()` - 5 edges
4. `Import-RsMigrationSubscription()` - 5 edges
5. `New-RsMigrationRestSession()` - 4 edges
6. `Invoke-RsMigration()` - 4 edges
7. `Invoke-RsMigrationValidation()` - 4 edges
8. `scripts/qg-ps.ps1 quality gate` - 4 edges
9. `Invoke-RsReportRender()` - 3 edges
10. `Test-RsDataSourceConnection()` - 3 edges

## Surprising Connections (you probably didn't know these)
- `Copy-RsMigrationBackup()` --calls--> `Join-RsMigrationPath()`  [INFERRED]
  RsMigration/Private/Copy-RsMigrationBackup.ps1 → RsMigration/Private/Join-RsMigrationPath.ps1
- `Backup-RsMigrationDatabase()` --calls--> `Join-RsMigrationPath()`  [INFERRED]
  RsMigration/Public/Backup-RsMigrationDatabase.ps1 → RsMigration/Private/Join-RsMigrationPath.ps1
- `Restore-RsMigrationDatabase()` --calls--> `Join-RsMigrationPath()`  [INFERRED]
  RsMigration/Public/Restore-RsMigrationDatabase.ps1 → RsMigration/Private/Join-RsMigrationPath.ps1
- `Import-RsMigrationSubscription()` --calls--> `New-RsMigrationRestSession()`  [INFERRED]
  RsMigration/Public/Import-RsMigrationSubscription.ps1 → RsMigration/Private/New-RsMigrationRestSession.ps1
- `Invoke-RsMigration()` --calls--> `Invoke-RsMigrationValidation()`  [INFERRED]
  RsMigration/Public/Invoke-RsMigration.ps1 → RsMigration/Public/Invoke-RsMigrationValidation.ps1

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Nine-phase migration runbook sequence** — readme_invoke_rsmigration, readme_backup_rsmigrationkey, readme_backup_rsmigrationdatabase, readme_restore_rsmigrationdatabase, readme_set_rsmigrationdatabase, readme_restore_rsmigrationkey, readme_remove_rsmigrationstalekey, readme_import_rsmigrationsubscription, readme_invoke_rsmigrationvalidation [EXTRACTED 1.00]
- **PowerShell quality gate** — readme_qg_ps, readme_pester, readme_psscriptanalyzer, readme_run_bat, readme_justfile [EXTRACTED 1.00]

## Communities (34 total, 3 thin omitted)

### Community 0 - "Migration Orchestration & Backup"
Cohesion: 0.17
Nodes (6): Copy-RsMigrationBackup(), Join-RsMigrationPath(), Backup-RsMigrationDatabase(), Export-RsMigrationInventory(), Invoke-RsMigration(), Restore-RsMigrationDatabase()

### Community 1 - "Migration Runbook Concepts"
Cohesion: 0.20
Nodes (12): Backup-RsMigrationKey, Dry run (read-only rehearsal), Export-RsMigrationInventory, Idempotent subscription refresh, Import-RsMigrationSubscription, Invoke-RsMigration, Invoke-RsMigrationValidation, Remove-RsMigrationStaleKey (+4 more)

### Community 2 - "Validation & Rendering"
Cohesion: 0.29
Nodes (4): Invoke-RsReportRender(), New-RsMigrationRestSession(), Test-RsDataSourceConnection(), Invoke-RsMigrationValidation()

### Community 3 - "Database Transfer (dbatools)"
Cohesion: 0.29
Nodes (8): Backup-DbaDatabase, Backup-RsMigrationDatabase, dbatools module, ReportingServicesTools module, Restore-DbaDatabase, Restore-RsMigrationDatabase, RsMigration.psd1 module manifest, SMB fileshare transfer model

### Community 4 - "SSRS-PBIRS Platform & Security"
Cohesion: 0.29
Nodes (8): Encryption key (.snk), Power BI Report Server (PBIRS), PowerShell 7+ (pwsh), Reset-RsMigrationEncryptedContent, RsMigration PowerShell module, Integrated Windows security model, Set-RsMigrationDataSource, SQL Server Reporting Services (SSRS)

### Community 5 - "Quality Gate Tooling"
Cohesion: 0.29
Nodes (7): .env configuration, justfile (qg-ps recipe), Pester (test framework), PSScriptAnalyzer, scripts/qg-ps.ps1 quality gate, Quality gate (>=90% coverage), run.bat (Windows task runner)

### Community 6 - "Subscription Import"
Cohesion: 0.80
Nodes (4): ConvertTo-RsSubPayload(), Get-RsSubField(), Get-RsSubKey(), Import-RsMigrationSubscription()

## Knowledge Gaps
- **14 isolated node(s):** `Backup-RsMigrationKey`, `Set-RsMigrationDatabase`, `Restore-RsMigrationKey`, `Remove-RsMigrationStaleKey`, `Set-RsMigrationDataSource` (+9 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Invoke-RsMigration` connect `Migration Runbook Concepts` to `Database Transfer (dbatools)`, `SSRS-PBIRS Platform & Security`, `Quality Gate Tooling`?**
  _High betweenness centrality (0.093) - this node is a cross-community bridge._
- **Why does `RsMigration PowerShell module` connect `SSRS-PBIRS Platform & Security` to `Migration Runbook Concepts`, `Database Transfer (dbatools)`?**
  _High betweenness centrality (0.049) - this node is a cross-community bridge._
- **Why does `run.bat (Windows task runner)` connect `Quality Gate Tooling` to `Migration Runbook Concepts`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **Are the 4 inferred relationships involving `Join-RsMigrationPath()` (e.g. with `Copy-RsMigrationBackup()` and `Backup-RsMigrationDatabase()`) actually correct?**
  _`Join-RsMigrationPath()` has 4 INFERRED edges - model-reasoned connections that need verification._
- **Are the 3 inferred relationships involving `New-RsMigrationRestSession()` (e.g. with `Invoke-RsReportRender()` and `Test-RsDataSourceConnection()`) actually correct?**
  _`New-RsMigrationRestSession()` has 3 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Backup-RsMigrationKey`, `Set-RsMigrationDatabase`, `Restore-RsMigrationKey` to the rest of the system?**
  _15 weakly-connected nodes found - possible documentation gaps or missing edges._