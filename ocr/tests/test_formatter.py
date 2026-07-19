"""Unit tests for the dots.mocr layout-JSON → markdown formatter.

Run from the repo root (no GPU or running stack required):

    python3 -m unittest discover -s ocr/tests -v
"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import _element_to_markdown, _extract_json, layout_json_to_markdown


ELEMENTS = [
    {"bbox": [10, 5, 600, 40], "category": "Page-header", "text": "ACME Corp Confidential"},
    {"bbox": [50, 60, 550, 100], "category": "Title", "text": "# Quarterly Report"},
    {"bbox": [50, 120, 550, 200], "category": "Text", "text": "Revenue grew **12%** this quarter."},
    {"bbox": [50, 220, 550, 400], "category": "Table",
     "text": "<table><tr><th>Q</th><th>Rev</th></tr><tr><td>Q1</td><td>10</td></tr></table>"},
    {"bbox": [50, 420, 550, 470], "category": "Formula", "text": "E = mc^2"},
    {"bbox": [50, 490, 550, 560], "category": "Picture"},
    {"bbox": [10, 700, 600, 730], "category": "Page-footer", "text": "Page 1 of 12"},
]


class TestExtractJson(unittest.TestCase):
    def test_plain_list(self):
        self.assertEqual(_extract_json(json.dumps(ELEMENTS)), ELEMENTS)

    def test_fenced_json(self):
        raw = "```json\n" + json.dumps(ELEMENTS) + "\n```"
        self.assertEqual(_extract_json(raw), ELEMENTS)

    def test_fenced_no_lang(self):
        raw = "```\n" + json.dumps(ELEMENTS) + "\n```"
        self.assertEqual(_extract_json(raw), ELEMENTS)

    def test_dict_wrapped_list(self):
        raw = json.dumps({"elements": ELEMENTS})
        self.assertEqual(_extract_json(raw), ELEMENTS)

    def test_single_object(self):
        el = ELEMENTS[2]
        self.assertEqual(_extract_json(json.dumps(el)), [el])

    def test_garbage_raises(self):
        with self.assertRaises((ValueError, json.JSONDecodeError)):
            _extract_json("The page shows a report about revenue.")

    def test_truncated_json_raises(self):
        with self.assertRaises(json.JSONDecodeError):
            _extract_json(json.dumps(ELEMENTS)[:-20])


class TestElementToMarkdown(unittest.TestCase):
    def test_header_footer_skipped(self):
        self.assertIsNone(_element_to_markdown(ELEMENTS[0]))
        self.assertIsNone(_element_to_markdown(ELEMENTS[-1]))

    def test_picture_skipped(self):
        self.assertIsNone(_element_to_markdown(ELEMENTS[5]))

    def test_formula_wrapped_in_latex_block(self):
        md = _element_to_markdown(ELEMENTS[4])
        self.assertEqual(md, "$$\nE = mc^2\n$$")

    def test_formula_already_delimited_untouched(self):
        md = _element_to_markdown({"category": "Formula", "text": "$E = mc^2$"})
        self.assertEqual(md, "$E = mc^2$")

    def test_table_html_passthrough(self):
        md = _element_to_markdown(ELEMENTS[3])
        self.assertTrue(md.startswith("<table>"))

    def test_text_passthrough(self):
        self.assertEqual(_element_to_markdown(ELEMENTS[2]),
                         "Revenue grew **12%** this quarter.")

    def test_empty_text_skipped(self):
        self.assertIsNone(_element_to_markdown({"category": "Text", "text": "  "}))

    def test_non_dict_skipped(self):
        self.assertIsNone(_element_to_markdown("just a string"))

    def test_missing_category_defaults_to_text(self):
        self.assertEqual(_element_to_markdown({"text": "hello"}), "hello")


class TestLayoutJsonToMarkdown(unittest.TestCase):
    def test_full_page(self):
        md = layout_json_to_markdown(json.dumps(ELEMENTS))
        # Reading order preserved, headers/footers/pictures dropped
        self.assertIn("# Quarterly Report", md)
        self.assertIn("Revenue grew **12%**", md)
        self.assertIn("<table>", md)
        self.assertIn("$$\nE = mc^2\n$$", md)
        self.assertNotIn("ACME Corp Confidential", md)
        self.assertNotIn("Page 1 of 12", md)
        self.assertLess(md.index("# Quarterly Report"), md.index("<table>"))

    def test_empty_list(self):
        self.assertEqual(layout_json_to_markdown("[]"), "")

    def test_unparseable_raises(self):
        with self.assertRaises((ValueError, json.JSONDecodeError)):
            layout_json_to_markdown("not json at all")


if __name__ == "__main__":
    unittest.main()
