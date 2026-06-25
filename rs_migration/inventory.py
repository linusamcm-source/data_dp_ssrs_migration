"""Catalog inventory over REST (impl-doc §8.1 / A1).

The Python counterpart to the PowerShell ``Export-RsMigrationInventory``
(Story 7). It walks the PBIRS catalog over the REST v2.0 API:

- ``GET /CatalogItems`` enumerates every catalog item;
- ``GET /CatalogItems(<id>)/DataSources`` reads each item's data sources.

For every data source whose ``CredentialRetrieval`` is ``Store`` (the only
mode whose secret is symmetric-key-protected — impl-doc §9) and which carries
a server-side password, the stored password is pushed to Key Vault under a
deterministic name derived from the item path and data-source name. A record
is returned for *every* data source — stored or not — so the caller has a full
inventory of catalog credential modes.
"""

from __future__ import annotations

import re

from rs_migration import keyvault
from rs_migration.rest_client import RestClient

#: Catalog enumeration endpoint (relative to the client base URL).
_CATALOG_ENDPOINT = "CatalogItems"
#: Canonical stored-credential mode; compared case-insensitively (impl-doc §8.1
#: uses lowercase ``store``, §8 uses capitalised ``Store``).
_STORE_MODE = "store"


def _datasources_endpoint(item_id: str) -> str:
    """Per-item data-sources endpoint: ``CatalogItems(<id>)/DataSources``."""
    return f"{_CATALOG_ENDPOINT}({item_id})/DataSources"


def _secret_name(item_path: str, data_source: str) -> str:
    """Derive a Key Vault secret name from the item path + data-source name.

    Key Vault secret names allow only alphanumerics and dashes, so every other
    character (slashes, spaces, backslashes) collapses to a dash and runs of
    dashes are squeezed.
    """
    raw = f"{item_path}-{data_source}"
    name = re.sub(r"[^A-Za-z0-9]+", "-", raw)
    return name.strip("-")


def _stored_password(data_source: dict) -> str | None:
    """Return the stored server-side password, or ``None`` if absent."""
    creds = data_source.get("CredentialsInServer") or {}
    return creds.get("Password")


def inventory(client: RestClient, vault: str) -> list[dict]:
    """Inventory every catalog data source, pushing stored secrets to Key Vault.

    Args:
        client: A Story-11 :class:`RestClient` bound to the target PBIRS server.
        vault: The Azure Key Vault name to push stored credentials into.

    Returns:
        One record per data source, each a dict with ``item_path``,
        ``data_source``, and ``credential_retrieval`` keys.
    """
    catalog = client.get(_CATALOG_ENDPOINT)
    items = catalog.get("value", []) if catalog else []

    records: list[dict] = []
    for item in items:
        item_id = item["Id"]
        item_path = item.get("Path", "")
        ds_response = client.get(_datasources_endpoint(item_id))
        data_sources = ds_response.get("value", []) if ds_response else []

        for data_source in data_sources:
            name = data_source.get("Name", "")
            mode = data_source.get("CredentialRetrieval", "")
            records.append(
                {
                    "item_path": item_path,
                    "data_source": name,
                    "credential_retrieval": mode,
                }
            )

            if mode.casefold() == _STORE_MODE:
                password = _stored_password(data_source)
                if password is not None:
                    keyvault.set_secret(
                        vault, _secret_name(item_path, name), password
                    )

    return records
