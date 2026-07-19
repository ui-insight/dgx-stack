"""Unit tests for the ocr_page retry/fallback logic (stubbed vLLM backend).

Run from the repo root (no GPU or running stack required):

    python3 -m unittest discover -s ocr/tests -v
"""

import asyncio
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app.main as main


USAGE = {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}

TEXT_PAGE = json.dumps([
    {"bbox": [50, 60, 550, 100], "category": "Title", "text": "# Report"},
    {"bbox": [50, 120, 550, 200], "category": "Text", "text": "Hello world."},
])
PICTURE_ONLY_PAGE = json.dumps([
    {"bbox": [12, 34, 1650, 2180], "category": "Picture"},
])


class StubBackend:
    """Replaces _mocr_request; returns scripted responses per call."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []  # list of prompts used

    async def __call__(self, client, page_b64, prompt):
        self.calls.append(prompt)
        if not self.responses:
            raise AssertionError("more requests than scripted responses")
        return self.responses.pop(0), dict(USAGE)


def run_ocr_page(stub):
    orig = main._mocr_request
    main._mocr_request = stub
    try:
        sem = asyncio.Semaphore(1)
        return asyncio.run(main.ocr_page(None, "fakeb64", sem))
    finally:
        main._mocr_request = orig


class TestOcrPage(unittest.TestCase):
    def test_clean_parse_returns_immediately(self):
        stub = StubBackend([TEXT_PAGE])
        md, usage = run_ocr_page(stub)
        self.assertIn("# Report", md)
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(usage["total_tokens"], 150)

    def test_picture_only_page_accepted_without_fallback(self):
        # A parsed page with only a Picture element is a real (empty) result:
        # no retries, no plain-text fallback.
        stub = StubBackend([PICTURE_ONLY_PAGE])
        md, usage = run_ocr_page(stub)
        self.assertEqual(md, "")
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(stub.calls[0], main.DOTS_LAYOUT_PROMPT)

    def test_garbage_retries_then_falls_back_to_text(self):
        stub = StubBackend(["not json", "still } not { json", "nope",
                           "  Plain extracted text.  "])
        md, usage = run_ocr_page(stub)
        self.assertEqual(md, "Plain extracted text.")
        # 1 + MAX_RETRIES layout attempts, then the text fallback
        self.assertEqual(len(stub.calls), 1 + main.MAX_RETRIES + 1)
        self.assertEqual(stub.calls[-1], main.DOTS_TEXT_PROMPT)
        self.assertEqual(usage["total_tokens"], 150 * (1 + main.MAX_RETRIES + 1))

    def test_garbage_then_valid_parse_stops_retrying(self):
        stub = StubBackend(["truncated {", TEXT_PAGE])
        md, usage = run_ocr_page(stub)
        self.assertIn("Hello world.", md)
        self.assertEqual(len(stub.calls), 2)

    def test_consistently_empty_list_returns_blank_no_fallback(self):
        stub = StubBackend(["[]"] * (1 + main.MAX_RETRIES))
        md, usage = run_ocr_page(stub)
        self.assertEqual(md, "")
        self.assertEqual(len(stub.calls), 1 + main.MAX_RETRIES)
        self.assertNotIn(main.DOTS_TEXT_PROMPT, stub.calls)

    def test_empty_list_then_content_is_retried_and_accepted(self):
        stub = StubBackend(["[]", TEXT_PAGE])
        md, usage = run_ocr_page(stub)
        self.assertIn("Hello world.", md)
        self.assertEqual(len(stub.calls), 2)


if __name__ == "__main__":
    unittest.main()
