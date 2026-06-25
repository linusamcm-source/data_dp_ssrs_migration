"""Re-key catalog-item data sources over PBIRS REST v2.0 (impl-doc §8 / §8.1).

The Python counterpart to PowerShell Story 8 (``Set-RsMigrationDataSource``);
used in the lost-key path after ``rskeymgmt.exe -d`` and in post-migration
credential fixes. It re-binds a catalog item's stored credentials by writing
the data-source array back to ``.../DataSources``.

Method is type-dependent (impl-doc §8):

- ``Report`` / ``DataSet`` -> ``PUT``
- ``PowerBIReport``        -> ``PATCH``

The body is always a JSON **array** and always includes ``CredentialRetrieval``
even though the published schema understates it (impl-doc §8.1). The same
preconditions the underlying ``Set-RsRestItemDataSource`` cmdlet enforces are
encoded here:

- ``CredentialRetrieval`` of ``Store`` (compared case-insensitively, matching
  both ``Store`` and ``store``) requires ``CredentialsInServer``.
- A ``PowerBIReport`` requires BOTH ``CredentialsInServer``
  (UserName/Password/UseAsWindowsCredentials) AND a ``DataModelDataSource``
  (Username/Secret), else scheduled refresh fails.
"""

from __future__ import annotations

from typing import Any

from .rest_client import RestClient

#: Item types re-keyed with a PUT (paginated/shared report data sources).
_PUT_TYPES = frozenset({"Report", "DataSet"})
#: Item type re-keyed with a PATCH (Power BI model data source).
_PATCH_TYPE = "PowerBIReport"
#: Credential-retrieval mode (canonical casing) that requires stored creds.
_STORE = "Store"


def rekey(
    client: RestClient,
    item_path: str,
    item_type: str,
    *,
    credential_retrieval: str,
    credentials_in_server: dict[str, Any] | None = None,
    data_model_data_source: dict[str, Any] | None = None,
) -> Any:
    """Re-bind a catalog item's data-source credentials over REST.

    Args:
        client: A Story-11 :class:`~rs_migration.rest_client.RestClient`.
        item_path: Catalog path of the item (e.g. ``/Sales/Orders``).
        item_type: ``Report``/``DataSet`` (PUT) or ``PowerBIReport`` (PATCH).
        credential_retrieval: ``Integrated``/``Store``/``Prompt``/``None``;
            ``Store`` (case-insensitive) requires ``credentials_in_server``.
        credentials_in_server: Stored-credential block
            (UserName/Password/UseAsWindowsCredentials).
        data_model_data_source: Power BI model credential block
            (Username/Secret); required for ``PowerBIReport``.

    Returns:
        The decoded JSON body of the write response (or ``None``).

    Raises:
        ValueError: For an unknown ``item_type``, a ``Store`` retrieval without
            credentials, or a ``PowerBIReport`` missing either credential block.
    """
    is_patch = item_type == _PATCH_TYPE
    if not is_patch and item_type not in _PUT_TYPES:
        raise ValueError(
            f"Unsupported item_type {item_type!r}: expected one of "
            f"{sorted(_PUT_TYPES) + [_PATCH_TYPE]}"
        )

    if credential_retrieval.casefold() == _STORE.casefold() and not credentials_in_server:
        raise ValueError(
            f"CredentialRetrieval={credential_retrieval!r} (Store) requires "
            "CredentialsInServer credentials."
        )

    if is_patch:
        if not credentials_in_server:
            raise ValueError(
                "A PowerBIReport requires CredentialsInServer "
                "(UserName/Password/UseAsWindowsCredentials)."
            )
        if not data_model_data_source:
            raise ValueError(
                "A PowerBIReport requires a DataModelDataSource (Username/Secret)."
            )

    data_source: dict[str, Any] = {"CredentialRetrieval": credential_retrieval}
    if credentials_in_server is not None:
        data_source["CredentialsInServer"] = credentials_in_server
    if data_model_data_source is not None:
        data_source["DataModelDataSource"] = data_model_data_source

    endpoint = f"CatalogItems(Path='{item_path}')/DataSources"
    body = [data_source]
    if is_patch:
        return client.patch(endpoint, json=body)
    return client.put(endpoint, json=body)
