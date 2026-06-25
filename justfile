opus:
    @claude --dangerously-skip-permissions "/caveman"

# PowerShell quality gate: Pester (>=90% coverage) + PSScriptAnalyzer.
qg-ps:
    pwsh -NoProfile -File scripts/qg-ps.ps1

# Python quality gate: self-bootstrap a worktree-local venv (uv; pip fallback), pytest (>=90% coverage) + ruff.
qg-py:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v uv >/dev/null 2>&1; then
        [ -d .venv ] || uv venv .venv
        uv pip install -q -e '.[dev]'
    else
        [ -d .venv ] || python3 -m venv .venv
        .venv/bin/python -m pip install -q --upgrade pip
        .venv/bin/python -m pip install -q -e '.[dev]'
    fi
    .venv/bin/python -m pytest --cov=rs_migration --cov-report=term-missing --cov-fail-under=90 tests/python
    .venv/bin/ruff check rs_migration tests/python