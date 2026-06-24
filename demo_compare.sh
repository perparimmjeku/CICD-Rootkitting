#!/bin/bash
# demo_compare.sh — CI/CD Rootkit Lab full live demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEAN_BIN="$SCRIPT_DIR/build_clean/server"
BAD_BIN="$SCRIPT_DIR/build_compromised/server"

# Ensure ports are free
kill $(lsof -ti:8080 2>/dev/null) 2>/dev/null || true
kill $(lsof -ti:8081 2>/dev/null) 2>/dev/null || true
sleep 0.5

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  CI/CD ROOTKIT LAB — LIVE DEMO                                 ║"
echo '║  "When the Build System Betrays You"                            ║'
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
sleep 1

# ── PHASE 1: SOURCE CODE REVIEW ───────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 1 — SOURCE CODE REVIEW (what the PR reviewer sees)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  Files committed to main:"
cd "$SCRIPT_DIR/clean_app"
git ls-files | sed 's/^/    /'
echo ""

echo "  Searching source for backdoor strings..."
if grep -rq "__backdoor__" --include="*.go" --exclude="*_test.go" .; then
    echo "  ✗ FOUND — source is dirty"
    exit 1
else
    echo "  ✓ CLEAN — no backdoor strings in source"
fi
echo ""

echo "  Git history:"
git log --oneline 2>/dev/null | head -5 | sed 's/^/    /'
echo ""
GIT_STATUS=$(git status --short 2>/dev/null)
if [ -z "$GIT_STATUS" ]; then
    echo "  Git status: ✓ CLEAN — no uncommitted changes"
fi
echo ""
sleep 1

# ── PHASE 2: CI PIPELINE VIEW ─────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 2 — CI PIPELINE (clean_app/.github/workflows/build.yml)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  (the app's own pipeline — view it: cat clean_app/.github/workflows/build.yml)"
echo ""
echo "  jobs:"
echo "    security-scan:"
echo "      - actions/checkout@v4"
echo "      - SAST scan on source         → scanning main.go..."
sleep 0.5

# Simulate SAST — scans only source files
if grep -q "__backdoor__" "$SCRIPT_DIR/clean_app/main.go" 2>/dev/null; then
    echo "      ✗ SAST FAILED — backdoor found in source"
    exit 1
else
    echo "      ✓ SAST PASSED — no issues found"
fi

echo "      - Dependency scan (go.sum)    → ✓ PASSED"
echo ""
echo "    build:"
echo "      - needs: security-scan        → ✓ PASSED"
echo "      - container: company/go-builder:latest   ← trusted image"
echo "      - go build -o server ."
sleep 0.5
echo "      - upload-artifact: server-binary"
echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  Pipeline status: ✓ ALL CHECKS PASSED        │"
echo "  │  Artifact signed and uploaded.                │"
echo "  └──────────────────────────────────────────────┘"
echo ""
sleep 1

# ── PHASE 3: BINARY COMPARISON ────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 3 — THE PARADOX: SAME SOURCE, DIFFERENT BINARY"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

CLEAN_HASH=$(sha256sum "$CLEAN_BIN" | cut -d' ' -f1)
BAD_HASH=$(sha256sum "$BAD_BIN" | cut -d' ' -f1)

echo "  Build A — golang:1.22-alpine (official image):"
echo "    SHA256: $CLEAN_HASH"
echo ""
echo "  Build B — company/go-builder:latest (trusted CI image):"
echo "    SHA256: $BAD_HASH"
echo ""

if [ "$CLEAN_HASH" != "$BAD_HASH" ]; then
    echo "  ⚠  BINARIES ARE DIFFERENT"
    echo "     Source code:  IDENTICAL in both builds"
    echo "     Git commit:   IDENTICAL in both builds"
    echo "     SAST result:  PASSED in both builds"
    echo "     Binary hash:  DIFFERENT"
    echo ""
    echo "  The difference came from the build environment — not the code."
else
    echo "  ✗ Binaries are identical — injection did not work. Re-run setup.sh"
    exit 1
fi
echo ""
sleep 1

# ── PHASE 4: START BOTH SERVERS ───────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 4 — LIVE SIDE-BY-SIDE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  Starting both servers..."
export PORT=8080; "$CLEAN_BIN" &
CLEAN_PID=$!
# LAB_ALLOW_RCE=1 opts in to live command execution for this controlled,
# loopback-only demo (the backdoor is a dry-run unless this is set).
export PORT=8081 LAB_ALLOW_RCE=1; "$BAD_BIN" &
BAD_PID=$!
sleep 1

echo "  Clean server       → http://localhost:8080  (PID $CLEAN_PID)"
echo "  Compromised server → http://localhost:8081  (PID $BAD_PID)"
echo ""
echo "  Open both in browser — they look IDENTICAL."
echo ""
sleep 2

# ── PHASE 5: TRIGGER THE BACKDOOR ─────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 5 — TRIGGER THE BACKDOOR"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "  [CLEAN] curl http://localhost:8080/__backdoor__"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/__backdoor__ || echo "ERR")
echo "  → HTTP $HTTP_CODE  (404 — endpoint does not exist)"
echo ""

echo "  [BACKDOORED] curl -H 'X-Backdoor-Token: secret' \\"
echo "               http://localhost:8081/__backdoor__"
RESULT=$(curl -s -H 'X-Backdoor-Token: secret' http://localhost:8081/__backdoor__ || echo '{"error":"failed"}')
echo "  → $RESULT"
echo ""

echo "  [RCE] curl -H 'X-Backdoor-Token: secret' \\"
echo "        'http://localhost:8081/__backdoor__?cmd=id'"
RCE=$(curl -s -H 'X-Backdoor-Token: secret' 'http://localhost:8081/__backdoor__?cmd=id' || echo "failed")
echo "  → $RCE"
echo ""
sleep 1

# ── PHASE 6: THE REVEAL ───────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 6 — THE REVEAL: What's inside company/go-builder:latest"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  Extracting /usr/local/go/bin/go from the image..."
WRAPPER=$(docker run --rm --entrypoint cat company/go-builder:latest /usr/local/go/bin/go 2>/dev/null || echo "(failed to read)")
echo ""
echo "  ─── /usr/local/go/bin/go (the 'go' binary) ────────────────────"
echo "$WRAPPER" | sed 's/^/  │  /'
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  The developer sees:  golang:1.22-alpine — official base image"
echo "  The pipeline uses:   company/go-builder:latest — 'enterprise' image"
echo "  What's inside:       a shell script wrapping the real go binary"
echo ""
echo "  No source file was modified. No CI YAML was changed."
echo "  The compromise lived entirely inside the runner image."
echo ""

# ── PHASE 7: DEFENCES ─────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 7 — HOW TO DETECT & PREVENT THIS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  DETECTION"
echo "    • Reproducible builds + binary hash comparison (caught it here)"
echo "    • SLSA L3 provenance — platform-generated, not script-generated"
echo "    • Scan builder images: trivy image company/go-builder:latest"
echo "    • Runtime syscall tracing: Falco, Tracee, tetragon"
echo "    • Binary SCA post-build: syft + grype on the artifact"
echo ""
echo "  PREVENTION"
echo "    • Pin images to digest, never a mutable tag:"
echo "        image: golang@sha256:1699c10..."
echo "    • Verify image signatures before use (cosign verify)"
echo "    • Ephemeral runners — no persistence between jobs"
echo "    • Build inside a read-only rootfs (no cp to source dir possible)"
echo "    • SLSA L3+ enforced at artifact ingestion"
echo ""

# ── CLEANUP ───────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  Press Ctrl+C to stop servers and end demo"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cleanup() {
    echo ""
    echo "Stopping servers..."
    kill "$CLEAN_PID" "$BAD_PID" 2>/dev/null || true
    echo "Demo complete."
}
trap cleanup EXIT INT TERM

wait "$CLEAN_PID" "$BAD_PID" 2>/dev/null || true
