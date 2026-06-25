"""Tests for rs_migration.rekey (Story 13 ACs).

The PBIRS REST v2.0 boundary is mocked with ``requests-mock`` (driving a real
Story-11 ``RestClient``) so tests never touch the network. Each test maps to a
Story 13 acceptance criterion:

- AC1: a ``Report`` item drives a ``PUT`` and a ``PowerBIReport`` item drives a
  ``PATCH`` (method + URL asserted).
- AC2: the request body is a JSON **array** that always includes
  ``CredentialRetrieval`` (even though the published schema understates it).
- AC3: a Power BI report requires BOTH ``CredentialsInServer`` and a
  ``DataModelDataSource`` — missing either raises.
- AC4: ``CredentialRetrieval='Store'`` (case-insensitive — both ``Store`` and
  ``store``) without credentials raises.
"""

import json

import pytest
import requests_mock

from rs_migration.rekey import rekey
from rs_migration.rest_client import RestClient

# --- shared fixtures / helpers ----------------------------------------------

_BASE = "https://pbirs.contoso.com/Reports/api/v2.0"


def _client() -> RestClient:
    return RestClient("pbirs.contoso.com")


def _mock_handshake(m: requests_mock.Mocker) -> None:
    """Register the XSRF probe so writes can complete."""
    m.get(f"{_BASE}/me", cookies={"XSRF-TOKEN": "tok"}, json={})


def _credentials_in_server() -> dict:
    return {
        "UserName": "dom\\svc",
        "Password": "pw",
        "UseAsWindowsCredentials": True,
    }


def _data_model_data_source() -> dict:
    return {"Username": "dom\\svc", "Secret": "pw"}


# --- AC1: Report -> PUT, PowerBIReport -> PATCH (method + URL) ---------------


def test_report_item_drives_put():
    """A Report item re-keys via PUT to the item's DataSources endpoint."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        rekey(
            client,
            "/Sales/Orders",
            "Report",
            credential_retrieval="Store",
            credentials_in_server=_credentials_in_server(),
        )

        write = next(r for r in m.request_history if r.method != "GET")
        assert write.method == "PUT"
        assert write.url == f"{_BASE}/CatalogItems(Path='/Sales/Orders')/DataSources"


def test_powerbi_report_item_drives_patch():
    """A PowerBIReport item re-keys via PATCH to the DataSources endpoint."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.patch(requests_mock.ANY, status_code=200, json={})

        rekey(
            client,
            "/Sales/Exec",
            "PowerBIReport",
            credential_retrieval="Store",
            credentials_in_server=_credentials_in_server(),
            data_model_data_source=_data_model_data_source(),
        )

        write = next(r for r in m.request_history if r.method != "GET")
        assert write.method == "PATCH"
        assert write.url == f"{_BASE}/CatalogItems(Path='/Sales/Exec')/DataSources"


# --- AC2: body is a JSON array that always includes CredentialRetrieval ------


def test_report_body_is_json_array_including_credential_retrieval():
    """The PUT body is a JSON array whose element carries CredentialRetrieval."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        rekey(
            client,
            "/Sales/Orders",
            "Report",
            credential_retrieval="Store",
            credentials_in_server=_credentials_in_server(),
        )

        write = next(r for r in m.request_history if r.method == "PUT")
        body = json.loads(write.body)
        assert isinstance(body, list)
        assert len(body) == 1
        assert body[0]["CredentialRetrieval"] == "Store"
        assert body[0]["CredentialsInServer"] == _credentials_in_server()


def test_powerbi_body_is_json_array_including_credential_retrieval():
    """The PATCH body is a JSON array with CredentialRetrieval + both blocks."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.patch(requests_mock.ANY, status_code=200, json={})

        rekey(
            client,
            "/Sales/Exec",
            "PowerBIReport",
            credential_retrieval="Store",
            credentials_in_server=_credentials_in_server(),
            data_model_data_source=_data_model_data_source(),
        )

        write = next(r for r in m.request_history if r.method == "PATCH")
        body = json.loads(write.body)
        assert isinstance(body, list)
        assert body[0]["CredentialRetrieval"] == "Store"
        assert body[0]["CredentialsInServer"] == _credentials_in_server()
        assert body[0]["DataModelDataSource"] == _data_model_data_source()


def test_credential_retrieval_present_even_for_non_store_mode():
    """CredentialRetrieval is always in the body, even for non-Store modes."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        rekey(client, "/Sales/Orders", "Report", credential_retrieval="Integrated")

        write = next(r for r in m.request_history if r.method == "PUT")
        body = json.loads(write.body)
        assert body[0]["CredentialRetrieval"] == "Integrated"


# --- AC3: PowerBIReport requires BOTH CredentialsInServer and a model source --


def test_powerbi_missing_credentials_in_server_raises():
    """A PowerBIReport without CredentialsInServer raises (no write issued).

    Uses a non-Store retrieval mode so it is the PowerBIReport-specific
    CredentialsInServer requirement that raises, not the Store guard.
    """
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.patch(requests_mock.ANY, status_code=200, json={})

        with pytest.raises(ValueError, match="CredentialsInServer"):
            rekey(
                client,
                "/Sales/Exec",
                "PowerBIReport",
                credential_retrieval="Integrated",
                data_model_data_source=_data_model_data_source(),
            )

        assert not any(r.method == "PATCH" for r in m.request_history)


def test_powerbi_missing_data_model_data_source_raises():
    """A PowerBIReport without a DataModelDataSource raises (no write issued)."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.patch(requests_mock.ANY, status_code=200, json={})

        with pytest.raises(ValueError, match="DataModelDataSource"):
            rekey(
                client,
                "/Sales/Exec",
                "PowerBIReport",
                credential_retrieval="Store",
                credentials_in_server=_credentials_in_server(),
            )

        assert not any(r.method == "PATCH" for r in m.request_history)


# --- AC4: Store (case-insensitive) without credentials raises ----------------


@pytest.mark.parametrize("mode", ["Store", "store"])
def test_store_without_credentials_raises(mode):
    """Store/store with no CredentialsInServer raises (no write issued)."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        with pytest.raises(ValueError, match="(?i)store"):
            rekey(client, "/Sales/Orders", "Report", credential_retrieval=mode)

        assert not any(r.method == "PUT" for r in m.request_history)


@pytest.mark.parametrize("mode", ["Store", "store"])
def test_store_with_credentials_succeeds_case_insensitive(mode):
    """Lowercase and capitalised Store both pass when credentials are given."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        rekey(
            client,
            "/Sales/Orders",
            "Report",
            credential_retrieval=mode,
            credentials_in_server=_credentials_in_server(),
        )

        write = next(r for r in m.request_history if r.method == "PUT")
        body = json.loads(write.body)
        assert body[0]["CredentialRetrieval"] == mode


# --- OData path injection: single quotes/spaces are escaped+encoded ----------


def test_item_path_with_quote_and_space_is_escaped_and_encoded():
    """A path containing a single quote and a space must not break out of the
    OData string literal: the quote is doubled (OData escaping) then percent-
    encoded, the space is percent-encoded, and the request still issues to the
    DataSources endpoint."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        # A malicious / awkward path: a quote that would otherwise close the
        # literal, plus a space.
        rekey(
            client,
            "/Sales/O'Brien Reports",
            "Report",
            credential_retrieval="Integrated",
        )

        write = next(r for r in m.request_history if r.method == "PUT")
        # The raw quote must never appear unescaped inside the literal, and the
        # space must be encoded — together that means no literal breakout.
        assert "/Sales/O'Brien Reports" not in write.url
        assert " " not in write.url
        # OData doubles internal quotes; percent-encoded that is %27%27.
        assert "%27%27" in write.url
        # The endpoint is still the item's DataSources collection.
        assert write.url.endswith("/DataSources")
        assert write.url.startswith(f"{_BASE}/CatalogItems(Path=")


# --- supporting: DataSet routes via PUT, unknown item type rejected ----------


def test_dataset_item_drives_put():
    """A DataSet item (like Report) re-keys via PUT."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        m.put(requests_mock.ANY, status_code=200, json={})

        rekey(client, "/Sales/Shared", "DataSet", credential_retrieval="None")

        write = next(r for r in m.request_history if r.method != "GET")
        assert write.method == "PUT"


def test_unknown_item_type_raises():
    """An unsupported item type is rejected before any request."""
    client = _client()
    with requests_mock.Mocker() as m:
        _mock_handshake(m)
        with pytest.raises(ValueError, match="item_type"):
            rekey(client, "/Sales/Orders", "Folder", credential_retrieval="None")
        assert m.call_count == 0
