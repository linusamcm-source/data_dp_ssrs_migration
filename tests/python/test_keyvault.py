"""Tests for rs_migration.keyvault (Story 10 ACs)."""

import base64
from unittest.mock import MagicMock

from rs_migration import keyvault


def _secret(value):
    """Build a fake SecretClient.get_secret() return object."""
    secret = MagicMock()
    secret.value = value
    return secret


def test_get_secret_returns_value(mock_secret_client):
    """get_secret returns the secret value from a mocked SecretClient."""
    mock_secret_client.get_secret.return_value = _secret("hunter2")

    result = keyvault.get_secret("myvault", "db-password")

    assert result == "hunter2"
    mock_secret_client.get_secret.assert_called_once_with("db-password")


def test_get_secret_builds_vault_url(mock_secret_client):
    """The client is constructed against the vault's full URL."""
    import rs_migration.keyvault as kv

    mock_secret_client.get_secret.return_value = _secret("x")

    with_patch = MagicMock(return_value=mock_secret_client)
    original = kv.SecretClient
    kv.SecretClient = with_patch
    try:
        kv.get_secret("myvault", "name")
    finally:
        kv.SecretClient = original

    _, kwargs = with_patch.call_args
    assert kwargs["vault_url"] == "https://myvault.vault.azure.net"


def test_get_secret_bytes_decodes_base64(mock_secret_client):
    """get_secret_bytes base64-decodes the stored secret value to bytes."""
    raw = b"\x00\x01binary-key-bytes\xff"
    encoded = base64.b64encode(raw).decode("ascii")
    mock_secret_client.get_secret.return_value = _secret(encoded)

    result = keyvault.get_secret_bytes("myvault", "snk")

    assert result == raw
    assert isinstance(result, bytes)
    mock_secret_client.get_secret.assert_called_once_with("snk")


def test_set_secret_calls_client(mock_secret_client):
    """set_secret forwards (name, value) to the client's set_secret."""
    keyvault.set_secret("myvault", "api-key", "s3cr3t")

    mock_secret_client.set_secret.assert_called_once_with("api-key", "s3cr3t")
