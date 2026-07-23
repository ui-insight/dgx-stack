#!/usr/bin/env bash
set -euo pipefail
# ───────────────────────────────────────────────────────────────────────────
# Vendor MindRouter's dashboard CDN assets locally, for air-gapped operation.
#
# MindRouter's dashboard templates load JS/CSS/fonts from cdn.jsdelivr.net.
# Those load in the *browser*, so a client with no internet (e.g. on the DGX's
# own hotspot) gets a broken dashboard. This downloads every referenced asset
# — and the fonts its CSS pulls — into the dashboard's own /static/vendor/
# directory, then repoints the templates at the local copies.
#
# The path under /static/vendor mirrors the jsdelivr path exactly, so the
# template patch is one uniform replacement AND the relative url(fonts/...)
# refs inside katex/bootstrap-icons CSS resolve against the local copies.
#
# Runs once during install while the box still has internet (like the model
# download); after that the dashboard is fully self-contained. Idempotent:
# already-downloaded assets are skipped and already-patched templates are a
# no-op. Called automatically by install-mindrouter.sh; safe to run by hand
# after a MindRouter update reverts the templates.
#
# Usage:  ./vendor-assets.sh [MINDROUTER_DIR]      (default ~/mindrouter)
# ───────────────────────────────────────────────────────────────────────────
MRDIR="${1:-$HOME/mindrouter}"
TPL="$MRDIR/backend/app/dashboard/templates"
VENDOR="$MRDIR/backend/app/dashboard/static/vendor"
CDN="https://cdn.jsdelivr.net/npm"
[[ -d "$TPL" ]] || { echo "[vendor] templates not found at $TPL" >&2; exit 1; }
mkdir -p "$VENDOR"

dl() {  # dl URL LOCALPATH — skip if already present (offline-friendly re-runs)
  [[ -s "$2" ]] && return 0
  mkdir -p "$(dirname "$2")"
  curl -sfL --max-time 60 "$1" -o "$2" || { echo "[vendor]   FAILED: $1" >&2; return 1; }
}

# Helper: print the (normalized, relative) url(...) asset refs inside a CSS file.
CSSREFS="$(mktemp)"; trap 'rm -f "$CSSREFS"' EXIT
cat > "$CSSREFS" <<'PY'
import re, os, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for m in re.finditer(r'url\(\s*["\']?([^"\')]+)', txt):
    ref = m.group(1).split('?')[0].strip()
    if not ref or ref.startswith(('data:', 'http')):
        continue
    print(os.path.normpath(os.path.join(sys.argv[2], ref)))
PY

# The template-referenced CDN URLs. On a fresh checkout the templates still
# point at the CDN; if they were already patched this list is empty and the
# script no-ops.
mapfile -t urls < <(grep -rhoE "https://cdn\.jsdelivr\.net/npm/[^\"')( ]+" "$TPL" | sort -u)
if [[ ${#urls[@]} -eq 0 ]]; then
  echo "[vendor] templates already reference local assets — nothing to do."
  exit 0
fi
echo "[vendor] vendoring ${#urls[@]} CDN assets into $VENDOR ..."

for u in "${urls[@]}"; do
  rel="${u#"$CDN"/}"
  dl "$u" "$VENDOR/$rel" || continue
  [[ "$rel" == *.css ]] || continue
  cssdir="$(dirname "$rel")"
  while read -r target; do
    [[ -z "$target" ]] && continue
    dl "$CDN/$target" "$VENDOR/$target" || true
  done < <(python3 "$CSSREFS" "$VENDOR/$rel" "$cssdir" | sort -u)
done

# Repoint templates at the local copies (one uniform replacement).
mapfile -t patched < <(grep -rl "cdn.jsdelivr.net/npm" "$TPL")
for f in "${patched[@]}"; do
  sed -i "s#https://cdn\.jsdelivr\.net/npm/#/static/vendor/#g" "$f"
done
echo "[vendor] vendored $(find "$VENDOR" -type f | wc -l | tr -d ' ') files; patched ${#patched[@]} templates."
