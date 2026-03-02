#!/usr/bin/env python3
"""Test suite for Perplexity claim context extraction.

@decision DEC-PERPLEXITY-CLAIMS: Extract surrounding sentence for each [N] marker
in Perplexity report text to populate citation["claim"]. This enables depth-3
cross-reference validation which otherwise falls through to trivial liveness check
for bare-URL citations that have no title or claim.

Tests verify the extraction logic in isolation by calling the function with
synthetic report text and citation lists — no HTTP calls needed.
"""

import sys
import unittest
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.perplexity_dr import _extract_claims


class TestExtractClaims(unittest.TestCase):
    """Test claim context extraction from [N] markers in Perplexity report text."""

    def test_basic_extraction(self):
        """Each citation gets the sentence surrounding its [N] marker."""
        report = (
            "Researchers found that neural networks can learn complex patterns.[1] "
            "Other studies suggest transformer models outperform RNNs in NLP tasks.[2] "
            "The latest benchmarks confirm these findings.[3]"
        )
        citations = [{"url": "https://example.com/1"},
                     {"url": "https://example.com/2"},
                     {"url": "https://example.com/3"}]

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertIn("claim", result[1])
        self.assertIn("claim", result[2])
        # Each claim should contain relevant words from the surrounding sentence
        self.assertIn("neural networks", result[0]["claim"])
        self.assertIn("transformer", result[1]["claim"])
        self.assertIn("benchmarks", result[2]["claim"])

    def test_marker_not_in_report(self):
        """Citations without a matching [N] marker are left without a claim."""
        report = "This report only mentions citation one.[1]"
        citations = [{"url": "https://example.com/1"},
                     {"url": "https://example.com/2"}]  # [2] not in report

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertNotIn("claim", result[1])

    def test_empty_citations(self):
        """Empty citation list returns empty list without error."""
        report = "Some report text with no citations."
        citations = []

        result = _extract_claims(report, citations)

        self.assertEqual(result, [])

    def test_empty_report(self):
        """Empty report text leaves citations without claims."""
        report = ""
        citations = [{"url": "https://example.com/1"}]

        result = _extract_claims(report, citations)

        self.assertNotIn("claim", result[0])

    def test_marker_at_start_of_text(self):
        """Marker at position 0 of text still extracts a claim."""
        report = "[1] This is a claim at the very start of the report text."
        citations = [{"url": "https://example.com/1"}]

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertIn("start of the report", result[0]["claim"])

    def test_marker_at_end_of_text(self):
        """Marker at end of text (no trailing sentence) still extracts a claim."""
        report = "This is a claim sentence with the marker at the very end.[1]"
        citations = [{"url": "https://example.com/1"}]

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertIn("claim sentence", result[0]["claim"])

    def test_consecutive_markers(self):
        """Consecutive markers [1][2] each get a claim from their shared context."""
        report = (
            "Multiple sources agree that climate change is accelerating.[1][2] "
            "A third source provides additional confirmation.[3]"
        )
        citations = [{"url": "https://example.com/1"},
                     {"url": "https://example.com/2"},
                     {"url": "https://example.com/3"}]

        result = _extract_claims(report, citations)

        # All three should have claims
        self.assertIn("claim", result[0])
        self.assertIn("claim", result[1])
        self.assertIn("claim", result[2])
        # [1] and [2] share the same sentence context
        self.assertIn("climate change", result[0]["claim"])
        self.assertIn("climate change", result[1]["claim"])
        self.assertIn("confirmation", result[2]["claim"])

    def test_claim_does_not_contain_marker(self):
        """The [N] marker itself is stripped from the extracted claim text."""
        report = "Quantum computing shows great promise for cryptography.[1]"
        citations = [{"url": "https://example.com/1"}]

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertNotIn("[1]", result[0]["claim"])

    def test_existing_claim_not_overwritten(self):
        """If citation already has a claim field, it is not overwritten."""
        report = "Some report text with a marker.[1]"
        citations = [{"url": "https://example.com/1", "claim": "pre-existing claim"}]

        result = _extract_claims(report, citations)

        self.assertEqual(result[0]["claim"], "pre-existing claim")

    def test_no_markers_in_report(self):
        """Report with no [N] markers leaves all citations without claims."""
        report = "This report has no citation markers at all."
        citations = [{"url": "https://example.com/1"},
                     {"url": "https://example.com/2"}]

        result = _extract_claims(report, citations)

        self.assertNotIn("claim", result[0])
        self.assertNotIn("claim", result[1])

    def test_dict_citation_with_title_preserved(self):
        """Dict citations (with title etc.) have claim added without losing other fields."""
        report = "A detailed study confirms the hypothesis.[1]"
        citations = [{"url": "https://example.com/1", "title": "Study Title"}]

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertEqual(result[0]["title"], "Study Title")
        self.assertEqual(result[0]["url"], "https://example.com/1")

    def test_multiline_report(self):
        """Markers in multiline report text extract claim from the right line."""
        report = (
            "First paragraph discusses foundational concepts.\n"
            "Neural networks were invented decades ago.[1]\n"
            "Second paragraph covers modern advances.\n"
            "Transformers changed NLP fundamentally.[2]"
        )
        citations = [{"url": "https://example.com/1"},
                     {"url": "https://example.com/2"}]

        result = _extract_claims(report, citations)

        self.assertIn("claim", result[0])
        self.assertIn("claim", result[1])
        self.assertIn("Neural networks", result[0]["claim"])
        self.assertIn("Transformers", result[1]["claim"])


if __name__ == "__main__":
    unittest.main()
