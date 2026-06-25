"""Tests for rs_migration.validate (Story 14 ACs — validation over REST).

The PBIRS REST v2.0 boundary is mocked with ``requests-mock`` so tests never
touch the network. Story 14 is the REST-observable validation path only:
msdb SQL-Agent-job confirmation (PowerShell Story 9) is out of scope here.

Each test maps to a Story 14 acceptance criterion:

- AC1: ``validate()`` renders each report over REST and records success/failure
  per report (including a failing render driving the aggregate ``ok`` False).
- AC2: it probes each data source over REST and records connectivity per source.
- AC3: it confirms subscriptions via the REST ``GET /Subscriptions`` endpoint
  (the asserted endpoint pins the check) and records whether any are present.
- AC4: the aggregate ``ok`` is False if any check failed, True only when all pass.
"""

import requests_mock

from rs_migration.rest_client import RestClient
from rs_migration.validate import validate

_BASE = "https://pbirs.contoso.com/Reports/api/v2.0/"


def _client() -> RestClient:
    return RestClient("pbirs.contoso.com")


# --- AC1: render each report over REST, record per-report success/failure -----


def test_renders_each_report_and_records_success_per_report():
    """Every report is rendered over REST; a 2xx render records success=True."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(f"{_BASE}CatalogItems(Orders)/Model.GetRenderStream", json={})
        m.get(f"{_BASE}CatalogItems(Exec)/Model.GetRenderStream", json={})
        m.get(f"{_BASE}Subscriptions", json={"value": [{"Id": "s1"}]})

        result = validate(
            client,
            reports=["Orders", "Exec"],
            data_sources=[],
        )

        # One render request per report, hitting the report's render endpoint.
        rendered = {
            r.url
            for r in m.request_history
            if r.url.endswith("Model.GetRenderStream")
        }
        assert rendered == {
            f"{_BASE}CatalogItems(Orders)/Model.GetRenderStream",
            f"{_BASE}CatalogItems(Exec)/Model.GetRenderStream",
        }

        # Per-report pass recording.
        reports = {r["report"]: r["success"] for r in result["reports"]}
        assert reports == {"Orders": True, "Exec": True}


def test_records_failure_for_report_whose_render_errors():
    """A non-2xx render records success=False for that report and ok=False."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(f"{_BASE}CatalogItems(Orders)/Model.GetRenderStream", json={})
        m.get(
            f"{_BASE}CatalogItems(Broken)/Model.GetRenderStream",
            status_code=500,
            json={"error": "render failed"},
        )
        m.get(f"{_BASE}Subscriptions", json={"value": [{"Id": "s1"}]})

        result = validate(
            client,
            reports=["Orders", "Broken"],
            data_sources=[],
        )

        reports = {r["report"]: r["success"] for r in result["reports"]}
        assert reports == {"Orders": True, "Broken": False}
        # A failing render alone drives the aggregate to not-ok.
        assert result["ok"] is False


# --- AC2: probe each data source over REST, record per-source connectivity ----


def test_probes_each_data_source_and_records_connectivity():
    """Each data source is probed over REST; connectivity is recorded per source."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(f"{_BASE}DataSources(Good)/Model.GetConnectionString", json={})
        m.get(
            f"{_BASE}DataSources(Bad)/Model.GetConnectionString",
            status_code=400,
            json={"error": "no connection"},
        )
        m.get(f"{_BASE}Subscriptions", json={"value": [{"Id": "s1"}]})

        result = validate(
            client,
            reports=[],
            data_sources=["Good", "Bad"],
        )

        probed = {
            r.url
            for r in m.request_history
            if r.url.endswith("Model.GetConnectionString")
        }
        assert probed == {
            f"{_BASE}DataSources(Good)/Model.GetConnectionString",
            f"{_BASE}DataSources(Bad)/Model.GetConnectionString",
        }

        sources = {d["data_source"]: d["connected"] for d in result["data_sources"]}
        assert sources == {"Good": True, "Bad": False}


# --- AC3: confirm subscriptions via the REST GET /Subscriptions endpoint -------


def test_enumerates_subscriptions_over_rest_subscriptions_endpoint():
    """Subscriptions are confirmed by enumerating GET /Subscriptions."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(
            f"{_BASE}Subscriptions",
            json={"value": [{"Id": "s1"}, {"Id": "s2"}]},
        )

        result = validate(client, reports=[], data_sources=[])

        # The check pins the exact REST subscriptions endpoint.
        sub_calls = [
            r for r in m.request_history if r.url == f"{_BASE}Subscriptions"
        ]
        assert len(sub_calls) == 1
        assert sub_calls[0].method == "GET"
        assert result["subscriptions_present"] is True


def test_records_subscriptions_absent_when_endpoint_returns_none():
    """An empty Subscriptions collection records subscriptions_present=False."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(f"{_BASE}Subscriptions", json={"value": []})

        result = validate(client, reports=[], data_sources=[])

        assert result["subscriptions_present"] is False
        # No subscriptions present is itself a failed check.
        assert result["ok"] is False


# --- AC4: aggregate ok — True only when all checks pass, False on any failure --


def test_ok_true_when_all_checks_pass():
    """ok is True when every render passes, every source connects, subs present."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(f"{_BASE}CatalogItems(Orders)/Model.GetRenderStream", json={})
        m.get(f"{_BASE}CatalogItems(Exec)/Model.GetRenderStream", json={})
        m.get(f"{_BASE}DataSources(Sales)/Model.GetConnectionString", json={})
        m.get(f"{_BASE}DataSources(HR)/Model.GetConnectionString", json={})
        m.get(f"{_BASE}Subscriptions", json={"value": [{"Id": "s1"}]})

        result = validate(
            client,
            reports=["Orders", "Exec"],
            data_sources=["Sales", "HR"],
        )

        assert result["ok"] is True


def test_ok_false_when_a_data_source_fails_to_connect():
    """A single failed data-source probe drives the aggregate ok to False."""
    client = _client()
    with requests_mock.Mocker() as m:
        m.get(f"{_BASE}CatalogItems(Orders)/Model.GetRenderStream", json={})
        m.get(f"{_BASE}DataSources(Good)/Model.GetConnectionString", json={})
        m.get(
            f"{_BASE}DataSources(Bad)/Model.GetConnectionString",
            status_code=400,
            json={},
        )
        m.get(f"{_BASE}Subscriptions", json={"value": [{"Id": "s1"}]})

        result = validate(
            client,
            reports=["Orders"],
            data_sources=["Good", "Bad"],
        )

        assert result["ok"] is False
