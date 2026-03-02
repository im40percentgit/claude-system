#!/usr/bin/env python3
"""Tests for Gemini grounding URL redirect resolution in citation validation.

@decision DEC-VALIDATE-002
@title Grounding URL redirect tests mock only the HTTP boundary
@status accepted
@rationale urllib.request.urlopen is the external HTTP boundary. Mocking it
is the correct isolation point — it prevents real network calls in CI while
testing real internal logic (_follow_redirect and validate_citations). We do
NOT mock _follow_redirect itself; integration tests call it directly through
validate_citations so the full code path runs. This follows Sacred Practice #5:
mocks are acceptable only for external boundaries (HTTP, DB, third-party APIs).

# @mock-exempt: urllib.request.urlopen is an external HTTP boundary.
# All mocks in this file target urlopen only — no internal functions are mocked.

Verifies that vertexaisearch.cloud.google.com/grounding-api-redirect URLs
are followed to their final destinations before validation runs, so citations
are checked against real source pages instead of redirect intermediaries.
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, call
import urllib.error

# Add lib to path (same pattern as existing test files)
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.validate import _follow_redirect, validate_citations


GROUNDING_URL = (
    "https://vertexaisearch.cloud.google.com/grounding-api-redirect/"
    "AbF2UqX1234567890abcdef"
)
RESOLVED_URL = "https://www.reuters.com/technology/ai-news-2026"


def _make_mock_response(url: str) -> MagicMock:
    """Build a mock urlopen response that reports a given final URL."""
    mock_response = MagicMock()
    mock_response.url = url
    mock_response.status = 200
    mock_response.__enter__ = lambda s: s
    mock_response.__exit__ = MagicMock(return_value=False)
    return mock_response


class TestFollowRedirect(unittest.TestCase):
    """Unit tests for the _follow_redirect() helper function.

    All HTTP calls are mocked at the urllib.request.urlopen boundary.
    """

    def test_non_grounding_url_when_server_returns_same_url(self):
        """_follow_redirect returns original URL when response.url equals input.

        Simulates a server that does not redirect (final URL = original URL).
        The function should detect no redirect occurred and return the original.
        """
        ordinary_url = "https://www.example.com/article"
        mock_response = _make_mock_response(ordinary_url)

        with patch("urllib.request.urlopen", return_value=mock_response):
            result = _follow_redirect(ordinary_url)

        self.assertEqual(result, ordinary_url)

    def test_grounding_url_returns_resolved_url(self):
        """_follow_redirect resolves a grounding redirect to its final destination."""
        mock_response = _make_mock_response(RESOLVED_URL)

        with patch("urllib.request.urlopen", return_value=mock_response) as mock_open:
            result = _follow_redirect(GROUNDING_URL)

        self.assertEqual(result, RESOLVED_URL)
        mock_open.assert_called_once()

    def test_failed_redirect_url_error_returns_original(self):
        """_follow_redirect returns original URL on URLError (network failure)."""
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("timeout")):
            result = _follow_redirect(GROUNDING_URL)

        self.assertEqual(result, GROUNDING_URL)

    def test_failed_redirect_general_exception_returns_original(self):
        """_follow_redirect returns original URL on unexpected exceptions."""
        with patch("urllib.request.urlopen", side_effect=Exception("unexpected")):
            result = _follow_redirect(GROUNDING_URL)

        self.assertEqual(result, GROUNDING_URL)

    def test_head_fallback_to_get_on_405(self):
        """_follow_redirect falls back to GET when HEAD returns 405 Method Not Allowed."""
        get_response = _make_mock_response(RESOLVED_URL)
        head_error = urllib.error.HTTPError(
            GROUNDING_URL, 405, "Method Not Allowed", {}, None
        )

        # First call (HEAD) raises 405, second call (GET) succeeds
        with patch("urllib.request.urlopen", side_effect=[head_error, get_response]) as mock_open:
            result = _follow_redirect(GROUNDING_URL)

        self.assertEqual(result, RESOLVED_URL)
        self.assertEqual(mock_open.call_count, 2)


class TestValidateCitationsRedirect(unittest.TestCase):
    """Integration tests for grounding-URL redirect detection in validate_citations().

    Tests call validate_citations() directly, which internally calls
    _follow_redirect() and then the depth-specific validator. We mock
    urllib.request.urlopen at the HTTP boundary only — both _follow_redirect
    and the liveness validator use it, so one patch covers the full stack.
    """

    def _make_result(self, url: str, title: str = "Test Article") -> list:
        """Return a minimal list-of-dicts result compatible with validate_citations."""
        return [{"citations": [{"url": url, "title": title}]}]

    def test_non_grounding_url_passes_through_unchanged(self):
        """validate_citations does NOT add original_url for non-grounding URLs."""
        ordinary_url = "https://www.example.com/article"
        results = self._make_result(ordinary_url)

        # Mock urlopen so liveness check succeeds without a real network call
        mock_response = _make_mock_response(ordinary_url)
        with patch("urllib.request.urlopen", return_value=mock_response):
            validate_citations(results, depth=1)

        citation = results[0]["citations"][0]
        self.assertEqual(citation["url"], ordinary_url)
        self.assertNotIn("original_url", citation)

    def test_grounding_url_resolved_url_stored(self):
        """validate_citations replaces grounding URL with the resolved URL."""
        results = self._make_result(GROUNDING_URL)

        # urlopen is called twice: once by _follow_redirect (HEAD),
        # once by _validate_url_liveness (HEAD on the resolved URL).
        resolved_response = _make_mock_response(RESOLVED_URL)
        liveness_response = _make_mock_response(RESOLVED_URL)

        with patch("urllib.request.urlopen", side_effect=[resolved_response, liveness_response]):
            validate_citations(results, depth=1)

        citation = results[0]["citations"][0]
        self.assertEqual(citation["url"], RESOLVED_URL)

    def test_original_url_preserved_when_redirect_occurs(self):
        """When a grounding URL redirects, original_url is saved in the citation dict."""
        results = self._make_result(GROUNDING_URL)

        resolved_response = _make_mock_response(RESOLVED_URL)
        liveness_response = _make_mock_response(RESOLVED_URL)

        with patch("urllib.request.urlopen", side_effect=[resolved_response, liveness_response]):
            validate_citations(results, depth=1)

        citation = results[0]["citations"][0]
        self.assertEqual(citation["original_url"], GROUNDING_URL)
        self.assertEqual(citation["url"], RESOLVED_URL)

    def test_failed_redirect_leaves_citation_url_unchanged(self):
        """When _follow_redirect fails, citation URL stays as the grounding URL."""
        results = self._make_result(GROUNDING_URL)

        # First call (_follow_redirect HEAD) fails; second call (liveness HEAD) succeeds
        grounding_response = _make_mock_response(GROUNDING_URL)
        liveness_response = _make_mock_response(GROUNDING_URL)

        # _follow_redirect returns original URL when resolved == original
        with patch("urllib.request.urlopen", side_effect=[grounding_response, liveness_response]):
            validate_citations(results, depth=1)

        citation = results[0]["citations"][0]
        # URL unchanged
        self.assertEqual(citation["url"], GROUNDING_URL)
        # No original_url when no redirect occurred
        self.assertNotIn("original_url", citation)


if __name__ == "__main__":
    unittest.main()
