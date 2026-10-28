#!/bin/bash
# Запуск → лог → перегляд, без жодних кліків.
# Збирає застосунок, запускає його без вікна, робить ПРОБНИЙ запуск (нічого не видаляє),
# перевіряє власну поведінку на реальних даних цього Mac і показує підсумок діагностичного файлу.
#
# Використання: scripts/selftest.sh [--no-build] [--open]
#   --no-build  не перезбирати (використати поточний build/Cleaner.app)
#   --open      відкрити діагностичний файл у текстовому редакторі
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --open) OPEN=1 ;;
        *) echo "Невідомий аргумент: $arg" >&2; exit 2 ;;
    esac
done

if [ "$BUILD" = 1 ]; then
    echo "▶ Збираю застосунок…"
    scripts/build-app.sh debug >/dev/null
fi

OUT="$(mktemp -t cleaner-selftest)"
echo "▶ Запускаю Cleaner без вікна (пробний запуск; може тривати кілька хвилин)…"
echo
set +e
build/Cleaner.app/Contents/MacOS/Cleaner --selftest 2>/dev/null | tee "$OUT"
STATUS=${PIPESTATUS[0]}
set -e

LOG="$(grep '^ЛОГ: ' "$OUT" | head -1 | sed 's/^ЛОГ: //')"
rm -f "$OUT"

if [ -n "${LOG:-}" ] && [ -f "$LOG" ]; then
    echo
    echo "════════ ПЕРЕГЛЯД ДІАГНОСТИЧНОГО ФАЙЛУ ════════"
    echo "Файл: $LOG"
    echo
    sed -n '/^== ПІДСУМОК ==/,/^== ЗНАЙДЕНЕ/p' "$LOG" | sed '$d'
    echo
    echo "── Що вибрано автоматично (по правилах) ──"
    # Без обрізання рядків: у кирилиці багатобайтові символи не можна різати за байтами.
    { awk '
        /^[^ \[#=].* \[[a-zA-Z0-9_.]+\] — / { rule=$0 }
        /^  \[✓ авто\] [0-9]/ { n[rule]++ }
        END { for (r in n) printf "%4d  %s\n", n[r], r }' "$LOG" | LC_ALL=C sort -rn; } || true
    echo
    echo "── Заблоковано (зараз не можна вибрати), перші 12 ──"
    { grep -E '^  \[🔒\] [0-9]' "$LOG" | head -12; } || true
    echo
    echo "── Попередження й аномалії ──"
    { grep -E '^ *⚠︎|^  \[✓ \?\?\?\] [0-9]' "$LOG" | head -10; } || true
    if [ "$OPEN" = 1 ]; then open -t "$LOG"; fi
fi

exit "$STATUS"
