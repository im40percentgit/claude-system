"""Perplexity deep research provider client.

@decision Synchronous long-timeout request for Perplexity — sonar-deep-research
is a synchronous API (no background/polling). It can take 60-300s to respond.
We use a 300s timeout and extract inline citations from the response content.
Rate limit is 5-10 req/min so no special handling needed for single requests.

Uses the standard Chat Completions API format.

@decision DEC-PERPLEXITY-CLAIMS: Extract surrounding sentence for each [N] marker
in report text to populate citation["claim"]. Perplexity returns bare URLs with no
title in its citations array; without a claim, depth-2+ validation in validate.py
falls through to the trivial "page reachable" check instead of cross-reference
validation. By scanning for [N] markers and extracting ~200 chars of context
trimmed to sentence boundaries, we populate the claim field that
_validate_url_cross_reference() already consumes. This is purely additive —
citations without matching markers are left unchanged, and pre-existing claim
fields are never overwritten.
"""

import re
from typing import Any, Dict, List, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL = "https://api.perplexity.ai"
MODEL = "sonar-deep-research"
REQUEST_TIMEOUT = 300  # seconds — deep research can take several minutes


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }


def _extract_claims(report: str, citations: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Extract claim context from [N] markers in report text and attach to citations.

    Scans the report for [1], [2], ... markers corresponding to citation indices,
    extracts ~200 chars of surrounding context trimmed to sentence boundaries,
    strips the marker itself, and sets citation["claim"] if not already present.

    Args:
        report: Full report text from Perplexity response.
        citations: List of citation dicts (may have "url", "title", etc.).

    Returns:
        The same citations list with "claim" fields added where markers were found.
        Mutates in place and returns for convenience.
    """
    if not citations or not report:
        return citations

    for i, citation in enumerate(citations):
        # Skip if claim already populated (e.g. future API versions may return it)
        if citation.get("claim"):
            continue

        marker = f"[{i + 1}]"
        if marker not in report:
            continue

        pos = report.index(marker)

        # Extract ~200 chars context around marker
        start = max(0, pos - 200)
        end = min(len(report), pos + 200)
        context = report[start:end]

        # Trim to sentence start: find last '. ' or '\n' before the marker.
        # '. ' delimiter: skip 2 chars (period + space).
        # '\n' delimiter: skip 1 char (newline only).
        relative_pos = pos - start
        dot_pos = context.rfind('. ', 0, relative_pos)
        nl_pos = context.rfind('\n', 0, relative_pos)
        if dot_pos > 0 or nl_pos > 0:
            if dot_pos >= nl_pos:
                context = context[dot_pos + 2:]
            else:
                context = context[nl_pos + 1:]

        # Find sentence end after the marker position in the trimmed context
        marker_in_ctx = context.find(marker)
        if marker_in_ctx >= 0:
            marker_end = marker_in_ctx + len(marker)
            sent_end = context.find('.', marker_end)
            if sent_end > 0:
                context = context[:sent_end + 1]

        # Remove the marker itself from claim text
        claim = context.replace(marker, '').strip()
        if claim:
            citation["claim"] = claim

    return citations


def research(api_key: str, topic: str) -> Tuple[str, List[Any], str]:
    """Run Perplexity deep research on a topic.

    Args:
        api_key: Perplexity API key
        topic: Research topic/question

    Returns:
        Tuple of (report_text, citations, model_used)

    Raises:
        http.HTTPError: On API failure
    """
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": topic}],
    }

    resp = http.post(
        f"{BASE_URL}/chat/completions",
        json_data=payload,
        headers=_headers(api_key),
        timeout=REQUEST_TIMEOUT,
    )

    report = ""
    citations = []

    # Extract report from chat completion response
    choices = resp.get("choices", [])
    if choices:
        message = choices[0].get("message", {})
        report = message.get("content", "")

    # Extract citations if present (Perplexity includes them in response)
    raw_citations = resp.get("citations", [])
    for url in raw_citations:
        if isinstance(url, str):
            citations.append({"url": url})
        elif isinstance(url, dict):
            citations.append(url)

    # Extract claim context from [N] markers in report text
    # See @decision DEC-PERPLEXITY-CLAIMS in module docstring for rationale.
    _extract_claims(report, citations)

    model_used = resp.get("model", MODEL)
    return report, citations, model_used
