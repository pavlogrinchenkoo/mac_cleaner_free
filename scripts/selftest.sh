#!/bin/bash
# Run → log → review, without a single click.
# Builds the app, runs it without a window, does a DRY RUN (deletes nothing),
# checks its own behavior on this Mac's real data and shows a summary of the diagnostic file.
#
# Usage: scripts/selftest.sh [--no-build] [--open]
#   --no-build  do not rebuild (use the current build/Cleaner.app)
#   --open      open the diagnostic file in a text editor
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --open) OPEN=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ "$BUILD" = 1 ]; then
    echo "▶ Building the app…"
    scripts/build-app.sh debug >/dev/null
fi

OUT="$(mktemp -t cleaner-selftest)"
echo "▶ Running Cleaner without a window (dry run; may take a few minutes)…"
echo
set +e
CLEANER_LANGUAGE=en build/Cleaner.app/Contents/MacOS/Cleaner --selftest 2>/dev/null | tee "$OUT"
STATUS=${PIPESTATUS[0]}
set -e

LOG="$(grep '^LOG: ' "$OUT" | head -1 | sed 's/^LOG: //')"
rm -f "$OUT"

if [ -n "${LOG:-}" ] && [ -f "$LOG" ]; then
    echo
    echo "════════ DIAGNOSTIC FILE REVIEW ════════"
    echo "File: $LOG"
    echo
    sed -n '/^== SUMMARY ==/,/^== FOUND/p' "$LOG" | sed '$d'
    echo
    echo "── Selected automatically (by rules) ──"
    # No line truncation: multibyte characters (e.g. Cyrillic) must not be cut at byte boundaries.
    { awk '
        /^[^ \[#=].* \[[a-zA-Z0-9_.]+\] — / { rule=$0 }
        /^  \[✓ auto\] [0-9]/ { n[rule]++ }
        END { for (r in n) printf "%4d  %s\n", n[r], r }' "$LOG" | LC_ALL=C sort -rn; } || true
    echo
    echo "── Locked (cannot be selected right now), first 12 ──"
    { grep -E '^  \[🔒\] [0-9]' "$LOG" | head -12; } || true
    echo
    echo "── Warnings and anomalies ──"
    { grep -E '^ *⚠︎|^  \[✓ \?\?\?\] [0-9]' "$LOG" | head -10; } || true
    if [ "$OPEN" = 1 ]; then open -t "$LOG"; fi
fi

exit "$STATUS"
