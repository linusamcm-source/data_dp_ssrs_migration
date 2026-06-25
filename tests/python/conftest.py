"""Shared pytest fixtures for the rs_migration test suite.

The Azure Key Vault boundary is mocked here so tests never touch the network
or require real credentials. ``mock_secret_client`` patches the
``SecretClient`` symbol imported into ``rs_migration.keyvault`` and yields the
mock client instance that the patched constructor returns.
"""

from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def mock_secret_client():
    """Patch ``rs_migration.keyvault.SecretClient`` and yield the client mock.

    The patched class is a constructor mock; its return value is the client
    instance used by the keyvault helpers. Tests configure the client's
    ``get_secret`` / ``set_secret`` return values and assert on its calls.
    """
    with patch("rs_migration.keyvault.SecretClient") as client_cls:
        client = MagicMock()
        client_cls.return_value = client
        yield client
