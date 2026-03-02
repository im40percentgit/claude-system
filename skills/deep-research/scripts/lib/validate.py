"""Citation validation for deep-research results.

@decision Post-collection validation (runs after all providers return) rather than
inline validation. Four depth levels: 0=none, 1=liveness (HEAD request),
2=relevance (fetch + text match), 3=cross-reference (fetch + verify claim).
Uses urllib directly for raw HTTP (not http.py which parses JSON) — stdlib-only.

@decision DEC-VALIDATE-001
@title Grounding URL redirect resolution is scoped to vertexaisearch URLs only
@status accepted
@rationale Following redirects for ALL citation URLs would add one extra HTTP
round-trip per citation (performance cost), could trigger unintended side effects
on URLs that use POST-redirect-GET patterns or auth flows, and is unnecessary for
most providers (Perplexity, OpenAI return final URLs directly). Gemini's
vertexaisearch.cloud.google.com/grounding-api-redirect/* URLs are the sole known
case where the citation URL is an opaque redirect intermediary rather than the
real source. Scoping the resolution to this specific host pattern minimises
overhead while fixing the false-negative validation problem described in issue #9.
"""

import re
import time
import urllib.request
import urllib.error
from typing import Any, Dict, List

_GROUNDING_REDIRECT_MARKER = "vertexaisearch.cloud.google.com/grounding-api-redirect"


def _fetch_raw_html(url: str, timeout: int = 15) -> tuple[str, int]:
    """Fetch raw HTML content from a URL.

    Args:
        url: URL to fetch
        timeout: Request timeout in seconds

    Returns:
        Tuple of (html_content, status_code)

    Raises:
        urllib.error.HTTPError: On HTTP errors
        urllib.error.URLError: On network errors
    """
    headers = {"User-Agent": "deep-research-validator/1.0"}
    req = urllib.request.Request(url, headers=headers, method="GET")

    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode('utf-8', errors='ignore')
        return body, response.status


def _follow_redirect(url: str) -> str:
    """Follow HTTP redirects and return the final URL after all hops.

    Attempts a HEAD request first (lightweight, no body download). Falls back
    to GET when the server returns 405 Method Not Allowed, which some servers
    return for HEAD on redirect endpoints.

    On any error the original URL is returned unchanged so callers can proceed
    with the unresolved URL rather than failing hard.

    Args:
        url: URL to resolve (may be a redirect intermediary)

    Returns:
        Final URL after following all redirects, or the original URL on error.
    """
    headers = {"User-Agent": "deep-research-validator/1.0"}

    # Try HEAD first — cheaper, no response body needed
    try:
        req = urllib.request.Request(url, headers=headers, method="HEAD")
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.url
    except urllib.error.HTTPError as e:
        if e.code == 405:
            # Server does not allow HEAD; fall through to GET
            pass
        else:
            # Other HTTP errors: return original URL unchanged
            return url
    except Exception:
        return url

    # HEAD was rejected — retry with GET
    try:
        req = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.url
    except Exception:
        return url


def _validate_url_liveness(url: str) -> Dict[str, Any]:
    """Check if a URL is reachable via HEAD request.

    Args:
        url: URL to validate

    Returns:
        Dict with status, details
    """
    try:
        headers = {"User-Agent": "deep-research-validator/1.0"}
        req = urllib.request.Request(url, headers=headers, method="HEAD")

        with urllib.request.urlopen(req, timeout=10) as response:
            status_code = response.status
            if 200 <= status_code < 400:
                return {"status": "valid", "details": f"HTTP {status_code}"}
            else:
                return {"status": "invalid", "details": f"HTTP {status_code}"}

    except urllib.error.HTTPError as e:
        if 200 <= e.code < 400:
            return {"status": "valid", "details": f"HTTP {e.code}"}
        else:
            return {"status": "invalid", "details": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def _validate_url_relevance(url: str, citation_title: str = "") -> Dict[str, Any]:
    """Check if a URL is reachable and contains relevant content.

    Args:
        url: URL to validate
        citation_title: Expected title or keywords to find

    Returns:
        Dict with status, details
    """
    try:
        html, status_code = _fetch_raw_html(url, timeout=15)

        if not (200 <= status_code < 400):
            return {"status": "invalid", "details": f"HTTP {status_code}"}

        # Level 2: Check if citation title appears in the page
        if citation_title:
            # Case-insensitive search
            html_lower = html.lower()
            title_lower = citation_title.lower()

            # Try exact phrase match first
            if title_lower in html_lower:
                return {"status": "valid", "details": "Citation title found in page"}

            # Try keyword match (at least 50% of words in title)
            title_words = [w for w in re.findall(r'\w+', title_lower) if len(w) > 3]
            if title_words:
                matches = sum(1 for word in title_words if word in html_lower)
                if matches / len(title_words) >= 0.5:
                    return {"status": "valid", "details": f"Keywords found ({matches}/{len(title_words)})"}

            return {"status": "invalid", "details": "Citation title not found in page"}
        else:
            # No title to verify, just check liveness
            return {"status": "valid", "details": "Page reachable (no title to verify)"}

    except urllib.error.HTTPError as e:
        return {"status": "invalid", "details": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def _validate_url_cross_reference(url: str, claim: str = "", citation_title: str = "") -> Dict[str, Any]:
    """Check if a URL supports a specific claim.

    Args:
        url: URL to validate
        claim: The specific claim to verify
        citation_title: Citation title or keywords

    Returns:
        Dict with status, details
    """
    try:
        html, status_code = _fetch_raw_html(url, timeout=15)

        if not (200 <= status_code < 400):
            return {"status": "invalid", "details": f"HTTP {status_code}"}

        html_lower = html.lower()

        # Level 3: Check if claim keywords appear in the page
        if claim:
            # Extract keywords from claim (words longer than 3 chars)
            claim_words = [w for w in re.findall(r'\w+', claim.lower()) if len(w) > 3]
            if claim_words:
                matches = sum(1 for word in claim_words if word in html_lower)
                if matches / len(claim_words) >= 0.6:  # 60% keyword match for claims
                    return {"status": "valid", "details": f"Claim keywords found ({matches}/{len(claim_words)})"}
                else:
                    return {"status": "invalid", "details": f"Insufficient claim support ({matches}/{len(claim_words)})"}

        # Fall back to title relevance
        if citation_title:
            title_lower = citation_title.lower()
            if title_lower in html_lower:
                return {"status": "valid", "details": "Citation title found in page"}

            title_words = [w for w in re.findall(r'\w+', title_lower) if len(w) > 3]
            if title_words:
                matches = sum(1 for word in title_words if word in html_lower)
                if matches / len(title_words) >= 0.5:
                    return {"status": "valid", "details": f"Title keywords found ({matches}/{len(title_words)})"}

            return {"status": "invalid", "details": "Citation not verified in page"}
        else:
            # No claim or title, just liveness
            return {"status": "valid", "details": "Page reachable (no claim to verify)"}

    except urllib.error.HTTPError as e:
        return {"status": "invalid", "details": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def validate_citations(results: List[Any], depth: int = 0) -> List[Any]:
    """Validate citations in provider results.

    Args:
        results: List of ProviderResult objects (as dicts)
        depth: Validation depth (0=none, 1=liveness, 2=relevance, 3=cross-ref)

    Returns:
        Modified results with validation data added to citations
    """
    if depth == 0:
        return results

    for result in results:
        # Get direct reference to citations list
        if hasattr(result, "citations"):
            citations = result.citations
        elif isinstance(result, dict):
            citations = result.get("citations", [])
        else:
            continue

        if not citations:
            continue

        for citation in citations:
            if not isinstance(citation, dict):
                citation["validation"] = {
                    "status": "skipped",
                    "depth": depth,
                    "details": "Non-dict citation",
                }
                continue

            url = citation.get("url", "")
            if not url:
                citation["validation"] = {
                    "status": "skipped",
                    "depth": depth,
                    "details": "No URL",
                }
                continue

            # Follow redirects for grounding URLs (e.g., Gemini's vertexaisearch redirects)
            if _GROUNDING_REDIRECT_MARKER in url:
                resolved = _follow_redirect(url)
                if resolved != url:
                    citation["original_url"] = url
                    citation["url"] = resolved
                    url = resolved

            # Validate based on depth
            if depth == 1:
                validation = _validate_url_liveness(url)
            elif depth == 2:
                title = citation.get("title", "")
                validation = _validate_url_relevance(url, title)
            elif depth == 3:
                title = citation.get("title", "")
                claim = citation.get("claim", "")  # May not exist
                validation = _validate_url_cross_reference(url, claim, title)
            else:
                validation = {"status": "skipped", "details": "Invalid depth"}

            # Add validation data to citation
            citation["validation"] = {
                "status": validation["status"],
                "depth": depth,
                "details": validation.get("details", ""),
            }

            # Rate limit: small delay between requests to avoid hammering servers
            time.sleep(0.2)

    return results
