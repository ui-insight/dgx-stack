"""
OCR service that converts documents to markdown using dots.mocr via vLLM.

Accepts PDF, images, and Office documents. Converts each page to an image and
sends it to dots.mocr (a document-parsing VLM) one page per request — the
model is trained page-at-a-time. The layout-JSON response (bbox + category +
text per element, reading order) is rendered to markdown the same way the
upstream dots.mocr pipeline does: tables stay HTML, formulas become LaTeX
blocks, page headers/footers are dropped.
"""

import asyncio
import base64
import io
import json
import os
import re
import secrets
import subprocess
import tempfile
import time
from typing import Optional

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from pdf2image import convert_from_bytes, pdfinfo_from_bytes
from PIL import Image

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------

VLLM_BASE_URL = os.environ.get("VLLM_BASE_URL", "http://localhost:8001")
VLLM_MODEL = os.environ.get("VLLM_MODEL", "dots-mocr")
OCR_PORT = int(os.environ.get("OCR_PORT", "8010"))

# 200 DPI is the dots.mocr team's recommendation for PDF rendering; the
# server-side processor caps images at ~11.3MP itself, so the client
# only guards against extreme dimensions (their reference uses 4500px).
DPI = int(os.environ.get("OCR_DPI", "200"))
MAX_TOKENS = int(os.environ.get("OCR_MAX_TOKENS", "16384"))
TEMPERATURE = float(os.environ.get("OCR_TEMPERATURE", "0.1"))
TOP_P = float(os.environ.get("OCR_TOP_P", "0.9"))
MAX_CONCURRENT = int(os.environ.get("OCR_MAX_CONCURRENT_PAGES", "4"))
MAX_RETRIES = int(os.environ.get("OCR_MAX_RETRIES", "2"))
MAX_PAGES = int(os.environ.get("OCR_MAX_PAGES", "200"))
MAX_FILE_SIZE_MB = int(os.environ.get("OCR_MAX_FILE_SIZE_MB", "100"))
MAX_IMAGE_DIM = 4500

# dots.mocr's image placeholder must be inlined at the start of the text
# segment — without it vLLM inserts the placeholder itself followed by a
# newline, which is not how the model was trained (see the upstream
# inference.py in rednote-hilab/dots.mocr).
IMG_PLACEHOLDER = "<|img|><|imgpad|><|endofimg|>"

IMAGE_MIMES = {
    "image/png", "image/jpeg", "image/webp", "image/gif",
    "image/tiff", "image/bmp",
}
PDF_MIMES = {"application/pdf"}
OFFICE_MIMES = {
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/msword",
    "application/vnd.ms-excel",
    "application/vnd.ms-powerpoint",
}
OFFICE_EXTENSIONS = {".docx", ".xlsx", ".pptx", ".doc", ".xls", ".ppt"}

app = FastAPI(title="OCR Service", version="2.0.0")


# ---------------------------------------------------------------------------
# Helpers: image conversion
# ---------------------------------------------------------------------------

def _downscale(img: Image.Image) -> Image.Image:
    if max(img.size) > MAX_IMAGE_DIM:
        img.thumbnail((MAX_IMAGE_DIM, MAX_IMAGE_DIM), Image.LANCZOS)
    return img


def _image_to_b64(img: Image.Image) -> str:
    img = _downscale(img.convert("RGB"))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def _detect_mime(file: UploadFile) -> str:
    ct = file.content_type or "application/octet-stream"
    if ct == "application/octet-stream" and file.filename:
        ext = os.path.splitext(file.filename)[1].lower()
        ext_map = {
            ".pdf": "application/pdf",
            ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".webp": "image/webp", ".gif": "image/gif", ".tiff": "image/tiff",
            ".bmp": "image/bmp",
            ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            ".doc": "application/msword",
            ".xls": "application/vnd.ms-excel",
            ".ppt": "application/vnd.ms-powerpoint",
        }
        ct = ext_map.get(ext, ct)
    return ct


# ---------------------------------------------------------------------------
# Document → list of PIL images
# ---------------------------------------------------------------------------

def images_from_pdf_bytes(pdf_bytes: bytes, dpi: int) -> list[Image.Image]:
    info = pdfinfo_from_bytes(pdf_bytes)
    page_count = info.get("Pages", 0)
    if page_count > MAX_PAGES:
        raise HTTPException(400, f"PDF has {page_count} pages, max is {MAX_PAGES}")
    return convert_from_bytes(pdf_bytes, dpi=dpi)


def images_from_image_bytes(data: bytes) -> list[Image.Image]:
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception:
        raise HTTPException(400, "Could not decode image file")
    frames = []
    try:
        while True:
            frames.append(img.copy())
            img.seek(img.tell() + 1)
    except EOFError:
        pass
    return frames


def office_to_pdf_bytes(data: bytes, filename: str) -> bytes:
    ext = os.path.splitext(filename)[1].lower() if filename else ".docx"
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, f"input{ext}")
        with open(src, "wb") as f:
            f.write(data)
        result = subprocess.run(
            ["libreoffice", "--headless", "--convert-to", "pdf", "--outdir", tmpdir, src],
            timeout=120, capture_output=True,
        )
        pdf_path = os.path.join(tmpdir, "input.pdf")
        if result.returncode != 0 or not os.path.exists(pdf_path):
            detail = (result.stderr or b"").decode(errors="replace")[-300:]
            raise HTTPException(500, f"Office-to-PDF conversion failed: {detail or 'no output produced'}")
        with open(pdf_path, "rb") as f:
            return f.read()


# ---------------------------------------------------------------------------
# dots.mocr prompts (verbatim from rednote-hilab/dots.mocr prompts.py)
# ---------------------------------------------------------------------------

# Primary: full layout parse. Output is a single JSON object listing every
# layout element with bbox, category, and text (tables as HTML, formulas as
# LaTeX, everything else markdown), sorted in reading order.
DOTS_LAYOUT_PROMPT = """Please output the layout information from the PDF image, including each layout element's bbox, its category, and the corresponding text content within the bbox.

1. Bbox format: [x1, y1, x2, y2]

2. Layout Categories: The possible categories are ['Caption', 'Footnote', 'Formula', 'List-item', 'Page-footer', 'Page-header', 'Picture', 'Section-header', 'Table', 'Text', 'Title'].

3. Text Extraction & Formatting Rules:
    - Picture: For the 'Picture' category, the text field should be omitted.
    - Formula: Format its text as LaTeX.
    - Table: Format its text as HTML.
    - All Others (Text, Title, etc.): Format their text as Markdown.

4. Constraints:
    - The output text must be the original text from the image, with no translation.
    - All layout elements must be sorted according to human reading order.

5. Final Output: The entire output must be a single JSON object.
"""

# Fallback: plain text extraction (used when the layout JSON cannot be
# parsed after retries).
DOTS_TEXT_PROMPT = "Extract the text content from this image."


# ---------------------------------------------------------------------------
# Layout JSON → markdown (same rendering rules as the upstream pipeline)
# ---------------------------------------------------------------------------

_SKIP_CATEGORIES = {"Page-header", "Page-footer"}


def _extract_json(text: str):
    """Parse the model's layout output into a list of element dicts."""
    t = text.strip()
    # Strip markdown fences even when preamble/commentary surrounds them
    fence = re.search(r"```(?:json)?\s*(.*?)\s*```", t, re.DOTALL)
    if fence:
        t = fence.group(1)
    data = json.loads(t)
    if isinstance(data, dict):
        # Some outputs wrap the element list in a single-key object; only
        # unwrap values that look like element lists (bbox values are lists
        # of ints, which must not be mistaken for the element list).
        for v in data.values():
            if isinstance(v, list) and v and all(isinstance(e, dict) for e in v):
                return v
        return [data]
    if isinstance(data, list):
        return data
    raise ValueError("layout JSON is neither list nor object")


def _element_to_markdown(el: dict) -> Optional[str]:
    if not isinstance(el, dict):
        return None
    category = el.get("category", "Text")
    if category in _SKIP_CATEGORIES or category == "Picture":
        return None
    text = (el.get("text") or "").strip()
    if not text:
        return None
    if category == "Formula":
        if not text.startswith("$"):
            return f"$$\n{text}\n$$"
        return text
    # Tables arrive as HTML and are valid inside markdown as-is; Section
    # headers/titles/list items already arrive markdown-formatted.
    return text


def _render_elements(elements: list) -> str:
    parts = []
    for el in elements:
        md = _element_to_markdown(el)
        if md:
            parts.append(md)
    return "\n\n".join(parts)


def layout_json_to_markdown(raw: str) -> str:
    """Render dots.mocr layout JSON to markdown. Raises on unparseable JSON."""
    return _render_elements(_extract_json(raw))


# ---------------------------------------------------------------------------
# LLM call per page
# ---------------------------------------------------------------------------

async def _mocr_request(
    client: httpx.AsyncClient, page_b64: str, prompt: str,
) -> tuple[str, dict]:
    payload = {
        "model": VLLM_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url",
                 "image_url": {"url": f"data:image/png;base64,{page_b64}"}},
                {"type": "text", "text": f"{IMG_PLACEHOLDER}{prompt}"},
            ],
        }],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "stream": False,
    }
    resp = await client.post(
        f"{VLLM_BASE_URL}/v1/chat/completions",
        json=payload,
        timeout=600.0,
    )
    resp.raise_for_status()
    data = resp.json()
    text = data["choices"][0]["message"]["content"] or ""
    usage = data.get("usage", {})
    return text, usage


def _accumulate(total: dict, usage: dict) -> None:
    for k in total:
        total[k] += usage.get(k, 0)


async def ocr_page(
    client: httpx.AsyncClient,
    page_b64: str,
    semaphore: asyncio.Semaphore,
    page_num: int = 0,
) -> tuple[str, dict]:
    """OCR one page: layout parse → markdown, with retries and a plain-text
    fallback if the layout JSON never parses.

    A successful parse is the acceptance signal: repetition loops and
    truncation produce invalid JSON, while a parsed element list — even one
    that renders to empty markdown (picture-only page) — is a real result.
    An empty element list ([]) is retried in case the model bailed early;
    if it stays empty across retries the page is genuinely blank.
    Transport/HTTP errors count as failed attempts and are retried; if the
    backend never responds usefully the document fails with a 502 naming
    the page rather than a generic 500.
    """
    total_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    async with semaphore:
        parsed_empty = False
        last_err = None
        for _ in range(1 + MAX_RETRIES):
            try:
                raw, usage = await _mocr_request(client, page_b64, DOTS_LAYOUT_PROMPT)
            except httpx.HTTPError as e:
                last_err = e
                continue
            _accumulate(total_usage, usage)
            try:
                elements = _extract_json(raw)
            except (ValueError, json.JSONDecodeError):
                continue
            if elements:
                return _render_elements(elements), total_usage
            parsed_empty = True
        if parsed_empty:
            return "", total_usage
        # Layout parsing kept failing — fall back to plain text extraction.
        try:
            text, usage = await _mocr_request(client, page_b64, DOTS_TEXT_PROMPT)
        except httpx.HTTPError as e:
            raise HTTPException(
                502, f"OCR backend error on page {page_num}: {type(e).__name__}: {e}"
            ) from e
        _accumulate(total_usage, usage)
        return text.strip(), total_usage


# ---------------------------------------------------------------------------
# Pipeline orchestration
# ---------------------------------------------------------------------------

def _document_to_b64_pages(data: bytes, mime: str, filename: str, dpi: int) -> list[str]:
    """Blocking part of the pipeline: rasterize the document and encode
    pages. Runs in a worker thread so LibreOffice/poppler/PIL work does
    not stall the event loop."""
    if mime in PDF_MIMES:
        pages = images_from_pdf_bytes(data, dpi)
    elif mime in IMAGE_MIMES:
        pages = images_from_image_bytes(data)
    elif mime in OFFICE_MIMES:
        pdf_bytes = office_to_pdf_bytes(data, filename)
        pages = images_from_pdf_bytes(pdf_bytes, dpi)
    else:
        raise HTTPException(400, f"Unsupported file type: {mime}")

    if not pages:
        raise HTTPException(400, "No pages found in document")
    if len(pages) > MAX_PAGES:
        raise HTTPException(400, f"Document has {len(pages)} pages, max is {MAX_PAGES}")

    return [_image_to_b64(p) for p in pages]


async def process_document(
    data: bytes,
    mime: str,
    filename: str,
    dpi: int,
) -> tuple[str, int, dict]:
    """
    Full OCR pipeline. Returns (markdown, page_count, usage).
    """
    # Steps 1+2: rasterize + encode off the event loop
    page_b64s = await asyncio.to_thread(_document_to_b64_pages, data, mime, filename, dpi)
    page_count = len(page_b64s)

    # Step 3: OCR each page concurrently (dots.mocr is a single-page model)
    semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    total_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(*[
            ocr_page(client, b64, semaphore, page_num=i + 1)
            for i, b64 in enumerate(page_b64s)
        ])

    page_texts = []
    for text, usage in results:
        page_texts.append(text)
        _accumulate(total_usage, usage)

    # Step 4: join pages (no overlap dedup needed — pages are disjoint)
    markdown = "\n\n".join(t for t in page_texts if t)

    return markdown, page_count, total_usage


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok"}


DPI_MIN, DPI_MAX = 40, 400


def _clamp_dpi(dpi: int) -> int:
    return max(DPI_MIN, min(dpi, DPI_MAX))


@app.post("/v1/ocr")
async def ocr_endpoint(
    file: UploadFile = File(...),
    # model is accepted for API compatibility but ignored — the service
    # always talks to the single model its vLLM backend serves.
    model: Optional[str] = Form(None),
    output_format: str = Form("markdown"),
    # chunk_size/overlap are accepted (as raw strings, so stale clients
    # sending anything don't 422) but ignored: dots.mocr processes
    # exactly one page per request.
    chunk_size: Optional[str] = Form(None),
    overlap: Optional[str] = Form(None),
    dpi: int = Form(DPI),
):
    """OCR a document and return structured JSON result."""
    data = await file.read()
    if len(data) > MAX_FILE_SIZE_MB * 1024 * 1024:
        raise HTTPException(400, f"File too large, max {MAX_FILE_SIZE_MB}MB")

    mime = _detect_mime(file)
    markdown, page_count, usage = await process_document(
        data, mime, file.filename or "", _clamp_dpi(dpi),
    )

    return JSONResponse({
        "id": f"ocr-{secrets.token_hex(12)}",
        "object": "ocr.result",
        "created": int(time.time()),
        "model": VLLM_MODEL,
        "content": markdown,
        "format": output_format,
        "pages": page_count,
        "chunks_processed": page_count,
        "usage": usage,
    })


@app.post("/v1/ocrmd")
async def ocrmd_endpoint(
    file: UploadFile = File(...),
    model: Optional[str] = Form(None),
    chunk_size: Optional[str] = Form(None),
    overlap: Optional[str] = Form(None),
    dpi: int = Form(DPI),
):
    """OCR a document and return raw markdown."""
    data = await file.read()
    if len(data) > MAX_FILE_SIZE_MB * 1024 * 1024:
        raise HTTPException(400, f"File too large, max {MAX_FILE_SIZE_MB}MB")

    mime = _detect_mime(file)
    markdown, _, _ = await process_document(
        data, mime, file.filename or "", _clamp_dpi(dpi),
    )

    return PlainTextResponse(markdown, media_type="text/markdown")
