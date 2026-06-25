"""Tests for rs_migration.inventory (Story 12 ACs).

The PBIRS REST v2.0 boundary is mocked with ``requests-mock`` against the
Story-11 :class:`RestClient`; the Key Vault boundary is patched at
``rs_migration.inventory.keyvault.set_secret``. Each test maps to a Story 12
acceptance criterion:

- AC1: ``inventory()`` issues ``GET /CatalogItems`` then ``GET .../DataSources``
  per item, in that order (call sequence pinned via ``requests-mock``).
- AC2: for each stored-credential data source it calls ``keyvault.set_secret``
  exactly once (mock asserted).
- AC3: it returns a list of records with item path, data-source name, and
  credential-retrieval mode.
"""

from unittest.mock import patch

import pytest
import requests_mock

from rs_migration.inventory import _secret_name, inventory
from rs_migration.rest_client import RestClient

_BASE = "https://pbirs.contoso.com/Reports/api/v2.0/"


def _client():
    return RestClient("pbirs.contoso.com")


# A two-item catalog: a paginated report and a Power BI report. Only the
# Sales/Orders data source uses Store; the other two do not.
_CATALOG = {
    "value": [
        {"Id": "id-orders", "Path": "/Sales/Orders", "Type": "Report"},
        {"Id": "id-exec", "Path": "/Sales/Exec", "Type": "PowerBIReport"},
    ]
}
_DS_ORDERS = {
    "value": [
        {
            "Name": "OrdersDB",
            "CredentialRetrieval": "Store",
            "ConnectionString": "Data Source=sql1;Initial Catalog=Sales",
            "CredentialsInServer": {"UserName": "dom\\svc", "Password": "p@ss"},
        }
    ]
}
_DS_EXEC = {
    "value": [
        {
            "Name": "ExecModel",
            "CredentialRetrieval": "Integrated",
            "ConnectionString": "Data Source=ssas1",
        }
    ]
}


def _register_happy_path(m):
    """Register the catalog + per-item DataSources endpoints on ``m``."""
    m.get(_BASE + "CatalogItems", json=_CATALOG)
    m.get(_BASE + "CatalogItems(id-orders)/DataSources", json=_DS_ORDERS)
    m.get(_BASE + "CatalogItems(id-exec)/DataSources", json=_DS_EXEC)


# --- AC1: GET /CatalogItems, then GET .../DataSources per item, in order -----


def test_issues_catalog_then_datasources_per_item_in_order():
    """The call sequence is CatalogItems, then one DataSources GET per item."""
    with requests_mock.Mocker() as m:
        _register_happy_path(m)
        with patch("rs_migration.inventory.keyvault.set_secret"):
            inventory(_client(), "kv-prod")

        urls = [r.url for r in m.request_history]
        assert urls == [
            _BASE + "CatalogItems",
            _BASE + "CatalogItems(id-orders)/DataSources",
            _BASE + "CatalogItems(id-exec)/DataSources",
        ]
        assert all(r.method == "GET" for r in m.request_history)


def test_datasources_endpoint_is_per_item_keyed_by_id():
    """Each DataSources GET targets the specific item's id, not a bare path."""
    with requests_mock.Mocker() as m:
        _register_happy_path(m)
        with patch("rs_migration.inventory.keyvault.set_secret"):
            inventory(_client(), "kv-prod")

        ds_calls = [
            r.url for r in m.request_history if r.url.endswith("/DataSources")
        ]
        assert ds_calls == [
            _BASE + "CatalogItems(id-orders)/DataSources",
            _BASE + "CatalogItems(id-exec)/DataSources",
        ]


def test_catalog_without_items_issues_only_the_catalog_get():
    """An empty catalog means a single GET /CatalogItems and no DS calls."""
    with requests_mock.Mocker() as m:
        m.get(_BASE + "CatalogItems", json={"value": []})
        with patch("rs_migration.inventory.keyvault.set_secret") as set_secret:
            records = inventory(_client(), "kv-prod")

        assert [r.url for r in m.request_history] == [_BASE + "CatalogItems"]
        assert records == []
        set_secret.assert_not_called()


# --- AC2: keyvault.set_secret called once per stored-credential data source --


def test_set_secret_called_once_for_each_stored_credential_datasource():
    """Exactly one set_secret per Store data source; none for the others."""
    with requests_mock.Mocker() as m:
        _register_happy_path(m)
        with patch("rs_migration.inventory.keyvault.set_secret") as set_secret:
            inventory(_client(), "kv-prod")

        # Only OrdersDB uses Store -> exactly one push to Key Vault.
        assert set_secret.call_count == 1
        vault_arg, _name, _value = set_secret.call_args.args
        assert vault_arg == "kv-prod"


def test_set_secret_pushes_stored_password_under_path_derived_name():
    """The secret name is derived from item path + data-source name; the
    pushed value is the stored password."""
    with requests_mock.Mocker() as m:
        _register_happy_path(m)
        with patch("rs_migration.inventory.keyvault.set_secret") as set_secret:
            inventory(_client(), "kv-prod")

        vault, name, value = set_secret.call_args.args
        assert vault == "kv-prod"
        # Name must trace to both the item path and the data-source name.
        assert "Sales" in name and "Orders" in name and "OrdersDB" in name
        # Key Vault secret names allow only alphanumerics and dashes.
        assert all(c.isalnum() or c == "-" for c in name)
        assert value == "p@ss"


def test_non_stored_datasource_produces_no_set_secret_call():
    """A data source not using Store yields no Key Vault write."""
    catalog = {"value": [{"Id": "id-x", "Path": "/A/B", "Type": "Report"}]}
    ds = {
        "value": [
            {"Name": "PromptDS", "CredentialRetrieval": "Prompt"},
            {"Name": "IntegratedDS", "CredentialRetrieval": "Integrated"},
        ]
    }
    with requests_mock.Mocker() as m:
        m.get(_BASE + "CatalogItems", json=catalog)
        m.get(_BASE + "CatalogItems(id-x)/DataSources", json=ds)
        with patch("rs_migration.inventory.keyvault.set_secret") as set_secret:
            records = inventory(_client(), "kv-prod")

        set_secret.assert_not_called()
        # Both non-Store data sources are still inventoried.
        assert {r["data_source"] for r in records} == {"PromptDS", "IntegratedDS"}


def test_stored_datasource_without_credentials_skips_set_secret():
    """A Store data source carrying no server credentials is recorded but
    triggers no Key Vault write (nothing to push)."""
    catalog = {"value": [{"Id": "id-y", "Path": "/A/C", "Type": "Report"}]}
    ds = {
        "value": [
            {"Name": "EmptyStore", "CredentialRetrieval": "Store"},
        ]
    }
    with requests_mock.Mocker() as m:
        m.get(_BASE + "CatalogItems", json=catalog)
        m.get(_BASE + "CatalogItems(id-y)/DataSources", json=ds)
        with patch("rs_migration.inventory.keyvault.set_secret") as set_secret:
            records = inventory(_client(), "kv-prod")

        set_secret.assert_not_called()
        assert records[0]["credential_retrieval"] == "Store"


def test_store_match_is_case_insensitive():
    """A lowercase 'store' mode (impl-doc §8.1) still triggers a push."""
    catalog = {"value": [{"Id": "id-z", "Path": "/A/D", "Type": "Report"}]}
    ds = {
        "value": [
            {
                "Name": "LowerStore",
                "CredentialRetrieval": "store",
                "CredentialsInServer": {"UserName": "u", "Password": "pw"},
            }
        ]
    }
    with requests_mock.Mocker() as m:
        m.get(_BASE + "CatalogItems", json=catalog)
        m.get(_BASE + "CatalogItems(id-z)/DataSources", json=ds)
        with patch("rs_migration.inventory.keyvault.set_secret") as set_secret:
            inventory(_client(), "kv-prod")

        assert set_secret.call_count == 1


# --- secret-name collision resistance (credential-integrity fix) -------------


def test_secret_name_distinguishes_inputs_that_collide_after_sanitising():
    """Two distinct (path, data source) pairs that sanitise to the same stem
    must NOT produce the same secret name — otherwise set_secret silently
    overwrites the earlier credential."""
    # Both '/Sales/Orders' + 'DS' and '/Sales-Orders' + 'DS' collapse to the
    # same sanitised stem 'Sales-Orders-DS' under the old scheme.
    a = _secret_name("/Sales/Orders", "DS")
    b = _secret_name("/Sales-Orders", "DS")
    assert a != b


def test_secret_name_is_deterministic_across_calls():
    """The same input always yields the same secret name (stable across runs)."""
    first = _secret_name("/Sales/Orders", "OrdersDB")
    second = _secret_name("/Sales/Orders", "OrdersDB")
    assert first == second


def test_secret_name_is_key_vault_legal_and_bounded():
    """The name is alphanumerics + dashes only and within Key Vault's 127-char
    limit, even for a very long path."""
    name = _secret_name("/A" * 200, "B" * 200)
    assert all(c.isalnum() or c == "-" for c in name)
    assert 0 < len(name) <= 127


# --- AC3: returns records with item path, data-source name, credential mode --


def test_returns_one_record_per_datasource_with_expected_shape():
    """Records carry item path, data-source name, and credential mode."""
    with requests_mock.Mocker() as m:
        _register_happy_path(m)
        with patch("rs_migration.inventory.keyvault.set_secret"):
            records = inventory(_client(), "kv-prod")

    assert isinstance(records, list)
    assert len(records) == 2  # one per data source across both items

    by_name = {r["data_source"]: r for r in records}

    orders = by_name["OrdersDB"]
    assert orders["item_path"] == "/Sales/Orders"
    assert orders["credential_retrieval"] == "Store"

    exec_ds = by_name["ExecModel"]
    assert exec_ds["item_path"] == "/Sales/Exec"
    assert exec_ds["credential_retrieval"] == "Integrated"


def test_record_keys_are_exactly_the_three_required_fields():
    """Each record exposes at minimum the three AC3 fields."""
    with requests_mock.Mocker() as m:
        _register_happy_path(m)
        with patch("rs_migration.inventory.keyvault.set_secret"):
            records = inventory(_client(), "kv-prod")

    required = {"item_path", "data_source", "credential_retrieval"}
    for record in records:
        assert required <= set(record.keys())


def test_item_with_no_datasources_contributes_no_records():
    """An item whose DataSources endpoint returns an empty list adds nothing."""
    catalog = {
        "value": [
            {"Id": "id-1", "Path": "/Empty/Item", "Type": "Report"},
            {"Id": "id-2", "Path": "/Sales/Orders", "Type": "Report"},
        ]
    }
    with requests_mock.Mocker() as m:
        m.get(_BASE + "CatalogItems", json=catalog)
        m.get(_BASE + "CatalogItems(id-1)/DataSources", json={"value": []})
        m.get(_BASE + "CatalogItems(id-2)/DataSources", json=_DS_ORDERS)
        with patch("rs_migration.inventory.keyvault.set_secret"):
            records = inventory(_client(), "kv-prod")

    assert [r["item_path"] for r in records] == ["/Sales/Orders"]


def test_rest_error_propagates():
    """A REST failure surfaces as the typed RestClientError (not swallowed)."""
    from rs_migration.rest_client import RestClientError

    with requests_mock.Mocker() as m:
        m.get(_BASE + "CatalogItems", status_code=500, json={})
        with patch("rs_migration.inventory.keyvault.set_secret"):
            with pytest.raises(RestClientError):
                inventory(_client(), "kv-prod")
