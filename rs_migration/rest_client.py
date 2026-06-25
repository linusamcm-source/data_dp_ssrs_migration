"""PBIRS REST v2.0 client with XSRF handshake + NTLM auth (impl-doc §8.1).

Mirrors ``ReportingServicesTools``' ``New-RsRestSession``:

- The base URL is composed as ``http(s)://<server>/Reports/api/v2.0/`` and every
  relative endpoint is resolved by appending the bare segment to that base, so
  ``/Reports`` is never dropped (a naive ``urljoin`` against a path-less host
  would strip it — we use a careful string join instead).
- REST sessions require an XSRF token: on the first write the client does
  ``GET .../api/v2.0/me``, reads the ``XSRF-TOKEN`` cookie, and sends it as the
  ``X-XSRF-TOKEN`` header on every subsequent ``PUT``/``PATCH``/``POST``. Plain
  ``GET`` requests never carry the header.
- NTLM credentials are wired via ``requests_ntlm.HttpNtlmAuth`` when supplied.
- Any non-2xx response raises the typed :class:`RestClientError`.
"""

from __future__ import annotations

import re
from typing import Any

import requests
from requests_ntlm import HttpNtlmAuth

#: Cookie set by the server during the XSRF probe.
_XSRF_COOKIE = "XSRF-TOKEN"
#: Header echoing the token back on write requests.
_XSRF_HEADER = "X-XSRF-TOKEN"
#: Relative endpoint probed to obtain the XSRF token.
_XSRF_PROBE = "me"
#: Marker substituted for a credential-bearing body in the exception message.
_REDACTION = "[redacted: response body may contain credentials]"
#: Max characters of a non-credential body included in the exception message.
_BODY_PREVIEW = 200
#: Credential-like tokens; on a failed write the server may echo the request
#: payload back, which can carry a Password/Secret. Matched case-insensitively.
_CREDENTIAL_PATTERN = re.compile(r"password|secret", re.IGNORECASE)


def _safe_body_for_message(body: str) -> str:
    """Render ``body`` safe to embed in a (loggable) exception message.

    If the body looks like it carries a credential (case-insensitive
    ``password``/``secret``), it is replaced wholesale with a redaction marker
    so logging the exception never leaks the secret. Otherwise a short
    truncated preview is returned. The full body is always retained on
    :attr:`RestClientError.body` for explicit debugging.
    """
    if not body:
        return ""
    if _CREDENTIAL_PATTERN.search(body):
        return _REDACTION
    if len(body) > _BODY_PREVIEW:
        return body[:_BODY_PREVIEW] + "..."
    return body


class RestClientError(Exception):
    """Raised when the PBIRS REST API returns a non-2xx response."""

    def __init__(self, status_code: int, url: str, body: str = "") -> None:
        self.status_code = status_code
        self.url = url
        self.body = body
        safe_body = _safe_body_for_message(body)
        super().__init__(f"PBIRS REST {status_code} for {url}: {safe_body}")


class RestClient:
    """Thin REST v2.0 client for a single PBIRS server.

    Args:
        server: Hostname of the report server (no scheme, no path).
        username: NTLM username (e.g. ``domain\\user``); enables NTLM when set.
        password: NTLM password; required alongside ``username``.
        scheme: ``"https"`` (default) or ``"http"``.
    """

    def __init__(
        self,
        server: str,
        username: str | None = None,
        password: str | None = None,
        scheme: str = "https",
    ) -> None:
        self.base_url = f"{scheme}://{server}/Reports/api/v2.0/"
        self.session = requests.Session()
        if username and password:
            self.session.auth = HttpNtlmAuth(username, password)
        self._xsrf_token: str | None = None

    # -- URL resolution -----------------------------------------------------

    def _resolve(self, endpoint: str) -> str:
        """Resolve a bare endpoint segment against the base URL.

        Uses a plain string join (not ``urljoin``) so the ``/Reports`` path
        prefix is preserved: ``"me"`` -> ``.../Reports/api/v2.0/me``.
        """
        return self.base_url + endpoint.lstrip("/")

    # -- XSRF handshake -----------------------------------------------------

    def _ensure_xsrf_token(self) -> str:
        """Return the XSRF token, performing the handshake on first use."""
        if self._xsrf_token is None:
            resp = self.session.get(self._resolve(_XSRF_PROBE))
            self._raise_for_status(resp)
            token = resp.cookies.get(_XSRF_COOKIE)
            if token is None:
                token = self.session.cookies.get(_XSRF_COOKIE)
            if token is None:
                raise RestClientError(
                    resp.status_code,
                    resp.url,
                    f"XSRF handshake returned no {_XSRF_COOKIE} cookie",
                )
            self._xsrf_token = token
        return self._xsrf_token

    # -- request plumbing ---------------------------------------------------

    @staticmethod
    def _raise_for_status(resp: requests.Response) -> None:
        """Raise :class:`RestClientError` for any non-2xx response."""
        if not (200 <= resp.status_code < 300):
            raise RestClientError(resp.status_code, resp.url, resp.text)

    def _write(self, method: str, endpoint: str, json: Any | None) -> Any:
        """Issue a write (PUT/PATCH/POST) carrying the XSRF header."""
        token = self._ensure_xsrf_token()
        resp = self.session.request(
            method,
            self._resolve(endpoint),
            json=json,
            headers={_XSRF_HEADER: token},
        )
        self._raise_for_status(resp)
        return self._json_or_none(resp)

    @staticmethod
    def _json_or_none(resp: requests.Response) -> Any:
        """Return the decoded JSON body, or ``None`` when there is none."""
        if not resp.content:
            return None
        try:
            return resp.json()
        except ValueError:
            return None

    # -- public verbs -------------------------------------------------------

    def get(self, endpoint: str) -> Any:
        """GET ``endpoint`` (no XSRF header) and return the JSON body."""
        resp = self.session.get(self._resolve(endpoint))
        self._raise_for_status(resp)
        return self._json_or_none(resp)

    def put(self, endpoint: str, json: Any | None = None) -> Any:
        """PUT ``endpoint`` with the XSRF header; returns the JSON body."""
        return self._write("PUT", endpoint, json)

    def patch(self, endpoint: str, json: Any | None = None) -> Any:
        """PATCH ``endpoint`` with the XSRF header; returns the JSON body."""
        return self._write("PATCH", endpoint, json)

    def post(self, endpoint: str, json: Any | None = None) -> Any:
        """POST ``endpoint`` with the XSRF header; returns the JSON body."""
        return self._write("POST", endpoint, json)
