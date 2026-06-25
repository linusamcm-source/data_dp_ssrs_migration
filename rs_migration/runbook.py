"""End-to-end migration runbook orchestrator + ``rs-migration`` CLI (impl-doc §6 / §8.1).

Drives the ordered migration phases of impl-doc §6 (primary key-migration path):

    key backup (A4) -> DB backup (B7) -> DB restore (B8) -> point-at-DB (B9)
    -> key restore (B10) -> stale-key cleanup (B11) -> validation (Phase C)

The PowerShell phases spawn the toolkit's OWN wrapper cmdlets (Stories 2-5) —
``Backup-RsMigrationKey``, ``Backup-RsMigrationDatabase``,
``Restore-RsMigrationDatabase``, ``Set-RsMigrationDatabase``,
``Restore-RsMigrationKey``, ``Remove-RsMigrationStaleKey`` — NOT the bare
upstream library cmdlets. Each phase is spawned via :func:`subprocess.run`
against ``pwsh`` with its required parameters threaded from a
:class:`MigrationConfig`. The subprocess boundary is the seam tested in this
story; the cmdlets themselves are exercised by their own Pester suites. The
final validation phase is REST-only: it uses Story 14's
:func:`rs_migration.validate.validate` (not a PowerShell cmdlet, not a
subprocess).

On any phase failing — a mutating subprocess returning a non-zero exit code, or
the REST validation reporting ``ok`` False — the runbook ABORTS the remaining
phases and reports the failing phase name (no silent continue).

Dry-run mode (``dry_run=True``) runs only the read-only phases — the catalog
inventory enumeration (:func:`rs_migration.inventory.inventory`) and the REST
validation read path — and performs ZERO mutating subprocess or SQL calls.

The :func:`main` console entry (registered as ``rs-migration``) parses args,
builds the :class:`MigrationConfig`, runs the runbook, and returns a non-zero
exit code when the runbook reports failure, 0 on success.
"""

from __future__ import annotations

import argparse
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass

from rs_migration.inventory import inventory
from rs_migration.rest_client import RestClient
from rs_migration.validate import validate

#: PowerShell executable used to spawn the wrapper-cmdlet phases.
_PWSH = "pwsh"

#: Name reported when the REST validation phase itself fails.
_VALIDATION_PHASE = "validation"


@dataclass
class MigrationConfig:
    """Parameters threaded into each mutating phase's wrapper-cmdlet argv.

    These are the inputs the toolkit wrapper cmdlets (impl-doc §6 A4 / B7-B11)
    require. The runbook builds each phase's ``pwsh`` argv from this config so
    ``vault`` / key material / instance / blob / machine-name inputs actually
    reach the phases (the original defect spawned bare cmdlets with no args).

    Attributes:
        vault: Azure Key Vault name holding the key password + ``.snk`` secrets.
        key_path: Filesystem path of the ``.snk`` encryption key.
        key_password_secret: Key Vault secret *name* holding the key password.
        snk_secret: Key Vault secret *name* the base64 ``.snk`` is pushed to.
        source_sql_instance: SOURCE SQL instance backed up FROM (B7).
        target_sql_instance: TARGET SQL instance restored ONTO (B8).
        azure_base_url: Blob container URL backups are written to / read from.
        blob_model: Blob-auth model (``SAS`` | ``StorageKey`` | ``ManagedIdentity``).
        database_server_name: SQL server PBIRS is pointed at (B9).
        database_name: ReportServer database name to bind (B9) and clean (B11).
        stale_machine_name: Stale source machine whose ``dbo.Keys`` row is removed.
        active_machine_name: Active target machine that must never be deleted.
    """

    vault: str
    key_path: str
    key_password_secret: str
    snk_secret: str
    source_sql_instance: str
    target_sql_instance: str
    azure_base_url: str
    database_server_name: str
    database_name: str
    stale_machine_name: str
    active_machine_name: str
    blob_model: str = "SAS"


@dataclass
class RunbookResult:
    """Outcome of a runbook execution.

    Attributes:
        ok: ``True`` only when every executed phase succeeded.
        failed_phase: The name of the first phase that failed, or ``None`` on
            success.
        dry_run: Whether the run was a read-only dry-run.
    """

    ok: bool
    failed_phase: str | None
    dry_run: bool


def _mutating_phases(config: MigrationConfig) -> list[tuple[str, list[str]]]:
    """Build the ordered ``(phase_name, [cmdlet, -Param, value, ...])`` phases.

    In impl-doc §6 order, each phase pairs its name with the toolkit WRAPPER
    cmdlet and the discrete argv tokens (param name + value) the cmdlet
    requires — threaded from ``config``. Tokens are kept discrete (never
    interpolated into one string) so user data cannot inject PowerShell
    expressions.
    """
    return [
        (
            "backup-key",  # A4
            [
                "Backup-RsMigrationKey",
                "-VaultName",
                config.vault,
                "-KeyPath",
                config.key_path,
                "-PasswordSecretName",
                config.key_password_secret,
                "-SnkSecretName",
                config.snk_secret,
            ],
        ),
        (
            "backup-db",  # B7 (previously missing)
            [
                "Backup-RsMigrationDatabase",
                "-SqlInstance",
                config.source_sql_instance,
                "-AzureBaseUrl",
                config.azure_base_url,
                "-Model",
                config.blob_model,
            ],
        ),
        (
            "restore-db",  # B8
            [
                "Restore-RsMigrationDatabase",
                "-SqlInstance",
                config.target_sql_instance,
                "-AzureBaseUrl",
                config.azure_base_url,
                "-Model",
                config.blob_model,
            ],
        ),
        (
            "point-at-db",  # B9
            [
                "Set-RsMigrationDatabase",
                "-DatabaseServerName",
                config.database_server_name,
                "-Name",
                config.database_name,
            ],
        ),
        (
            "restore-key",  # B10
            [
                "Restore-RsMigrationKey",
                "-VaultName",
                config.vault,
                "-KeyPath",
                config.key_path,
                "-PasswordSecretName",
                config.key_password_secret,
            ],
        ),
        (
            "stale-key",  # B11
            [
                "Remove-RsMigrationStaleKey",
                "-SqlInstance",
                config.target_sql_instance,
                "-Database",
                config.database_name,
                "-MachineName",
                config.stale_machine_name,
                "-ActiveMachineName",
                config.active_machine_name,
            ],
        ),
    ]


def _run_cmdlet(cmdlet: str, *cmdlet_args: str) -> int:
    """Spawn the wrapper ``cmdlet`` with discrete argv tokens; return its exit code.

    The wrapper cmdlet name and every parameter (``-Param``, value, ...) are
    forwarded as DISCRETE argv tokens after ``-Command``, so PowerShell binds
    each value to a named parameter rather than evaluating an interpolated
    expression — caller data cannot inject a PowerShell expression. Keeping the
    tokens discrete also lets the tests introspect the exact call shape. The
    subprocess boundary is mocked in tests; here we only build the argv and
    surface the child's ``returncode``.
    """
    completed = subprocess.run(
        [_PWSH, "-NoProfile", "-Command", cmdlet, *cmdlet_args],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.returncode


def runbook(
    client: RestClient,
    config: MigrationConfig,
    reports: Sequence[str],
    data_sources: Sequence[str],
    dry_run: bool = False,
) -> RunbookResult:
    """Execute the end-to-end migration runbook (impl-doc §6) and report the outcome.

    Args:
        client: A configured :class:`RestClient` for the target PBIRS server,
            used by the read-only inventory + validation phases.
        config: The :class:`MigrationConfig` carrying the per-phase parameters
            threaded into each wrapper-cmdlet argv.
        reports: Catalog-item ids to render-test in the validation phase.
        data_sources: Data-source ids to probe in the validation phase.
        dry_run: When ``True``, run ONLY the read-only phases (inventory +
            validation) and perform no mutating subprocess or SQL calls.

    Returns:
        A :class:`RunbookResult`. ``ok`` is ``False`` and ``failed_phase`` names
        the offending phase if any mutating cmdlet returns non-zero or the REST
        validation reports ``ok`` False; the remaining phases are then skipped.
    """
    if not dry_run:
        for phase_name, argv in _mutating_phases(config):
            returncode = _run_cmdlet(*argv)
            if returncode != 0:
                return RunbookResult(
                    ok=False, failed_phase=phase_name, dry_run=dry_run
                )
    else:
        # Read-only catalog enumeration (no mutation) — exercises the same REST
        # read path the inventory phase uses in a real pre-migration dry-run.
        inventory(client, config.vault)

    validation = validate(client, reports, data_sources)
    if not validation.get("ok", False):
        return RunbookResult(
            ok=False, failed_phase=_VALIDATION_PHASE, dry_run=dry_run
        )

    return RunbookResult(ok=True, failed_phase=None, dry_run=dry_run)


def _build_parser() -> argparse.ArgumentParser:
    """Build the ``rs-migration`` argument parser."""
    parser = argparse.ArgumentParser(
        prog="rs-migration",
        description=(
            "Drive the end-to-end SSRS->PBIRS migration runbook (impl-doc §6)."
        ),
    )
    parser.add_argument(
        "--server", required=True, help="Target PBIRS hostname (no scheme/path)."
    )
    parser.add_argument(
        "--vault", required=True, help="Azure Key Vault name for stored secrets."
    )
    parser.add_argument(
        "--key-path",
        required=True,
        help="Filesystem path of the .snk encryption key.",
    )
    parser.add_argument(
        "--key-password-secret",
        required=True,
        help="Key Vault secret name holding the key password.",
    )
    parser.add_argument(
        "--snk-secret",
        required=True,
        help="Key Vault secret name the base64 .snk is pushed to.",
    )
    parser.add_argument(
        "--source-sql-instance",
        required=True,
        help="SOURCE SQL instance the ReportServer DBs are backed up FROM (B7).",
    )
    parser.add_argument(
        "--target-sql-instance",
        required=True,
        help="TARGET SQL instance the ReportServer DBs are restored ONTO (B8).",
    )
    parser.add_argument(
        "--azure-base-url",
        required=True,
        help="Blob container URL backups are written to / restored from.",
    )
    parser.add_argument(
        "--blob-model",
        default="SAS",
        choices=["SAS", "StorageKey", "ManagedIdentity"],
        help="Blob-auth model for backup/restore (default: SAS).",
    )
    parser.add_argument(
        "--database-server-name",
        required=True,
        help="SQL server PBIRS is pointed at (B9).",
    )
    parser.add_argument(
        "--database-name",
        required=True,
        help="ReportServer database name to bind (B9) and clean (B11).",
    )
    parser.add_argument(
        "--stale-machine-name",
        required=True,
        help="Stale source machine whose dbo.Keys row is removed (B11).",
    )
    parser.add_argument(
        "--active-machine-name",
        required=True,
        help="Active target machine that must never be deleted (B11).",
    )
    parser.add_argument(
        "--report",
        dest="reports",
        action="append",
        default=[],
        help="Catalog-item id to render-test (repeatable).",
    )
    parser.add_argument(
        "--data-source",
        dest="data_sources",
        action="append",
        default=[],
        help="Data-source id to probe (repeatable).",
    )
    parser.add_argument(
        "--username", default=None, help="NTLM username (enables NTLM auth)."
    )
    parser.add_argument(
        "--password", default=None, help="NTLM password (with --username)."
    )
    parser.add_argument(
        "--scheme",
        default="https",
        choices=["http", "https"],
        help="URL scheme for the report server (default: https).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run only the read-only phases (no mutating cmdlets).",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Console entry point for ``rs-migration``.

    Parses ``argv`` (defaults to ``sys.argv[1:]``), builds the
    :class:`MigrationConfig`, runs the runbook, and returns a process exit code:
    ``0`` on success, non-zero when the runbook reports failure.
    """
    args = _build_parser().parse_args(argv)

    client = RestClient(
        args.server,
        username=args.username,
        password=args.password,
        scheme=args.scheme,
    )

    config = MigrationConfig(
        vault=args.vault,
        key_path=args.key_path,
        key_password_secret=args.key_password_secret,
        snk_secret=args.snk_secret,
        source_sql_instance=args.source_sql_instance,
        target_sql_instance=args.target_sql_instance,
        azure_base_url=args.azure_base_url,
        blob_model=args.blob_model,
        database_server_name=args.database_server_name,
        database_name=args.database_name,
        stale_machine_name=args.stale_machine_name,
        active_machine_name=args.active_machine_name,
    )

    result = runbook(
        client=client,
        config=config,
        reports=args.reports,
        data_sources=args.data_sources,
        dry_run=args.dry_run,
    )

    if not result.ok:
        print(f"runbook FAILED at phase: {result.failed_phase}")
        return 1

    print("runbook OK")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
