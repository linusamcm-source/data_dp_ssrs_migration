"""Tests for rs_migration.runbook (Story 15 ACs — end-to-end orchestrator + CLI).

The migration's cross-stack boundaries are mocked here:

- The PowerShell cmdlet phases (key/DB backup, restore, point-at-DB, key
  restore, stale-key cleanup) are spawned via ``subprocess.run``; that boundary
  is patched (``rs_migration.runbook.subprocess.run``) so tests assert the
  ordered cmdlet invocations without ever spawning ``pwsh``.
- The REST validation phase uses Story 14's ``rs_migration.validate.validate``;
  it is patched so the runbook tests stay decoupled from the REST wire.
- The dry-run read path's inventory enumeration uses Story 12's
  ``rs_migration.inventory.inventory``; it too is patched.

Each test maps to a Story 15 acceptance criterion:

- AC1: ``runbook()`` invokes the PowerShell cmdlets in impl-doc §6 order —
  key/DB backup -> restore -> point-at-DB -> key restore -> stale-key cleanup —
  then runs the REST validation (call order asserted via the mocked subprocess).
- AC2: a phase returning a non-zero result aborts the remaining phases and
  reports the failing phase name (later phases are NOT called).
- AC3: dry-run runs ONLY the read-only phases (inventory + REST validation) and
  performs ZERO mutating subprocess calls.
- AC4: the ``main()`` console entry returns a non-zero exit code on runbook
  failure and 0 on success.
"""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from rs_migration.runbook import RunbookResult, main
from rs_migration.runbook import runbook as run_runbook

# The mutating PowerShell phases, in impl-doc §6 order, paired with the cmdlet
# each phase is expected to spawn. The validation phase is REST (Story 14), not
# a subprocess, so it is asserted separately.
_EXPECTED_MUTATING_ORDER = [
    ("backup", "Backup-RsEncryptionKey"),
    ("restore", "Restore-DbaDatabase"),
    ("point-at-db", "Set-RsDatabase"),
    ("key-restore", "Restore-RsEncryptionKey"),
    ("stale-key", "Invoke-DbaQuery"),
]


def _ok_completed(returncode: int = 0):
    """A subprocess.run return value double (only returncode is read)."""
    return SimpleNamespace(returncode=returncode, stdout="", stderr="")


def _runbook_kwargs(**overrides):
    """Common runbook() kwargs; a real RestClient is never built (validate mocked)."""
    base = dict(
        client=MagicMock(name="rest_client"),
        vault="kv-mig",
        reports=["Orders", "Exec"],
        data_sources=["Sales", "HR"],
    )
    base.update(overrides)
    return base


# --- AC1: phase call ORDER via the mocked subprocess boundary -----------------


def test_runbook_invokes_cmdlets_in_impl_doc_phase_order():
    """Mutating cmdlets spawn in §6 order, then REST validation runs."""
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        result = run_runbook(**_runbook_kwargs())

    # Every spawned command is a pwsh invocation; the cmdlet name is somewhere
    # in the argv. Extract the cmdlet in spawn order.
    spawned_cmdlets = []
    for call in run.call_args_list:
        argv = call.args[0] if call.args else call.kwargs["args"]
        flat = " ".join(argv)
        for _, cmdlet in _EXPECTED_MUTATING_ORDER:
            if cmdlet in flat:
                spawned_cmdlets.append(cmdlet)
                break

    assert spawned_cmdlets == [cmdlet for _, cmdlet in _EXPECTED_MUTATING_ORDER]
    # First positional element of every spawn is the pwsh executable.
    for call in run.call_args_list:
        argv = call.args[0] if call.args else call.kwargs["args"]
        assert argv[0] == "pwsh"
    # Validation ran exactly once after the mutating phases.
    validate.assert_called_once()
    assert result.ok is True
    assert result.failed_phase is None


def test_runbook_validation_phase_uses_story14_validate_not_subprocess():
    """The validation phase calls validate() over REST, not a subprocess."""
    with (
        patch("rs_migration.runbook.subprocess.run") as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        run.return_value = _ok_completed()
        validate.return_value = {"ok": True}

        run_runbook(**_runbook_kwargs())

    # The reports/data_sources reach validate over REST (kw or positional).
    all_args = list(validate.call_args.args) + list(validate.call_args.kwargs.values())
    assert ["Orders", "Exec"] in all_args
    assert ["Sales", "HR"] in all_args


# --- AC2: a failing phase aborts the rest and reports the failing phase --------


def test_failing_phase_aborts_remaining_phases_and_reports_name():
    """A non-zero subprocess return aborts later phases; the phase name is reported."""
    # 'restore' is the 2nd mutating phase (index 1); make it fail.
    failing_index = 1
    failing_phase_name = _EXPECTED_MUTATING_ORDER[failing_index][0]

    def fake_run(argv, *args, **kwargs):
        flat = " ".join(argv)
        if _EXPECTED_MUTATING_ORDER[failing_index][1] in flat:
            return _ok_completed(returncode=1)
        return _ok_completed(returncode=0)

    with (
        patch("rs_migration.runbook.subprocess.run", side_effect=fake_run) as run,
        patch("rs_migration.runbook.validate") as validate,
    ):
        result = run_runbook(**_runbook_kwargs())

    assert result.ok is False
    assert result.failed_phase == failing_phase_name

    # Only the phases up to and including the failing one were spawned.
    spawned = []
    for call in run.call_args_list:
        argv = call.args[0]
        flat = " ".join(argv)
        for name, cmdlet in _EXPECTED_MUTATING_ORDER:
            if cmdlet in flat:
                spawned.append(name)
    assert spawned == [name for name, _ in _EXPECTED_MUTATING_ORDER[: failing_index + 1]]

    # The phases after the failure were NOT spawned.
    later = {name for name, _ in _EXPECTED_MUTATING_ORDER[failing_index + 1 :]}
    assert later.isdisjoint(spawned)

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

    # ZERO subprocess calls at all in dry-run (no mutation).
    run.assert_not_called()
    # Read-only phases still ran.
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
            ok=False, failed_phase="restore", dry_run=False
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


def test_main_builds_rest_client_from_server_arg():
    """main() constructs a RestClient for the --server host and passes it on."""
    with (
        patch("rs_migration.runbook.runbook") as rb,
        patch("rs_migration.runbook.RestClient") as client_cls,
    ):
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=False)
        main(_main_argv())

    client_cls.assert_called_once()
    # The server host reaches the RestClient constructor.
    ctor_args = list(client_cls.call_args.args) + list(client_cls.call_args.kwargs.values())
    assert "pbirs.contoso.com" in ctor_args
    # The constructed client is the one handed to runbook().
    assert rb.call_args.kwargs["client"] is client_cls.return_value


def test_main_exit_code_is_an_int_for_sys_exit():
    """main() returns an int suitable for the console-script SystemExit contract."""
    with patch("rs_migration.runbook.runbook") as rb:
        rb.return_value = RunbookResult(ok=True, failed_phase=None, dry_run=False)
        code = main(_main_argv())
    assert isinstance(code, int)
