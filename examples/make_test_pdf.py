#!/usr/bin/env python3
"""Generate a small multi-page test PDF for OCR testing.

Run once to produce examples/test-doc.pdf. Committed output is checked in,
so you only need to rerun this if you change the content.
"""
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle
)
from reportlab.lib import colors
from pathlib import Path

OUT = Path(__file__).parent / "test-doc.pdf"

styles = getSampleStyleSheet()
title = ParagraphStyle("title", parent=styles["Title"], fontSize=22, spaceAfter=18)
h2 = ParagraphStyle("h2", parent=styles["Heading2"], fontSize=15, spaceAfter=10)
body = ParagraphStyle("body", parent=styles["BodyText"], fontSize=11, leading=15, spaceAfter=8)

doc = SimpleDocTemplate(
    str(OUT),
    pagesize=letter,
    leftMargin=0.9 * inch,
    rightMargin=0.9 * inch,
    topMargin=0.9 * inch,
    bottomMargin=0.9 * inch,
    title="DGX Stack OCR Test Document",
)

story = []

# ── Page 1 ─────────────────────────────────────────────────────────────────
story.append(Paragraph("DGX Stack OCR Test Document", title))
story.append(Paragraph("Page 1 &mdash; Introduction", h2))
story.append(Paragraph(
    "This document is a synthetic three-page PDF used to verify the end-to-end "
    "OCR pipeline of the DGX Stack. It exercises plain prose, a structured table, "
    "and a short technical listing so you can check whether the vision model is "
    "correctly extracting headings, paragraphs, tabular data, and code-like text.",
    body,
))
story.append(Paragraph(
    "The DGX Spark is a compact Grace-Blackwell workstation with 128&nbsp;GB of "
    "unified memory, a GB10 SoC, and CUDA 13. This stack runs a single multimodal "
    "model (Gemma 4 26B or Qwen 3.5 35B) that serves both the chat endpoint and "
    "the OCR endpoint, so there is only one set of weights resident in memory.",
    body,
))
story.append(Paragraph(
    "If the OCR output below preserves the page markers, the heading structure, "
    "and the numeric values in the table on page 2, the pipeline is healthy.",
    body,
))
story.append(PageBreak())

# ── Page 2 ─────────────────────────────────────────────────────────────────
story.append(Paragraph("Page 2 &mdash; Benchmark Table", h2))
story.append(Paragraph(
    "The following table summarises hypothetical throughput numbers. The actual "
    "values are unimportant &mdash; what matters is that the OCR correctly reads "
    "every cell and preserves the column alignment.",
    body,
))
story.append(Spacer(1, 0.15 * inch))

data = [
    ["Model", "Params", "Active", "Weights", "Context", "Tok/s"],
    ["Gemma 4 26B", "26B", "4B",  "52 GB (BF16)", "128K", "41.7"],
    ["Qwen 3.5 35B", "35B", "3B", "35 GB (FP8)",  "262K", "58.2"],
    ["Llama 3.1 70B", "70B", "70B", "140 GB (BF16)", "128K", "12.4"],
    ["Phi-4 14B", "14B", "14B", "28 GB (BF16)", "16K", "94.6"],
]
tbl = Table(data, colWidths=[1.5*inch, 0.7*inch, 0.7*inch, 1.3*inch, 0.9*inch, 0.7*inch])
tbl.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#334155")),
    ("TEXTCOLOR",  (0, 0), (-1, 0), colors.white),
    ("FONTNAME",   (0, 0), (-1, 0), "Helvetica-Bold"),
    ("FONTSIZE",   (0, 0), (-1, -1), 10),
    ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
    ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.whitesmoke, colors.white]),
    ("ALIGN", (1, 1), (-1, -1), "CENTER"),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("LEFTPADDING", (0, 0), (-1, -1), 6),
    ("RIGHTPADDING", (0, 0), (-1, -1), 6),
    ("TOPPADDING", (0, 0), (-1, -1), 5),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
]))
story.append(tbl)
story.append(Spacer(1, 0.2 * inch))
story.append(Paragraph(
    "Note: tokens-per-second numbers above are illustrative only. Real throughput "
    "depends heavily on batch size, prompt length, KV cache dtype, and whether "
    "prefix caching is enabled.",
    body,
))
story.append(PageBreak())

# ── Page 3 ─────────────────────────────────────────────────────────────────
story.append(Paragraph("Page 3 &mdash; Example Request", h2))
story.append(Paragraph(
    "Below is a representative JSON payload sent to the OpenAI-compatible chat "
    "endpoint. The OCR should preserve the braces, quotes, and the field ordering "
    "even though this is rendered as body text rather than a monospace block.",
    body,
))
story.append(Spacer(1, 0.1 * inch))

code = ParagraphStyle(
    "code",
    parent=styles["Code"],
    fontName="Courier",
    fontSize=10,
    leading=13,
    leftIndent=14,
    backColor=colors.HexColor("#f1f5f9"),
    borderPadding=8,
    spaceAfter=12,
)
story.append(Paragraph(
    "{<br/>"
    '&nbsp;&nbsp;"model": "qwen3.5-35b",<br/>'
    '&nbsp;&nbsp;"messages": [<br/>'
    '&nbsp;&nbsp;&nbsp;&nbsp;{"role": "user", "content": "Summarise page 2."}<br/>'
    "&nbsp;&nbsp;],<br/>"
    '&nbsp;&nbsp;"max_tokens": 256,<br/>'
    '&nbsp;&nbsp;"temperature": 0.2<br/>'
    "}",
    code,
))
story.append(Paragraph(
    "A successful OCR pass should return markdown in which page 1 contains the "
    "introduction, page 2 contains the benchmark table, and page 3 contains this "
    "example request. The word END-OF-TEST-DOCUMENT appears once, right here, so "
    "you can grep for it to confirm the final page was reached.",
    body,
))
story.append(Spacer(1, 0.2 * inch))
story.append(Paragraph("END-OF-TEST-DOCUMENT", h2))

doc.build(story)
print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")
