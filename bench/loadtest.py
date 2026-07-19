#!/usr/bin/env python3
"""
DGX Stack load & correctness benchmark.

Exercises both vLLM instances and the OCR service under diverse,
concurrent load, and verifies the API features the stack advertises:

  LLM (Qwen 3.6):
    - thinking off by default / per-request opt-in (reasoning parsing)
    - tool calling (qwen3_xml parser) with a simulated tool round-trip
    - max_tokens enforcement
    - streaming decode throughput + TTFT across a concurrency sweep
  OCR (dots.mocr via the OCR service):
    - real downloaded PDFs (arXiv, cached in bench/fixtures/)
    - single-document latency and multi-document concurrent throughput
  Mixed:
    - simultaneous chat / thinking / tool-calling / OCR load

Stdlib only — runs on the DGX host (or any client) with plain python3:

    python3 bench/loadtest.py                 # full run (~10-20 min)
    python3 bench/loadtest.py --quick         # reduced run (~3 min)
    python3 bench/loadtest.py --skip-ocr      # LLM only
    python3 bench/loadtest.py --concurrency 1,4,8,12

Individual request failures are recorded as data (error counts per sweep
point, FAIL checks) rather than aborting the run, and results are always
written to bench/results-<timestamp>.json — even on a crash.

Exit codes: 0 all checks passed, 1 some checks failed, 2 preflight
unreachable, 3 harness crash.
"""

import argparse
import concurrent.futures
import json
import math
import statistics
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
FIXTURE_DIR = BENCH_DIR / "fixtures"
TEST_DOC = BENCH_DIR.parent / "examples" / "test-doc.pdf"

# Stable, real-world OCR fixtures (multi-column layouts, tables, math).
PDF_FIXTURES = [
    ("attention.pdf", "https://arxiv.org/pdf/1706.03762"),
    ("bert.pdf", "https://arxiv.org/pdf/1810.04805"),
]

WEATHER_TOOL = {
    "type": "function",
    "function": {
        "name": "get_current_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name"},
                "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
            },
            "required": ["city"],
        },
    },
}

PROMPTS = [
    "Explain how a mixture-of-experts transformer routes tokens.",
    "Summarize the tradeoffs between FP8 and 4-bit weight quantization.",
    "Describe how speculative decoding preserves output quality.",
    "What is unified memory on a Grace-Blackwell system?",
    "Explain KV-cache growth with context length in plain terms.",
    "How does prefix caching work in an LLM inference server?",
    "Why is LLM decode throughput usually memory-bandwidth bound?",
    "Describe the difference between prefill and decode phases.",
    "What does a reasoning parser do in an inference server?",
    "Explain chunked prefill and why it reduces head-of-line blocking.",
    "What is a draft model in speculative decoding?",
    "How do OCR-specialist VLMs differ from general VLMs?",
]


# ---------------------------------------------------------------------------
# HTTP helpers (stdlib only)
# ---------------------------------------------------------------------------

def http_json(url, payload=None, timeout=300):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def http_multipart(url, filename, content, timeout=1800, extra_fields=None):
    boundary = uuid.uuid4().hex
    body = b""
    for k, v in (extra_fields or {}).items():
        body += (f"--{boundary}\r\nContent-Disposition: form-data; "
                 f'name="{k}"\r\n\r\n{v}\r\n').encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; "
             f'name="file"; filename="{filename}"\r\n'
             f"Content-Type: application/pdf\r\n\r\n").encode()
    body += content + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def stream_chat(url, payload, timeout=600):
    """Streaming chat completion. Returns a dict of timing/token stats.

    Errors (transport, HTTP status, truncated stream, missing usage) are
    returned as {"error": "..."} rather than raised, so a failing request
    under load is a data point instead of a run-killer.
    """
    payload = dict(payload)
    payload["stream"] = True
    payload["stream_options"] = {"include_usage": True}
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"})
    t_start = time.monotonic()
    t_first = None
    t_last = None
    n_events = 0
    content = []
    saw_reasoning = False
    saw_done = False
    finish_reason = None
    usage = {}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                chunk = line[5:].strip()
                if chunk == "[DONE]":
                    saw_done = True
                    break
                d = json.loads(chunk)
                if d.get("usage"):
                    usage = d["usage"]
                for ch in d.get("choices", []):
                    delta = ch.get("delta", {})
                    text = delta.get("content") or ""
                    reasoning = (delta.get("reasoning")
                                 or delta.get("reasoning_content") or "")
                    if text or reasoning:
                        now = time.monotonic()
                        if t_first is None:
                            t_first = now
                        t_last = now
                        n_events += 1
                    if reasoning:
                        saw_reasoning = True
                    if text:
                        content.append(text)
                    if ch.get("finish_reason"):
                        finish_reason = ch["finish_reason"]
    except Exception as e:  # transport error, truncated stream, bad JSON
        return {"error": f"{type(e).__name__}: {e}"}
    if not saw_done or not usage.get("completion_tokens"):
        return {"error": f"incomplete stream (done={saw_done}, usage={bool(usage)})"}
    t_end = time.monotonic()
    return {
        "ttft": (t_first - t_start) if t_first else None,
        "decode_time": (t_last - t_first)
        if (t_first and t_last and t_last > t_first) else None,
        "n_events": n_events,
        "total_time": t_end - t_start,
        "completion_tokens": usage["completion_tokens"],
        "content": "".join(content),
        "saw_reasoning": saw_reasoning,
        "finish_reason": finish_reason,
    }


def percentile_nearest_rank(values, p):
    """Nearest-rank percentile: correct for the small sample sizes here."""
    s = sorted(values)
    return s[max(0, math.ceil(p / 100 * len(s)) - 1)]


# ---------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------

RESULTS = {"meta": {}, "checks": [], "throughput": {}}
PASS = FAIL = 0


def check(name, ok, detail=""):
    global PASS, FAIL
    RESULTS["checks"].append({"name": name, "ok": bool(ok), "detail": str(detail)[:300]})
    if ok:
        PASS += 1
        print(f"  [PASS] {name}" + (f"  ({detail})" if detail else ""))
    else:
        FAIL += 1
        print(f"  [FAIL] {name}  {detail}")


def guarded(name):
    """Decorator: a crash inside a suite section becomes a FAIL check,
    not a run-killer."""
    def wrap(fn):
        def inner(*a, **kw):
            try:
                return fn(*a, **kw)
            except Exception as e:
                check(f"{name} (section crashed)", False, f"{type(e).__name__}: {e}")
                return None
        return inner
    return wrap


def section(title):
    print(f"\n== {title} " + "=" * max(0, 60 - len(title)))


# ---------------------------------------------------------------------------
# LLM correctness suite (temperature 0 + seed for determinism)
# ---------------------------------------------------------------------------

DET = {"temperature": 0, "seed": 0}


@guarded("LLM correctness")
def llm_correctness(args, model):
    url = f"{args.llm_url}/v1/chat/completions"
    q = {"role": "user", "content": "What is 17*23? Reply with only the number."}

    section("LLM correctness: thinking default / reasoning parsing")
    r = http_json(url, {"model": model, "messages": [q], "max_tokens": 512, **DET})
    m = r["choices"][0]["message"]
    reasoning = m.get("reasoning") or m.get("reasoning_content") or ""
    check("thinking OFF by default (no reasoning field)", not reasoning,
          f"content={m.get('content', '')[:30]!r}")
    check("default answer correct", "391" in (m.get("content") or ""))
    check("no <think> leakage in content", "<think>" not in (m.get("content") or ""))

    r = http_json(url, {"model": model, "messages": [q], "max_tokens": 4096, **DET,
                        "chat_template_kwargs": {"enable_thinking": True}})
    m = r["choices"][0]["message"]
    reasoning = m.get("reasoning") or m.get("reasoning_content") or ""
    check("thinking ON via opt-in (reasoning parsed)", len(reasoning) > 0,
          f"{len(reasoning)} reasoning chars")
    check("opt-in answer correct with clean content",
          "391" in (m.get("content") or "") and "<think>" not in (m.get("content") or ""))

    section("LLM correctness: max_tokens enforcement")
    r = http_json(url, {"model": model, "max_tokens": 32, **DET,
                        "messages": [{"role": "user", "content": "Write a long essay about oceans."}]})
    ch = r["choices"][0]
    ct = r["usage"]["completion_tokens"]
    check("max_tokens=32 respected", ct <= 32, f"completion_tokens={ct}")
    check("finish_reason=length when truncated", ch["finish_reason"] == "length",
          ch["finish_reason"])

    section("LLM correctness: tool calling (qwen3_xml parser)")
    tool_msgs = [{"role": "user",
                  "content": "What's the current weather in Moscow, Idaho in celsius? Use the tool."}]
    r = http_json(url, {"model": model, "messages": tool_msgs, "max_tokens": 1024,
                        "tools": [WEATHER_TOOL], **DET})
    ch = r["choices"][0]
    calls = ch["message"].get("tool_calls") or []
    ok_call = bool(calls) and calls[0]["function"]["name"] == "get_current_weather"
    check("tool call emitted and parsed", ok_call,
          f"finish={ch['finish_reason']}, calls={len(calls)}")
    args_ok = False
    if ok_call:
        try:
            parsed = json.loads(calls[0]["function"]["arguments"])
            args_ok = "moscow" in parsed.get("city", "").lower()
        except (ValueError, KeyError):
            pass
    check("tool arguments valid JSON with correct city", args_ok,
          calls[0]["function"]["arguments"][:80] if calls else "n/a")

    if ok_call:
        # Simulated tool round-trip: answer EVERY emitted call, then expect
        # the fed-back result in the final answer.
        followup = tool_msgs + [ch["message"]]
        for i, call in enumerate(calls):
            followup.append({
                "role": "tool", "tool_call_id": call.get("id", f"call_{i}"),
                "content": json.dumps({"city": "Moscow, Idaho", "temperature_c": -3,
                                       "conditions": "light snow"}),
            })
        r2 = http_json(url, {"model": model, "messages": followup,
                             "max_tokens": 512, "tools": [WEATHER_TOOL], **DET})
        final = r2["choices"][0]["message"].get("content") or ""
        check("tool result incorporated in final answer",
              "-3" in final or "snow" in final.lower(), final[:80])
    else:
        check("tool result incorporated in final answer", False, "skipped: no tool call")


# ---------------------------------------------------------------------------
# LLM throughput sweep
# ---------------------------------------------------------------------------

@guarded("LLM throughput")
def llm_throughput(args, model):
    url = f"{args.llm_url}/v1/chat/completions"
    max_tokens = 128 if args.quick else 256
    sweep = args.concurrency
    RESULTS["throughput"]["llm"] = []

    section(f"LLM throughput sweep (streaming, {max_tokens} tokens/req)")
    # Warm-up at the largest sweep size so batch CUDA graphs are captured
    # before the first measured point.
    warm = [{"model": model, "max_tokens": 16, **DET,
             "messages": [{"role": "user", "content": "Say OK."}]}] * max(sweep)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(sweep)) as ex:
        list(ex.map(lambda p: stream_chat(url, p), warm))

    for n in sweep:
        payloads = [{"model": model, "max_tokens": max_tokens, "temperature": 0.7,
                     "seed": 42 + i,
                     "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}]}
                    for i in range(n)]
        t0 = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=n) as ex:
            outs = list(ex.map(lambda p: stream_chat(url, p), payloads))
        wall = time.monotonic() - t0

        good = [o for o in outs if "error" not in o]
        errors = [o["error"] for o in outs if "error" in o]
        toks = [o["completion_tokens"] for o in good]
        ttfts = [o["ttft"] for o in good if o["ttft"]]
        # Fencepost correction: the tokens of the first arrival event were
        # generated before the [t_first, t_last] window opened; scale the
        # numerator by (n_events-1)/n_events to compensate.
        rates = [o["completion_tokens"] * (o["n_events"] - 1) / o["n_events"]
                 / o["decode_time"]
                 for o in good
                 if o["decode_time"] and o["n_events"] and o["n_events"] > 1]
        agg = sum(toks) / wall if toks else 0.0
        row = {
            "concurrency": n,
            "completed": len(good),
            "errors": len(errors),
            "aggregate_tok_s": round(agg, 1),
            "per_stream_tok_s": round(statistics.mean(rates), 1) if rates else None,
            "ttft_mean_ms": round(statistics.mean(ttfts) * 1000) if ttfts else None,
            "ttft_p95_ms": round(percentile_nearest_rank(ttfts, 95) * 1000) if ttfts else None,
            "total_tokens": sum(toks),
            "wall_s": round(wall, 1),
        }
        RESULTS["throughput"]["llm"].append(row)
        err_note = f" | ERRORS {len(errors)}" if errors else ""
        print(f"  c={n:>2}: aggregate {row['aggregate_tok_s']:>7} tok/s | "
              f"per-stream {row['per_stream_tok_s']} tok/s | "
              f"TTFT mean {row['ttft_mean_ms']}ms p95 {row['ttft_p95_ms']}ms{err_note}")
        if errors:
            print(f"        first error: {errors[0][:120]}")
        check(f"sweep c={n} all requests completed", not errors,
              f"{len(good)}/{n} ok")
    rows = RESULTS["throughput"]["llm"]
    if len(rows) > 1:
        check("LLM aggregate throughput scales with concurrency",
              rows[-1]["aggregate_tok_s"] > rows[0]["aggregate_tok_s"] * 1.5)


# ---------------------------------------------------------------------------
# OCR fixtures + throughput
# ---------------------------------------------------------------------------

def fetch_fixtures():
    FIXTURE_DIR.mkdir(exist_ok=True)
    docs = []
    for name, url in PDF_FIXTURES:
        path = FIXTURE_DIR / name
        if not path.exists():
            print(f"  downloading {name} from {url} ...")
            req = urllib.request.Request(url, headers={"User-Agent": "dgx-stack-bench/1.0"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                blob = resp.read()
            # Validate before caching: a rate-limit HTML page must not
            # poison every future run.
            if not blob.startswith(b"%PDF") or len(blob) < 10240:
                raise RuntimeError(
                    f"{url} did not return a PDF ({len(blob)} bytes, "
                    f"starts {blob[:8]!r}) — not caching")
            path.write_bytes(blob)
        docs.append(path)
        print(f"  fixture {name}: {path.stat().st_size // 1024} KB")
    return docs


def ocr_one(args, path, dpi=200):
    t0 = time.monotonic()
    try:
        r = http_multipart(f"{args.ocr_url}/v1/ocr", path.name, path.read_bytes(),
                           extra_fields={"dpi": str(dpi)})
    except Exception as e:
        return {"doc": path.name, "error": f"{type(e).__name__}: {e}",
                "seconds": round(time.monotonic() - t0, 1)}
    dt = time.monotonic() - t0
    return {"doc": path.name, "seconds": round(dt, 1), "pages": r.get("pages"),
            "chars": len(r.get("content", "")), "usage": r.get("usage", {}),
            "content": r.get("content", "")}


@guarded("OCR suite")
def ocr_suite(args):
    section("OCR: single-document latency (test-doc.pdf)")
    # Unrecorded warm-up so the canonical latency number is not the OCR
    # path's cold first request.
    ocr_one(args, TEST_DOC, dpi=80)
    r = ocr_one(args, TEST_DOC)
    ok = "error" not in r and r["pages"] == 3 and "END-OF-TEST-DOCUMENT" in r["content"]
    check("test-doc processed (3 pages, sentinel intact)", ok,
          r.get("error") or f"{r['seconds']}s, {r['chars']} chars")
    RESULTS["throughput"]["ocr_single"] = {k: v for k, v in r.items() if k != "content"}

    if args.quick:
        return

    section("OCR fixtures")
    docs = fetch_fixtures()

    section("OCR: concurrent real-document throughput")
    # Similar-size real documents only — mixing the 3-page synthetic doc in
    # would pad pages/min with a straggler-bound wall clock.
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(docs)) as ex:
        outs = list(ex.map(lambda p: ocr_one(args, p), docs))
    wall = time.monotonic() - t0
    good = [o for o in outs if "error" not in o]
    pages = sum(o["pages"] or 0 for o in good)
    out_tokens = sum(o["usage"].get("completion_tokens", 0) for o in good)
    RESULTS["throughput"]["ocr_concurrent"] = {
        "documents": [{k: v for k, v in o.items() if k != "content"} for o in outs],
        "total_pages": pages,
        "wall_s": round(wall, 1),
        "pages_per_min": round(pages / wall * 60, 1) if wall else None,
        "ocr_output_tok_s": round(out_tokens / wall, 1) if wall else None,
    }
    for o in outs:
        if "error" in o:
            print(f"  {o['doc']:>16}: ERROR {o['error'][:100]}")
        else:
            print(f"  {o['doc']:>16}: {o['pages']} pages in {o['seconds']}s, {o['chars']} chars")
    print(f"  TOTAL: {pages} pages in {round(wall, 1)}s = "
          f"{RESULTS['throughput']['ocr_concurrent']['pages_per_min']} pages/min "
          f"({RESULTS['throughput']['ocr_concurrent']['ocr_output_tok_s']} out tok/s)")
    check("concurrent OCR: all documents completed", len(good) == len(outs),
          f"{len(good)}/{len(outs)}")

    expects = {"attention.pdf": "attention", "bert.pdf": "bert"}
    for o in good:
        want = expects.get(o["doc"])
        if want:
            check(f"OCR content sanity: {o['doc']}",
                  want in o["content"].lower() and o["chars"] > 5000,
                  f"{o['chars']} chars")


# ---------------------------------------------------------------------------
# Mixed load
# ---------------------------------------------------------------------------

@guarded("Mixed load")
def mixed_load(args, model):
    section("Mixed load: chat + thinking + tools + OCR simultaneously")
    url = f"{args.llm_url}/v1/chat/completions"

    def chat_job(i, thinking):
        p = {"model": model, "max_tokens": 128 if args.quick else 256,
             "temperature": 0.7, "seed": 100 + i,
             "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}]}
        if thinking:
            p["chat_template_kwargs"] = {"enable_thinking": True}
            p["max_tokens"] = 1024
        return ("chat_think" if thinking else "chat", stream_chat(url, p))

    def tool_job(i):
        try:
            r = http_json(url, {"model": model, "max_tokens": 512, **DET,
                                "messages": [{"role": "user",
                                              "content": "Weather in Boise in celsius? Use the tool."}],
                                "tools": [WEATHER_TOOL]})
            return ("tool", {"ok": bool(r["choices"][0]["message"].get("tool_calls"))})
        except Exception as e:
            return ("tool", {"ok": False, "error": str(e)})

    def ocr_job():
        return ("ocr", ocr_one(args, TEST_DOC))

    jobs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:
        t0 = time.monotonic()
        futs = ([ex.submit(chat_job, i, False) for i in range(4)]
                + [ex.submit(chat_job, i, True) for i in range(2)]
                + [ex.submit(tool_job, i) for i in range(2)]
                + [ex.submit(ocr_job)])
        for f in futs:
            jobs.append(f.result())
        wall = time.monotonic() - t0

    kinds = {}
    for kind, out in jobs:
        kinds.setdefault(kind, []).append(out)

    def summarize(outs, ok_fn):
        errs = [o.get("error") or "check failed" for o in outs if not ok_fn(o)]
        return (not errs), (errs[0][:150] if errs else "")

    chat_ok, chat_err = summarize(
        kinds.get("chat", []), lambda o: "error" not in o and o["completion_tokens"] > 0)
    think_ok, think_err = summarize(
        kinds.get("chat_think", []), lambda o: "error" not in o and o["saw_reasoning"])
    tools_ok, tool_err = summarize(kinds.get("tool", []), lambda o: o["ok"])
    ocr_ok, ocr_err = summarize(
        kinds.get("ocr", []), lambda o: "error" not in o and o["pages"] == 3)
    check("mixed: 4x plain chat completed", chat_ok, chat_err)
    check("mixed: 2x thinking chat produced reasoning", think_ok, think_err)
    check("mixed: 2x tool calls parsed", tools_ok, tool_err)
    check("mixed: OCR document completed under load", ocr_ok, ocr_err)
    RESULTS["throughput"]["mixed_wall_s"] = round(wall, 1)
    print(f"  mixed batch wall time: {round(wall, 1)}s")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def preflight(args):
    """Probe only the services this run will actually use."""
    llm_model = mocr_model = None
    try:
        if not args.skip_llm:
            llm_model = http_json(f"{args.llm_url}/v1/models", timeout=10)["data"][0]["id"]
        if not args.skip_ocr:
            mocr_model = http_json(f"{args.mocr_url}/v1/models", timeout=10)["data"][0]["id"]
            health = http_json(f"{args.ocr_url}/health", timeout=10)
            if health.get("status") != "ok":
                raise RuntimeError(f"OCR service unhealthy: {health}")
    except Exception as e:
        print(f"Preflight failed — stack not reachable: {e}", file=sys.stderr)
        sys.exit(2)
    if llm_model:
        print(f"  LLM: {llm_model} @ {args.llm_url}")
    if mocr_model:
        print(f"  OCR model: {mocr_model} @ {args.mocr_url} (service @ {args.ocr_url})")
    return llm_model, mocr_model


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--llm-url", default="http://localhost:8000")
    ap.add_argument("--mocr-url", default="http://localhost:8001")
    ap.add_argument("--ocr-url", default="http://localhost:8010")
    ap.add_argument("--concurrency", default=None,
                    help="comma-separated LLM concurrency sweep "
                         "(default 1,4,8,12; 1,4 with --quick)")
    ap.add_argument("--quick", action="store_true", help="reduced run (~3 min)")
    ap.add_argument("--skip-ocr", action="store_true")
    ap.add_argument("--skip-llm", action="store_true")
    ap.add_argument("--output", default=None, help="results JSON path")
    args = ap.parse_args()
    if args.concurrency:
        # An explicit sweep is always honored, --quick or not.
        args.concurrency = [int(x) for x in args.concurrency.split(",") if x.strip()]
    else:
        args.concurrency = [1, 4] if args.quick else [1, 4, 8, 12]

    section("Preflight")
    llm_model, mocr_model = preflight(args)
    RESULTS["meta"] = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "llm_model": llm_model, "mocr_model": mocr_model,
        "quick": args.quick, "concurrency": args.concurrency,
    }

    out = Path(args.output) if args.output else \
        BENCH_DIR / f"results-{time.strftime('%Y%m%d-%H%M%S')}.json"
    t_start = time.monotonic()
    exit_code = 3
    try:
        if not args.skip_llm:
            llm_correctness(args, llm_model)
            llm_throughput(args, llm_model)
        if not args.skip_ocr:
            ocr_suite(args)
        if not (args.skip_llm or args.skip_ocr):
            mixed_load(args, llm_model)
        exit_code = 1 if FAIL else 0
    finally:
        RESULTS["meta"]["total_runtime_s"] = round(time.monotonic() - t_start, 1)
        section("Summary")
        print(f"  {PASS} passed, {FAIL} failed | runtime {RESULTS['meta']['total_runtime_s']}s")
        for row in RESULTS["throughput"].get("llm", []):
            print(f"  LLM  c={row['concurrency']:>2}: {row['aggregate_tok_s']} tok/s aggregate, "
                  f"{row['per_stream_tok_s']} tok/s/stream, TTFT {row['ttft_mean_ms']}ms"
                  + (f" [{row['errors']} errors]" if row["errors"] else ""))
        occ = RESULTS["throughput"].get("ocr_concurrent")
        if occ:
            print(f"  OCR  {occ['total_pages']} pages @ {occ['pages_per_min']} pages/min")
        out.write_text(json.dumps(RESULTS, indent=1))
        print(f"  results written to {out}")
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
