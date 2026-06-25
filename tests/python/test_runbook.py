"""Tests for rs_migration.runbook (Story 15 ACs — end-to-end orchestrator + CLI).

The migration's cross-stack boundaries are mocked here:

- The PowerShell wrapper-cmdlet phases (key backup, DB backup, DB restore,
  point-at-DB, key restore, stale-key cleanup) are spawned via
  ``subprocess.run``; that boundary is patched
  (``rs_migration.runbook.subprocess.run``) so tests assert the ordered,
  *parameterised* cmdlet invocations without ever spawning ``pwsh``.
- The REST validation phase uses Story 14's ``rs_migration.validate.validate``;
  it is patched so the runbook tests stay decoupled from the REST wire.
- The dry-run read path's inventory enumeration uses Story 12's
  ``rs_migration.inventory.inventory``; it too is patched.

Each test maps to a Story 15 acceptance criterion:

- AC1: ``runbook()`` invokes the TOOLKIT WRAPPER cmdlets in impl-doc §6 order —
  key backup (A4) -> DB backup (B7) -> DB restore (B8) -> point-at-DB (B9) ->
  key restore (B10) -> stale-key cleanup (B11) — then runs the REST validation.
  The call ORDER *and the per-phase parameters* are asserted via the mocked
  subprocess (a wrong cmdlet or a missing required parameter fails the gate).
- AC2: a phase returning a non-zero result aborts the remaining phases and
  reports the failing phase name (later phases are NOT called).
- AC3: dry-run runs ONLY the read-only phases (inventory + REST validation) and
  performs ZERO mutating subprocess calls.
- AC4: the ``main()`` console entry returns a non-zero exit code on runbook
  failure and 0 on success.
"""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from rs_migration.runbook import MigrationConfig, RunbookResult, main
from rs_migration.runbook import runbook as run_runbook

# The mutating PowerShell phases, in impl-doc §6 order, paired with the TOOLKIT
# WRAPPER cmdlet each phase must spawn (NOT the bare upstream cmdlet) and the
# key parameters that must appear in its argv. The validation phase is REST
# (Story 14), not a subprocess, so it is asserted separately.
#
# Each entry: (phase_name, wrapper_cmdlet, [required -Param flags]).
_EXPECTED_MUTATING_ORDER = [
    (
        "backup-key",
        "Backup-RsMigrationKey",
        ["-VaultName", "-KeyPath", "-PasswordSecretName", "-SnkSecretName"],
    ),
    (
        "backup-db",
        "Backup-RsMigrationDatabase",
        ["-SqlInstance", "-AzureBaseUrl"],
    ),
    (
        "restore-db",
        "Restore-RsMigrationDatabase",
        ["-SqlInstance", "-AzureBaseUrl"],
    ),
    (
        "point-at-db",
        "Set-RsMigrationDatabase",
        ["-DatabaseServerName", "-Name"],
    ),
    (
        "restore-key",
        "Restore-RsMigrationKey",
        ["-VaultName", "-KeyPath", "-PasswordSecretName"],
    ),
    (
        "stale-key",
        "Remove-RsMigrationStaleKey",
        ["-SqlInstance", "-Database", "-MachineName", "-ActiveMachineName"],
    ),
]


def _ok_completed(returncode: int = 0):
    """A subprocess.run return value double (only returncode is read)."""
    return SimpleNamespace(returncode=returncode, stdout="", stderr="")


def _config(**overrides):
    """A fully-populated MigrationConfig the phases build their argv from."""
    base = dict(
        vault="kv-mig",
        key_path="C:\\rs\\ReportServer.snk",
        key_password_secret="rsKeyPwd",
        snk_secret="rsSnk",
        source_sql_instance="SRC\\SQL",
        target_sql_instance="TGT\\SQL",
        azure_base_url="https://blob.example.net/rs",
        blob_model="SAS",
        database_server_name="TGT\\SQL",
        database_name="ReportServer",
        stale_machine_name="OLD-SSRS",
        active_machine_name="NEW-PBIRS",
    )
    base.update(overrides)
    return MigrationConfig(**base)


def _runbook_kwargs(**overrides):
    """Common runbook() kwargs; a real RestClient is never built (validate mocked)."""
    base = dict(
        client=MagicMock(name="rest_client"),
        config=_config(),
        reports=["Orders", "Exec"],
        data_sources=["Sales", "HR"],
    )
    base.update(overrides)
    return base


def _spawned_argv(call):
    """Extract the argv list a subprocess.run mock call was given."""
    return call.args[0] if call.args else call.kwargs["args"]


def _phase_calls_in_order(run_mock):
    """Return the spawn calls whose argv mentions an expected wrapper cmdlet.

    The returned list is in spawn order, each paired with the wrapper cmdlet
    name found in its argv.
    """
    found = []
    for call in run_mock.call_args_list:
        argv = _spawned_argv(call)
        flat = " ".join(argv)
        for _, cmdlet, _params in _EXPECTED_MUTATING_ORDER:
            if cmdlet in argv or cmdlet in flat:
                found.append((cmdlet, argv))
                break
    return found


# --- AC1: phase call ORDER *and parameters* via the mocked subprocess ----------


def test_runbook_spawns_wrapper_cmdlets_in_impl_doc_six_phase_order():
    """All SIX wrapper cmdlets spawn in §6 order (incl. the B7 DB backup)."""
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        result = run_runbook(**_runbook_kwargs())

    spawned = [cmdlet for cmdlet, _argv in _phase_calls_in_order(run)]
    expected = [cmdlet for _, cmdlet, _ in _EXPECTED_MUTATING_ORDER]
    assert spawned == expected
    # Exactly six mutating subprocess spawns — no missing/extra phase.
    assert run.call_count == len(_EXPECTED_MUTATING_ORDER)
    # Every spawn is a pwsh invocation.
    for call in run.call_args_list:
        argv = _spawned_argv(call)
        assert argv[0] == "pwsh"
    validate.assert_called_once()
    assert result.ok is True
    assert result.failed_phase is None


def test_each_phase_argv_carries_its_required_parameters():
    """Every mutating phase passes its wrapper cmdlet's mandatory -Param flags.

    A wrong cmdlet or a missing required parameter (the original argless defect)
    fails here.
    """
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        run_runbook(**_runbook_kwargs())

    calls = _phase_calls_in_order(run)
    by_cmdlet = {cmdlet: argv for cmdlet, argv in calls}

    for _phase, cmdlet, required_params in _EXPECTED_MUTATING_ORDER:
        assert cmdlet in by_cmdlet, f"phase {cmdlet} was never spawned"
        argv = by_cmdlet[cmdlet]
        for param in required_params:
            assert param in argv, f"{cmdlet} argv missing required {param}: {argv}"
        # Each -Param flag is immediately followed by a discrete value token
        # (parameters threaded as separate argv tokens, never a single
        # interpolated -Command string).
        for param in required_params:
            idx = argv.index(param)
            assert idx + 1 < len(argv), f"{cmdlet} {param} has no value token"
            value = argv[idx + 1]
            assert value and not value.startswith("-"), (
                f"{cmdlet} {param} value looks empty/missing: {value!r}"
            )


def test_phase_argv_threads_config_values_from_runbook_inputs():
    """The config's values (vault, instances, urls, machines) reach the argv."""
    cfg = _config()
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        run_runbook(**_runbook_kwargs(config=cfg))

    by_cmdlet = {cmdlet: argv for cmdlet, argv in _phase_calls_in_order(run)}

    def value_after(cmdlet, param):
        argv = by_cmdlet[cmdlet]
        return argv[argv.index(param) + 1]

    # Key phases carry the vault + key material.
    assert value_after("Backup-RsMigrationKey", "-VaultName") == cfg.vault
    assert value_after("Backup-RsMigrationKey", "-KeyPath") == cfg.key_path
    assert (
        value_after("Backup-RsMigrationKey", "-PasswordSecretName")
        == cfg.key_password_secret
    )
    assert value_after("Backup-RsMigrationKey", "-SnkSecretName") == cfg.snk_secret
    assert value_after("Restore-RsMigrationKey", "-VaultName") == cfg.vault

    # DB backup reads the SOURCE instance; restore targets the TARGET instance.
    assert (
        value_after("Backup-RsMigrationDatabase", "-SqlInstance")
        == cfg.source_sql_instance
    )
    assert (
        value_after("Backup-RsMigrationDatabase", "-AzureBaseUrl") == cfg.azure_base_url
    )
    assert (
        value_after("Restore-RsMigrationDatabase", "-SqlInstance")
        == cfg.target_sql_instance
    )

    # Point-at-DB carries the DB server + DB name.
    assert (
        value_after("Set-RsMigrationDatabase", "-DatabaseServerName")
        == cfg.database_server_name
    )
    assert value_after("Set-RsMigrationDatabase", "-Name") == cfg.database_name

    # Stale-key carries the stale + active machine names (B11 safety inputs).
    assert (
        value_after("Remove-RsMigrationStaleKey", "-MachineName")
        == cfg.stale_machine_name
    )
    assert (
        value_after("Remove-RsMigrationStaleKey", "-ActiveMachineName")
        == cfg.active_machine_name
    )


def test_runbook_does_not_spawn_bare_upstream_cmdlets():
    """The original defect: bare upstream cmdlets must NOT be spawned directly."""
    bare_upstream = {
        "Backup-RsEncryptionKey",
        "Restore-DbaDatabase",
        "Set-RsDatabase",
        "Restore-RsEncryptionKey",
        "Invoke-DbaQuery",
        "Backup-DbaDatabase",
    }
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        run_runbook(**_runbook_kwargs())

    for call in run.call_args_list:
        argv = _spawned_argv(call)
        # The bare upstream cmdlet name must not be a discrete argv token.
        assert bare_upstream.isdisjoint(set(argv)), (
            f"a bare upstream cmdlet leaked into argv: {argv}"
        )


def test_runbook_validation_phase_uses_story14_validate_not_subprocess():
    """The validation phase calls validate() over REST, not a subprocess."""
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        run_runbook(**_runbook_kwargs())

    all_args = list(validate.call_args.args) + list(validate.call_args.kwargs.values())
    assert ["Orders", "Exec"] in all_args
    assert ["Sales", "HR"] in all_args


# --- AC2: a failing phase aborts the rest and reports the failing phase --------


def test_failing_phase_aborts_remaining_phases_and_reports_name():
    """A non-zero subprocess return aborts later phases; the phase name is reported."""
    # 'backup-db' (the B7 phase) is the 2nd mutating phase (index 1); fail it.
    failing_index = 1
    failing_phase_name = _EXPECTED_MUTATING_ORDER[failing_index][0]
    failing_cmdlet = _EXPECTED_MUTATING_ORDER[failing_index][1]

    def fake_run(argv, *args, **kwargs):
        if failing_cmdlet in argv:
            return _ok_completed(returncode=1)
        return _ok_completed(returncode=0)

    with (
        patch("rs_migration.runbook.subprocess.run", side_effect=fake_run) as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        result = run_runbook(**_runbook_kwargs())

    assert result.ok is False
    assert result.failed_phase == failing_phase_name

    spawned = [cmdlet for cmdlet, _argv in _phase_calls_in_order(run)]
    expected_up_to_failure = [
        cmdlet for _, cmdlet, _ in _EXPECTED_MUTATING_ORDER[: failing_index + 1]
    ]
    assert spawned == expected_up_to_failure

    later = {cmdlet for _, cmdlet, _ in _EXPECTED_MUTATING_ORDER[failing_index + 1 :]}
    assert later.isdisjoint(set(spawned))

    # Validation (which runs last) is never reached after an earlier abort.
    validate.assert_not_called()


def test_failed_validation_marks_runbook_failed():
    """When the REST validation reports ok=False, the runbook fails on 'validation'."""
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": False}

        result = run_runbook(**_runbook_kwargs())

    assert result.ok is False
    assert result.failed_phase == "validation"


# --- AC3: dry-run runs only read-only phases, zero mutating subprocess ---------


def test_dry_run_performs_zero_mutating_subprocess_calls():
    """Dry-run never spawns a mutating cmdlet; it runs inventory + validation."""
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.inventory") as inventory,
        patch("rs_migration.runbook.validate") as validate,
    ):
        inventory.return_value = [{"item_path": "/Sales", "data_source": "DB"}]
        validate.return_value = {"ok": True}

        result = run_runbook(**_runbook_kwargs(), dry_run=True)

    run.assert_not_called()
    inventory.assert_called_once()
    validate.assert_called_once()
    assert result.ok is True
    assert result.dry_run is True


def test_dry_run_passes_vault_to_inventory():
    """Dry-run inventory enumeration receives the client + vault (read path)."""
    sentinel_client = MagicMock(name="client")
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.inventory") as inventory,
        patch("rs_migration.runbook.validate") as validate,
    ):
        inventory.return_value = []
        validate.return_value = {"ok": True}

        run_runbook(**_runbook_kwargs(client=sentinel_client), dry_run=True)

    run.assert_not_called()
    args = list(inventory.call_args.args) + list(inventory.call_args.kwargs.values())
    assert sentinel_client in args
    assert "kv-mig" in args


# --- AC4: main() exit code — non-zero on failure, 0 on success ----------------


def _main_argv():
    return [
        "--server",
        "pbirs.contoso.com",
        "--vault",
        "kv-mig",
        "--key-path",
        "C:\\rs\\ReportServer.snk",
        "--key-password-secret",
        "rsKeyPwd",
        "--snk-secret",
        "rsSnk",
        "--source-sql-instance",
        "SRC\\SQL",
        "--target-sql-instance",
        "TGT\\SQL",
        "--azure-base-url",
        "https://blob.example.net/rs",
        "--database-server-name",
        "TGT\\SQL",
        "--database-name",
        "ReportServer",
        "--stale-machine-name",
        "OLD-SSRS",
        "--active-machine-name",
        "NEW-PBIRS",
        "--report",
        "Orders",
        "--data-source",
        "Sales",
    ]


def test_main_returns_zero_on_success():
    """main() returns 0 when the runbook reports success."""
    with patch("rs_migration.runbook.runbook") as rb:
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=False)
        code = main(_main_argv())
    assert code == 0


def test_main_returns_nonzero_on_runbook_failure():
    """main() returns a non-zero exit code when the runbook reports failure."""
    with patch("rs_migration.runbook.runbook") as rb:
        rb.return_value = RunbookResult(
            ok=False, failed_phase="backup-db", dry_run=False
        )
        code = main(_main_argv())
    assert code != 0


def test_main_dry_run_flag_threads_through():
    """The --dry-run CLI flag drives runbook(dry_run=True)."""
    with patch("rs_migration.runbook.runbook") as rb:
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=True)
        code = main([*_main_argv(), "--dry-run"])
    assert code == 0
    assert rb.call_args.kwargs["dry_run"] is True


def test_main_builds_migration_config_from_cli_args():
    """main() threads the CLI migration params into the MigrationConfig it builds."""
    with patch("rs_migration.runbook.runbook") as rb:
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=False)
        main(_main_argv())

    cfg = rb.call_args.kwargs["config"]
    assert isinstance(cfg, MigrationConfig)
    assert cfg.vault == "kv-mig"
    assert cfg.key_path == "C:\\rs\\ReportServer.snk"
    assert cfg.source_sql_instance == "SRC\\SQL"
    assert cfg.target_sql_instance == "TGT\\SQL"
    assert cfg.azure_base_url == "https://blob.example.net/rs"
    assert cfg.stale_machine_name == "OLD-SSRS"
    assert cfg.active_machine_name == "NEW-PBIRS"


def test_main_builds_rest_client_from_server_arg():
    """main() constructs a RestClient for the --server host and passes it on."""
    with (
        patch("rs_migration.runbook.runbook") as rb,
        patch("rs_migration.runbook.RestClient") as client_cls,
    ):
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=False)
        main(_main_argv())

    client_cls.assert_called_once()
    ctor_args = list(client_cls.call_args.args) + list(
        client_cls.call_args.kwargs.values()
    )
    assert "pbirs.contoso.com" in ctor_args
    assert rb.call_args.kwargs["client"] is client_cls.return_value


def test_main_exit_code_is_an_int_for_sys_exit():
    """main() returns an int suitable for the console-script SystemExit contract."""
    with patch("rs_migration.runbook.runbook") as rb:
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=False)
        code = main(_main_argv())
    assert isinstance(code, int)
