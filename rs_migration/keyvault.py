"""Azure Key Vault client helpers (impl-doc §8.1).

Thin wrappers over ``azure-keyvault-secrets`` + ``azure-identity`` used by the
migration orchestrator to read and write stored credentials and the encryption
``.snk`` bytes. Authentication uses ``DefaultAzureCredential`` so the same code
works under managed identity, environment, or developer credentials.
"""

import base64

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient


def _client(vault: str) -> SecretClient:
    """Build a ``SecretClient`` for ``vault`` using the default credential."""
    return SecretClient(
        vault_url=f"https://{vault}.vault.azure.net",
        credential=DefaultAzureCredential(),
    )


def get_secret(vault: str, name: str) -> str:
    """Return the plaintext value of secret ``name`` in ``vault``."""
    return _client(vault).get_secret(name).value


def get_secret_bytes(vault: str, name: str) -> bytes:
    """Return the base64-decoded bytes of secret ``name`` in ``vault``.

    Used for binary secrets such as the encryption ``.snk`` stored as base64.
    """
    return base64.b64decode(get_secret(vault, name))


def set_secret(vault: str, name: str, value: str) -> None:
    """Set secret ``name`` to ``value`` in ``vault``."""
    _client(vault).set_secret(name, value)
