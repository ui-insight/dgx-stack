"""
OCR service that converts documents to markdown using Gemma 4 multimodal via vLLM.

Accepts PDF, images, and Office documents. Converts pages to images, processes
them in overlapping chunks through the vision LLM, and merges results using
difflib sequence matching (same approach as mindrouter /v1/ocrmd).
"""

import asyncio
import base64
import difflib
import io
import os
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

VLLM_BASE_URL = os.environ.get("VLLM_BASE_URL", "http://localhost:8000")
VLLM_MODEL = os.environ.get("VLLM_MODEL", "gemma-4-26b")
OCR_PORT = int(os.environ.get("OCR_PORT", "8010"))

CHUNK_SIZE = int(os.environ.get("OCR_CHUNK_SIZE", "6"))
OVERLAP = int(os.environ.get("OCR_OVERLAP", "2"))
DPI = int(os.environ.get("OCR_DPI", "200"))
MAX_TOKENS = int(os.environ.get("OCR_MAX_TOKENS", "16384"))
TEMPERATURE = float(os.environ.get("OCR_TEMPERATURE", "0.1"))
MAX_CONCURRENT = int(os.environ.get("OCR_MAX_CONCURRENT_CHUNKS", "4"))
MIN_CHARS_PER_PAGE = int(os.environ.get("OCR_MIN_CHARS_PER_PAGE", "400"))
MAX_RETRIES = int(os.environ.get("OCR_MAX_RETRIES", "2"))
MAX_PAGES = int(os.environ.get("OCR_MAX_PAGES", "200"))
MAX_FILE_SIZE_MB = int(os.environ.get("OCR_MAX_FILE_SIZE_MB", "100"))
MAX_IMAGE_DIM = 2048

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

app = FastAPI(title="OCR Service", version="1.0.0")


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


def images_from_pdf_range(pdf_bytes: bytes, first: int, last: int, dpi: int) -> list[Image.Image]:
    """Convert a specific page range (1-indexed, inclusive) from a PDF."""
    return convert_from_bytes(pdf_bytes, dpi=dpi, first_page=first, last_page=last)


def images_from_image_bytes(data: bytes) -> list[Image.Image]:
    img = Image.open(io.BytesIO(data))
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
        subprocess.run(
            ["libreoffice", "--headless", "--convert-to", "pdf", "--outdir", tmpdir, src],
            check=True, timeout=120, capture_output=True,
        )
        pdf_path = os.path.join(tmpdir, f"input.pdf")
        with open(pdf_path, "rb") as f:
            return f.read()


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

def make_chunks(n_pages: int, chunk_size: int, overlap: int) -> list[tuple[int, int]]:
    """Return list of (start, end) tuples (0-indexed, end exclusive)."""
    if n_pages == 0:
        return []
    stride = max(chunk_size - overlap, 1)
    chunks = []
    for start in range(0, n_pages, stride):
        end = min(start + chunk_size, n_pages)
        chunks.append((start, end))
        if end >= n_pages:
            break
    return chunks


# ---------------------------------------------------------------------------
# LLM call per chunk
# ---------------------------------------------------------------------------

OCR_PROMPT = (
    "Convert ALL of the following page images to well-structured markdown. "
    "Render tables as proper markdown tables with correct columns and rows. "
    "Do not add any preamble like 'Here is the markdown' - just output the "
    "markdown directly. Preserve all text exactly as it appears. Do not "
    "summarize or omit anything. Do not add any commentary. "
    "There are {n} page images - make sure you process EVERY page."
)

OCR_RETRY_PROMPT = (
    "IMPORTANT: You MUST convert ALL {n} page images to markdown. Your "
    "previous attempt was incomplete. Process every single page image below "
    "and output the complete markdown. Do not skip any page. "
    "Render tables as proper markdown tables. Output markdown directly with "
    "no preamble or commentary."
)


async def ocr_chunk(
    client: httpx.AsyncClient,
    page_b64s: list[str],
    retry: bool = False,
) -> tuple[str, dict]:
    """Send a chunk of page images to the vision LLM. Returns (text, usage)."""
    n = len(page_b64s)
    prompt = (OCR_RETRY_PROMPT if retry else OCR_PROMPT).format(n=n)

    content = [{"type": "text", "text": prompt}]
    for b64 in page_b64s:
        content.append({
            "type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{b64}"},
        })

    payload = {
        "model": VLLM_MODEL,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "stream": False,
    }

    resp = await client.post(
        f"{VLLM_BASE_URL}/v1/chat/completions",
        json=payload,
        timeout=600.0,
    )
    resp.raise_for_status()
    data = resp.json()
    text = data["choices"][0]["message"]["content"]
    usage = data.get("usage", {})

    # Strip wrapping markdown fences
    if text.startswith("```markdown"):
        text = text[len("```markdown"):].strip()
    if text.startswith("```"):
        text = text[3:].strip()
    if text.endswith("```"):
        text = text[:-3].strip()

    return text, usage


async def ocr_chunk_with_retry(
    client: httpx.AsyncClient,
    page_b64s: list[str],
    semaphore: asyncio.Semaphore,
) -> tuple[str, dict]:
    """OCR a chunk, retrying if the output looks too short."""
    async with semaphore:
        text, usage = await ocr_chunk(client, page_b64s, retry=False)
        n_pages = len(page_b64s)
        for _ in range(MAX_RETRIES):
            if len(text) >= MIN_CHARS_PER_PAGE * n_pages:
                break
            text, usage = await ocr_chunk(client, page_b64s, retry=True)
        return text, usage


# ---------------------------------------------------------------------------
# Deterministic chunk merging (difflib, same approach as mindrouter)
# ---------------------------------------------------------------------------

def _normalize(line: str) -> str:
    return " ".join(line.lower().split())


def merge_chunks(texts: list[str]) -> str:
    if not texts:
        return ""
    if len(texts) == 1:
        return texts[0]

    merged = texts[0]
    for i in range(1, len(texts)):
        merged = _merge_pair(merged, texts[i])
    return merged


def _merge_pair(a: str, b: str) -> str:
    a_lines = a.splitlines()
    b_lines = b.splitlines()
    if not a_lines or not b_lines:
        return a + "\n\n" + b

    # Take tail ~40% of a, head ~40% of b for overlap detection
    tail_len = max(int(len(a_lines) * 0.4), 10)
    head_len = max(int(len(b_lines) * 0.4), 10)
    a_tail = a_lines[-tail_len:]
    b_head = b_lines[:head_len]

    a_norm = [_normalize(l) for l in a_tail]
    b_norm = [_normalize(l) for l in b_head]

    sm = difflib.SequenceMatcher(None, a_norm, b_norm, autojunk=False)
    blocks = sm.get_matching_blocks()

    # Find best contiguous match (merge nearby blocks within 5 lines)
    best_a_end = 0
    best_b_end = 0
    best_size = 0
    for block in blocks:
        if block.size == 0:
            continue
        size = block.size
        a_end = block.a + block.size
        b_end = block.b + block.size
        if size > best_size:
            best_size = size
            best_a_end = a_end
            best_b_end = b_end

    if best_size < 3:
        # No meaningful overlap found, just concatenate
        return a.rstrip() + "\n\n" + b.lstrip()

    # Cut a at end of match region, continue b from end of match region
    a_cut = len(a_lines) - tail_len + best_a_end
    b_cut = best_b_end

    result_lines = a_lines[:a_cut] + [""] + b_lines[b_cut:]
    return "\n".join(result_lines)


# ---------------------------------------------------------------------------
# Pipeline orchestration
# ---------------------------------------------------------------------------

async def process_document(
    data: bytes,
    mime: str,
    filename: str,
    chunk_size: int,
    overlap: int,
    dpi: int,
) -> tuple[str, int, int, dict]:
    """
    Full OCR pipeline. Returns (markdown, page_count, chunks_processed, usage).
    """
    # Step 1: get page images
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

    page_count = len(pages)

    # Step 2: convert all pages to base64
    page_b64s = [_image_to_b64(p) for p in pages]

    # Step 3: build chunks
    chunks = make_chunks(page_count, chunk_size, overlap)

    # Step 4: OCR each chunk concurrently
    semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    total_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

    async with httpx.AsyncClient() as client:
        tasks = []
        for start, end in chunks:
            chunk_pages = page_b64s[start:end]
            tasks.append(ocr_chunk_with_retry(client, chunk_pages, semaphore))

        results = await asyncio.gather(*tasks)

    chunk_texts = []
    for text, usage in results:
        chunk_texts.append(text)
        for k in total_usage:
            total_usage[k] += usage.get(k, 0)

    # Step 5: merge overlapping chunks
    markdown = merge_chunks(chunk_texts)

    return markdown, page_count, len(chunks), total_usage


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/v1/ocr")
async def ocr_endpoint(
    file: UploadFile = File(...),
    model: Optional[str] = Form(None),
    output_format: str = Form("markdown"),
    chunk_size: int = Form(CHUNK_SIZE),
    overlap: int = Form(OVERLAP),
    dpi: int = Form(DPI),
):
    """OCR a document and return structured JSON result."""
    use_model = model or VLLM_MODEL

    data = await file.read()
    if len(data) > MAX_FILE_SIZE_MB * 1024 * 1024:
        raise HTTPException(400, f"File too large, max {MAX_FILE_SIZE_MB}MB")

    mime = _detect_mime(file)
    markdown, page_count, chunks_processed, usage = await process_document(
        data, mime, file.filename or "", chunk_size, overlap, dpi,
    )

    return JSONResponse({
        "id": f"ocr-{secrets.token_hex(12)}",
        "object": "ocr.result",
        "created": int(time.time()),
        "model": use_model,
        "content": markdown,
        "format": output_format,
        "pages": page_count,
        "chunks_processed": chunks_processed,
        "usage": usage,
    })


@app.post("/v1/ocrmd")
async def ocrmd_endpoint(
    file: UploadFile = File(...),
    model: Optional[str] = Form(None),
    chunk_size: int = Form(CHUNK_SIZE),
    overlap: int = Form(OVERLAP),
    dpi: int = Form(DPI),
):
    """OCR a document and return raw markdown."""
    data = await file.read()
    if len(data) > MAX_FILE_SIZE_MB * 1024 * 1024:
        raise HTTPException(400, f"File too large, max {MAX_FILE_SIZE_MB}MB")

    mime = _detect_mime(file)
    markdown, _, _, _ = await process_document(
        data, mime, file.filename or "", chunk_size, overlap, dpi,
    )

    return PlainTextResponse(markdown, media_type="text/markdown")
