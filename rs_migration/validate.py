"""Post-migration validation over the PBIRS REST v2.0 API (impl-doc §8.1 / §6 Phase C).

This is the REST-observable half of the migration's definition of done
(impl-doc §10): every report renders, every data source connects, and
subscriptions are present. Each check is performed over REST against the
:class:`~rs_migration.rest_client.RestClient` (the network boundary is mocked
in tests), and the results are folded into a single aggregate whose ``ok``
flag is the AND of every individual check.

Scope note: confirming the auto-recreated ``msdb`` SQL Agent subscription
*jobs* (the SQL half of impl-doc C13) is **out of scope here** — that lives in
the PowerShell ``Invoke-RsMigrationValidation`` (Story 9). Here we only confirm
subscriptions are *present* via the REST ``GET /Subscriptions`` enumeration.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from rs_migration.rest_client import RestClient, RestClientError

#: REST endpoint enumerating every subscription on the server.
_SUBSCRIPTIONS_ENDPOINT = "Subscriptions"


def _render_report(client: RestClient, report: str) -> bool:
    """Render ``report`` over REST, returning ``True`` on a 2xx response.

    A non-2xx render (surfaced as :class:`RestClientError`) is recorded as a
    failure rather than propagated, so one broken report does not abort the
    whole validation pass.
    """
    try:
        client.get(f"CatalogItems({report})/Model.GetRenderStream")
    except RestClientError:
        return False
    return True


def _probe_data_source(client: RestClient, data_source: str) -> bool:
    """Probe ``data_source`` connectivity over REST, ``True`` when it connects."""
    try:
        client.get(f"DataSources({data_source})/Model.GetConnectionString")
    except RestClientError:
        return False
    return True


def _subscriptions_present(client: RestClient) -> bool:
    """Return ``True`` when ``GET /Subscriptions`` enumerates at least one item."""
    body = client.get(_SUBSCRIPTIONS_ENDPOINT)
    items = (body or {}).get("value", []) if isinstance(body, dict) else []
    return len(items) > 0


def validate(
    client: RestClient,
    reports: Iterable[str],
    data_sources: Iterable[str],
) -> dict[str, Any]:
    """Validate a migrated PBIRS server over REST and return an aggregate result.

    Args:
        client: A configured :class:`RestClient` for the target server.
        reports: Catalog-item identifiers of the reports to render-test.
        data_sources: Identifiers of the data sources to probe for connectivity.

    Returns:
        A dict with:

        - ``reports``: ``[{"report": id, "success": bool}, ...]`` — per-report
          render outcome.
        - ``data_sources``: ``[{"data_source": id, "connected": bool}, ...]`` —
          per-source connectivity.
        - ``subscriptions_present``: whether ``GET /Subscriptions`` returned any.
        - ``ok``: ``True`` only when every render passed, every source
          connected, and subscriptions are present; ``False`` if any check
          failed.
    """
    report_results = [
        {"report": report, "success": _render_report(client, report)}
        for report in reports
    ]
    data_source_results = [
        {"data_source": ds, "connected": _probe_data_source(client, ds)}
        for ds in data_sources
    ]
    subscriptions_present = _subscriptions_present(client)

    ok = (
        all(r["success"] for r in report_results)
        and all(d["connected"] for d in data_source_results)
        and subscriptions_present
    )

    return {
        "reports": report_results,
        "data_sources": data_source_results,
        "subscriptions_present": subscriptions_present,
        "ok": ok,
    }
