# Graph Report - .  (2026-06-26)

## Corpus Check
- Corpus is ~24,351 words - fits in a single context window. You may not need a graph.

## Summary
- 385 nodes · 692 edges · 36 communities (32 shown, 4 thin omitted)
- Extraction: 92% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 51 edges (avg confidence: 0.72)
- Token cost: 0 input · 52,850 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Runbook Orchestrator Tests|Runbook Orchestrator Tests]]
- [[_COMMUNITY_Inventory Tests|Inventory Tests]]
- [[_COMMUNITY_REST Client Tests|REST Client Tests]]
- [[_COMMUNITY_Toolkit Architecture & Concepts|Toolkit Architecture & Concepts]]
- [[_COMMUNITY_Re-key Tests|Re-key Tests]]
- [[_COMMUNITY_Key Vault Helpers & Tests|Key Vault Helpers & Tests]]
- [[_COMMUNITY_Validation Tests|Validation Tests]]
- [[_COMMUNITY_REST Client Internals|REST Client Internals]]
- [[_COMMUNITY_REST Errors & Validation Logic|REST Errors & Validation Logic]]
- [[_COMMUNITY_CLI Argument Parsing|CLI Argument Parsing]]
- [[_COMMUNITY_Python Module Cores|Python Module Cores]]
- [[_COMMUNITY_Key BackupRestore Cmdlets|Key Backup/Restore Cmdlets]]
- [[_COMMUNITY_Report Render & Validation Cmdlets|Report Render & Validation Cmdlets]]
- [[_COMMUNITY_Database BackupRestore Cmdlets|Database Backup/Restore Cmdlets]]
- [[_COMMUNITY_Key Mgmt & Content Reset|Key Mgmt & Content Reset]]
- [[_COMMUNITY_Service Restart & DB Pointing|Service Restart & DB Pointing]]
- [[_COMMUNITY_Pytest Fixtures|Pytest Fixtures]]
- [[_COMMUNITY_Inventory Export Cmdlet|Inventory Export Cmdlet]]
- [[_COMMUNITY_Package Init|Package Init]]

## God Nodes (most connected - your core abstractions)
1. `RestClient` - 56 edges
2. `inventory()` - 21 edges
3. `runbook()` - 20 edges
4. `rekey()` - 18 edges
5. `validate()` - 17 edges
6. `_client()` - 15 edges
7. `_mock_handshake()` - 15 edges
8. `main()` - 14 edges
9. `_client()` - 14 edges
10. `Mocker` - 14 edges

## Surprising Connections (you probably didn't know these)
- `RestClient` --uses--> `RestClient`  [INFERRED]
  tests/python/test_rekey.py → rs_migration/rest_client.py
- `RestClient` --uses--> `RestClient`  [INFERRED]
  tests/python/test_validate.py → rs_migration/rest_client.py
- `Mocker` --uses--> `RestClient`  [INFERRED]
  tests/python/test_rekey.py → rs_migration/rest_client.py
- `RestClient` --uses--> `RestClient`  [INFERRED]
  rs_migration/inventory.py → rs_migration/rest_client.py
- `RestClient` --uses--> `RestClient`  [INFERRED]
  rs_migration/rekey.py → rs_migration/rest_client.py

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Ordered Migration Runbook Phase Sequence** — readme_phase_a4_key_backup, readme_phase_b7_db_backup, readme_phase_b8_db_restore, readme_phase_b9_point_at_db, readme_phase_b10_key_restore, readme_phase_b11_stale_key_cleanup, readme_phase_c_rest_validation [EXTRACTED 1.00]
- **Two-Part Toolkit Architecture** — readme_python_orchestrator, readme_rsmigration_powershell_module, readme_pwsh_subprocess_boundary [EXTRACTED 1.00]
- **Dual Quality Gate System** — readme_python_quality_gate, readme_powershell_quality_gate, readme_coverage_gate_90 [EXTRACTED 1.00]

## Communities (36 total, 4 thin omitted)

### Community 0 - "Runbook Orchestrator Tests"
Cohesion: 0.08
Nodes (57): _config(), _main_argv(), _ok_completed(), _phase_calls_in_order(), Tests for rs_migration.runbook (Story 15 ACs — end-to-end orchestrator + CLI)., Common runbook() kwargs; a real RestClient is never built (validate mocked)., Extract the argv list a subprocess.run mock call was given., Return the spawn calls whose argv mentions an expected wrapper cmdlet.      The (+49 more)

### Community 1 - "Inventory Tests"
Cohesion: 0.08
Nodes (43): _client(), Tests for rs_migration.inventory (Story 12 ACs).  The PBIRS REST v2.0 boundary i, An empty catalog means a single GET /CatalogItems and no DS calls., Exactly one set_secret per Store data source; none for the others., The secret name is derived from item path + data-source name; the     pushed val, A data source not using Store yields no Key Vault write., A Store data source carrying no server credentials is recorded but     triggers, A lowercase 'store' mode (impl-doc §8.1) still triggers a push. (+35 more)

### Community 2 - "REST Client Tests"
Cohesion: 0.07
Nodes (43): Tests for rs_migration.rest_client (Story 11 ACs).  The PBIRS REST v2.0 boundary, X-XSRF-TOKEN is attached to PATCH and POST, not just PUT., The /me probe happens once; the token is cached for later writes., A GET never sends X-XSRF-TOKEN, even after a prior write set one., A read-only client issues no handshake and no token header., The session's auth is an HttpNtlmAuth when user/password are given., The session carrying HttpNtlmAuth is the one used for each request.      The ses, Without credentials the session uses no NTLM auth. (+35 more)

### Community 3 - "Toolkit Architecture & Concepts"
Cohesion: 0.08
Nodes (43): Azure Key Vault, Backup-RsMigrationDatabase cmdlet, Backup-RsMigrationKey cmdlet, 90% Coverage Gate, DefaultAzureCredential, Dry Run (read-only phases), ReportServer Encryption Key (.snk), .env Configuration (+35 more)

### Community 4 - "Re-key Tests"
Cohesion: 0.13
Nodes (38): Mocker, _client(), _credentials_in_server(), _data_model_data_source(), _mock_handshake(), Tests for rs_migration.rekey (Story 13 ACs).  The PBIRS REST v2.0 boundary is mo, The PATCH body is a JSON array with CredentialRetrieval + both blocks., CredentialRetrieval is always in the body, even for non-Store modes. (+30 more)

### Community 5 - "Key Vault Helpers & Tests"
Cohesion: 0.11
Nodes (21): Tests for rs_migration.keyvault (Story 10 ACs)., Build a fake SecretClient.get_secret() return object., get_secret returns the secret value from a mocked SecretClient., The client is constructed against the vault's full URL., get_secret_bytes base64-decodes the stored secret value to bytes., set_secret forwards (name, value) to the client's set_secret., _secret(), test_get_secret_builds_vault_url() (+13 more)

### Community 6 - "Validation Tests"
Cohesion: 0.16
Nodes (20): _client(), Tests for rs_migration.validate (Story 14 ACs — validation over REST).  The PBIR, Subscriptions are confirmed by enumerating GET /Subscriptions., An empty Subscriptions collection records subscriptions_present=False., ok is True when every render passes, every source connects, subs present., A single failed data-source probe drives the aggregate ok to False., Every report is rendered over REST; a 2xx render records success=True., A non-2xx render records success=False for that report and ok=False. (+12 more)

### Community 7 - "REST Client Internals"
Cohesion: 0.18
Nodes (10): Response, Any, Return the XSRF token, performing the handshake on first use., Raise :class:`RestClientError` for any non-2xx response., Issue a write (PUT/PATCH/POST) carrying the XSRF header., Return the decoded JSON body, or ``None`` when there is none., GET ``endpoint`` (no XSRF header) and return the JSON body., PUT ``endpoint`` with the XSRF header; returns the JSON body. (+2 more)

### Community 8 - "REST Errors & Validation Logic"
Cohesion: 0.15
Nodes (15): Exception, A long, credential-free body is previewed (truncated) in the message,     while, An empty body produces a clean message and an empty .body., test_error_message_empty_body_is_handled(), test_error_message_includes_truncated_preview_for_safe_long_body(), Raised when the PBIRS REST API returns a non-2xx response., RestClientError, _probe_data_source() (+7 more)

### Community 9 - "CLI Argument Parsing"
Cohesion: 0.24
Nodes (11): ArgumentParser, _add_required(), _build_parser(), _env(), _env_flag(), _env_list(), Return env var ``name``'s value, or ``None`` when it is unset or empty., Parse a comma-separated env var into a list (``[]`` when unset). (+3 more)

### Community 10 - "Python Module Cores"
Cohesion: 0.20
Nodes (5): Catalog inventory over REST (impl-doc §8.1 / A1).  The Python counterpart to the, Re-key catalog-item data sources over PBIRS REST v2.0 (impl-doc §8 / §8.1).  The, PBIRS REST v2.0 client with XSRF handshake + NTLM auth (impl-doc §8.1).  Mirrors, Render ``body`` safe to embed in a (loggable) exception message.      If the bod, _safe_body_for_message()

### Community 11 - "Key Backup/Restore Cmdlets"
Cohesion: 0.25
Nodes (4): Get-KeyVaultSecret(), Resolve-RsConnection(), Backup-RsMigrationKey(), Restore-RsMigrationKey()

### Community 12 - "Report Render & Validation Cmdlets"
Cohesion: 0.33
Nodes (3): Invoke-RsReportRender(), Test-RsDataSourceConnection(), Invoke-RsMigrationValidation()

### Community 13 - "Database Backup/Restore Cmdlets"
Cohesion: 0.33
Nodes (3): New-RsMigrationBlobCredential(), Backup-RsMigrationDatabase(), Restore-RsMigrationDatabase()

### Community 16 - "Pytest Fixtures"
Cohesion: 0.50
Nodes (3): mock_secret_client(), Shared pytest fixtures for the rs_migration test suite.  The Azure Key Vault bou, Patch ``rs_migration.keyvault.SecretClient`` and yield the client mock.      The

## Ambiguous Edges - Review These
- `DefaultAzureCredential` → `rest_client.py`  [AMBIGUOUS]
  README.md · relation: conceptually_related_to

## Knowledge Gaps
- **10 isolated node(s):** `SecretClient`, `ReportServer Database`, `rekey.py`, `Backup-RsMigrationDatabase cmdlet`, `Restore-RsMigrationDatabase cmdlet` (+5 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `DefaultAzureCredential` and `rest_client.py`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `RestClient` connect `REST Client Tests` to `Runbook Orchestrator Tests`, `Inventory Tests`, `Re-key Tests`, `Validation Tests`, `REST Client Internals`, `REST Errors & Validation Logic`, `CLI Argument Parsing`, `Python Module Cores`?**
  _High betweenness centrality (0.324) - this node is a cross-community bridge._
- **Why does `runbook()` connect `Runbook Orchestrator Tests` to `Inventory Tests`, `Validation Tests`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **Why does `inventory()` connect `Inventory Tests` to `Runbook Orchestrator Tests`, `Python Module Cores`?**
  _High betweenness centrality (0.030) - this node is a cross-community bridge._
- **Are the 12 inferred relationships involving `RestClient` (e.g. with `ArgumentParser` and `Mocker`) actually correct?**
  _`RestClient` has 12 INFERRED edges - model-reasoned connections that need verification._
- **What connects `rs_migration: Python orchestrator for the SSRS to PBIRS migration toolkit.`, `Catalog inventory over REST (impl-doc §8.1 / A1).  The Python counterpart to the`, `Per-item data-sources endpoint: ``CatalogItems(<id>)/DataSources``.` to the rest of the system?**
  _146 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Runbook Orchestrator Tests` be split into smaller, more focused modules?**
  _Cohesion score 0.07740112994350283 - nodes in this community are weakly interconnected._