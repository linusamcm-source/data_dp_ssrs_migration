"""End-to-end migration runbook orchestrator + ``rs-migration`` CLI (impl-doc §6 / §8.1).

Drives the ordered migration phases of impl-doc §6 (primary key-migration path):

    key/DB backup -> restore -> point-at-DB -> key restore -> stale-key cleanup
    -> validation

The PowerShell key/DB cmdlet phases (owned by Stories 2-5 / dbatools) are spawned
via :func:`subprocess.run` against ``pwsh`` — the subprocess boundary is the
seam tested in this story; the cmdlets themselves are not exercised here. The
final validation phase is REST-only: it uses Story 14's
:func:`rs_migration.validate.validate` (not a PowerShell cmdlet and not a
subprocess).

On any phase failing — a mutating subprocess returning a non-zero exit code, or
the REST validation reporting ``ok`` False — the runbook ABORTS the remaining
phases and reports the failing phase name (no silent continue).

Dry-run mode (``dry_run=True``) runs only the read-only phases — the catalog
inventory enumeration (:func:`rs_migration.inventory.inventory`) and the REST
validation read path — and performs ZERO mutating subprocess or SQL calls.

The :func:`main` console entry (registered as ``rs-migration``) parses args,
runs the runbook, and returns a non-zero exit code when the runbook reports
failure, 0 on success.
"""

from __future__ import annotations

import argparse
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass

from rs_migration.inventory import inventory
from rs_migration.rest_client import RestClient
from rs_migration.validate import validate

#: PowerShell executable used to spawn the key/DB cmdlet phases.
_PWSH = "pwsh"

#: The mutating phases, in impl-doc §6 order, each paired with the PowerShell
#: cmdlet it spawns (cmdlet ⇄ source map, impl-doc §13):
#:   key/DB backup -> restore -> point-at-DB -> key restore -> stale-key cleanup.
_MUTATING_PHASES: tuple[tuple[str, str], ...] = (
    ("backup", "Backup-RsEncryptionKey"),
    ("restore", "Restore-DbaDatabase"),
    ("point-at-db", "Set-RsDatabase"),
    ("key-restore", "Restore-RsEncryptionKey"),
    ("stale-key", "Invoke-DbaQuery"),
)

#: Name reported when the REST validation phase itself fails.
_VALIDATION_PHASE = "validation"


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


def _run_cmdlet(cmdlet: str, *cmdlet_args: str) -> int:
    """Spawn ``pwsh -Command "<cmdlet> <args>"`` and return its exit code.

    The subprocess boundary is mocked in tests; here we only build the argv and
    surface the child's ``returncode``.
    """
    command = " ".join((cmdlet, *cmdlet_args)).strip()
    completed = subprocess.run(
        [_PWSH, "-NoProfile", "-Command", command],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.returncode


def runbook(
    client: RestClient,
    vault: str,
    reports: Sequence[str],
    data_sources: Sequence[str],
    dry_run: bool = False,
) -> RunbookResult:
    """Execute the end-to-end migration runbook (impl-doc §6) and report the outcome.

    Args:
        client: A configured :class:`RestClient` for the target PBIRS server,
            used by the read-only inventory + validation phases.
        vault: Azure Key Vault name the inventory read path enumerates against.
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
        for phase_name, cmdlet in _MUTATING_PHASES:
            returncode = _run_cmdlet(cmdlet)
            if returncode != 0:
                return RunbookResult(
                    ok=False, failed_phase=phase_name, dry_run=dry_run
                )
    else:
        # Read-only catalog enumeration (no mutation) — exercises the same REST
        # read path the inventory phase uses in a real pre-migration dry-run.
        inventory(client, vault)

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

    Parses ``argv`` (defaults to ``sys.argv[1:]``), runs the runbook, and
    returns a process exit code: ``0`` on success, non-zero when the runbook
    reports failure.
    """
    args = _build_parser().parse_args(argv)

    client = RestClient(
        args.server,
        username=args.username,
        password=args.password,
        scheme=args.scheme,
    )

    result = runbook(
        client=client,
        vault=args.vault,
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
