"""Tests for rs_migration.rest_client (Story 11 ACs).

The PBIRS REST v2.0 boundary is mocked with ``requests-mock`` so tests never
touch the network. Each test maps to a Story 11 acceptance criterion:

- AC1: base URL composition + exact resolved URLs (``/Reports`` retained).
- AC2: XSRF handshake (GET /me, read cookie, X-XSRF-TOKEN on writes).
- AC3: a plain GET carries no X-XSRF-TOKEN header.
- AC4: NTLM auth wired via requests_ntlm.HttpNtlmAuth when creds supplied.
- AC5: a non-2xx response raises the typed RestClientError.
"""

import pytest
import requests_mock
from requests_ntlm import HttpNtlmAuth

from rs_migration.rest_client import RestClient, RestClientError

# --- AC1: base URL + exact resolved endpoint URLs (no /Reports dropped) ------


def test_base_url_composition_https():
    """base_url is http(s)://<server>/Reports/api/v2.0/ (default https)."""
    client = RestClient("pbirs.contoso.com")
    assert client.base_url == "https://pbirs.contoso.com/Reports/api/v2.0/"


def test_base_url_composition_http_scheme():
    """The scheme is configurable (http for non-TLS labs)."""
    client = RestClient("pbirs.contoso.com", scheme="http")
    assert client.base_url == "http://pbirs.contoso.com/Reports/api/v2.0/"


def test_get_resolves_catalog_url_keeping_reports_segment():
    """A catalog GET resolves to .../Reports/api/v2.0/CatalogItems exactly."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            json={"value": []},
        )
        client.get("CatalogItems")

        assert m.call_count == 1
        assert (
            m.request_history[0].url
            == "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems"
        )


def test_xsrf_probe_resolves_to_me_url_keeping_reports_segment():
    """The XSRF probe GET resolves to .../Reports/api/v2.0/me exactly."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok-123"},
            json={},
        )
        m.put(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(1)",
            status_code=200,
            json={},
        )
        # A write triggers the handshake; the probe URL must keep /Reports.
        client.put("CatalogItems(1)", json={"x": 1})

        probe = m.request_history[0]
        assert probe.method == "GET"
        assert probe.url == "https://pbirs.contoso.com/Reports/api/v2.0/me"


# --- AC2: XSRF handshake — token read from cookie, sent on writes -----------


def test_first_write_performs_xsrf_handshake_and_sends_token_header():
    """First write GETs /me, reads XSRF-TOKEN cookie, sends X-XSRF-TOKEN."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok-abc"},
            json={},
        )
        m.put(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(7)",
            status_code=200,
            json={},
        )

        client.put("CatalogItems(7)", json={"CredentialRetrieval": "Store"})

        # request[0] = handshake GET /me, request[1] = the PUT.
        assert m.request_history[0].method == "GET"
        assert m.request_history[0].url.endswith("/api/v2.0/me")
        assert "X-XSRF-TOKEN" not in m.request_history[0].headers

        put_req = m.request_history[1]
        assert put_req.method == "PUT"
        assert put_req.headers["X-XSRF-TOKEN"] == "tok-abc"


def test_token_header_sent_on_patch_and_post_too():
    """X-XSRF-TOKEN is attached to PATCH and POST, not just PUT."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok-xyz"},
            json={},
        )
        m.patch(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(9)",
            status_code=200,
            json={},
        )
        m.post(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            status_code=201,
            json={},
        )

        client.patch("CatalogItems(9)", json={"a": 1})
        client.post("CatalogItems", json={"b": 2})

        patch_req = next(r for r in m.request_history if r.method == "PATCH")
        post_req = next(r for r in m.request_history if r.method == "POST")
        assert patch_req.headers["X-XSRF-TOKEN"] == "tok-xyz"
        assert post_req.headers["X-XSRF-TOKEN"] == "tok-xyz"


def test_handshake_runs_once_across_multiple_writes():
    """The /me probe happens once; the token is cached for later writes."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok-once"},
            json={},
        )
        m.put(requests_mock.ANY, status_code=200, json={})

        client.put("CatalogItems(1)", json={})
        client.put("CatalogItems(2)", json={})

        me_calls = [r for r in m.request_history if r.url.endswith("/api/v2.0/me")]
        assert len(me_calls) == 1


# --- AC3: a plain GET does NOT carry the X-XSRF-TOKEN header -----------------


def test_plain_get_has_no_xsrf_token_header():
    """A GET never sends X-XSRF-TOKEN, even after a prior write set one."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok-1"},
            json={},
        )
        m.put(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(1)",
            status_code=200,
            json={},
        )
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            json={"value": []},
        )

        client.put("CatalogItems(1)", json={})  # establishes the token
        client.get("CatalogItems")

        get_req = next(
            r
            for r in m.request_history
            if r.method == "GET" and r.url.endswith("/v2.0/CatalogItems")
        )
        assert "X-XSRF-TOKEN" not in get_req.headers


def test_plain_get_without_any_write_has_no_token_header():
    """A read-only client issues no handshake and no token header."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            json={"value": []},
        )

        client.get("CatalogItems")

        assert m.call_count == 1  # no /me probe occurred
        assert "X-XSRF-TOKEN" not in m.request_history[0].headers


# --- AC4: NTLM auth wired when credentials supplied -------------------------


def test_ntlm_auth_wired_when_credentials_supplied():
    """The session's auth is an HttpNtlmAuth when user/password are given."""
    client = RestClient("pbirs.contoso.com", username="dom\\svc", password="pw")
    assert isinstance(client.session.auth, HttpNtlmAuth)


def test_ntlm_auth_applied_to_outgoing_requests():
    """The session carrying HttpNtlmAuth is the one used for each request.

    The session-level ``auth`` is what requests applies to every outgoing
    request, so asserting the session's auth is the HttpNtlmAuth instance and
    that real requests flow through that same session proves NTLM is wired on
    the wire (HttpNtlmAuth installs a response hook rather than a static header,
    so the header is not observable on a mocked prepared request).
    """
    client = RestClient("pbirs.contoso.com", username="dom\\svc", password="pw")
    assert isinstance(client.session.auth, HttpNtlmAuth)
    with requests_mock.Mocker(session=client.session) as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            json={"value": []},
        )
        client.get("CatalogItems")
        assert m.call_count == 1


def test_no_auth_when_credentials_absent():
    """Without credentials the session uses no NTLM auth."""
    client = RestClient("pbirs.contoso.com")
    assert client.session.auth is None


# --- AC5: non-2xx raises the typed client error -----------------------------


def test_non_2xx_get_raises_typed_error():
    """A 4xx GET raises RestClientError carrying the status code."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            status_code=404,
            json={"error": "not found"},
        )
        with pytest.raises(RestClientError) as exc:
            client.get("CatalogItems")
        assert exc.value.status_code == 404


def test_non_2xx_write_raises_typed_error():
    """A 5xx write raises RestClientError after the handshake."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok"},
            json={},
        )
        m.put(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(1)",
            status_code=500,
            json={},
        )
        with pytest.raises(RestClientError) as exc:
            client.put("CatalogItems(1)", json={})
        assert exc.value.status_code == 500


def test_2xx_returns_parsed_json():
    """A 200 GET returns the decoded JSON body."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            json={"value": [{"Id": "1"}]},
        )
        result = client.get("CatalogItems")
        assert result == {"value": [{"Id": "1"}]}


# --- defensive branches: token-jar fallback, empty/non-JSON bodies ----------


def test_xsrf_token_read_from_session_cookie_jar_fallback():
    """When the token is in the session jar (not resp.cookies), it's used."""
    client = RestClient("pbirs.contoso.com")
    # Seed the session cookie jar as if a prior response had set it; the /me
    # response below carries no Set-Cookie, exercising the jar fallback path.
    client.session.cookies.set("XSRF-TOKEN", "jar-tok")
    with requests_mock.Mocker() as m:
        m.get("https://pbirs.contoso.com/Reports/api/v2.0/me", json={})
        m.put(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(1)",
            status_code=200,
            json={},
        )
        client.put("CatalogItems(1)", json={})

        put_req = next(r for r in m.request_history if r.method == "PUT")
        assert put_req.headers["X-XSRF-TOKEN"] == "jar-tok"


def test_xsrf_handshake_without_token_raises():
    """A handshake yielding no XSRF cookie raises RestClientError."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get("https://pbirs.contoso.com/Reports/api/v2.0/me", json={})
        m.put(requests_mock.ANY, status_code=200, json={})
        with pytest.raises(RestClientError):
            client.put("CatalogItems(1)", json={})


def test_empty_response_body_returns_none():
    """A 200 with an empty body decodes to None, not an error."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/me",
            cookies={"XSRF-TOKEN": "tok"},
            json={},
        )
        m.put(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems(1)",
            status_code=200,
            content=b"",
        )
        assert client.put("CatalogItems(1)", json={}) is None


def test_non_json_response_body_returns_none():
    """A 200 with a non-JSON body decodes to None, not an error."""
    client = RestClient("pbirs.contoso.com")
    with requests_mock.Mocker() as m:
        m.get(
            "https://pbirs.contoso.com/Reports/api/v2.0/CatalogItems",
            status_code=200,
            text="not json",
        )
        assert client.get("CatalogItems") is None
