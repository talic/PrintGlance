#!/bin/bash
# LaunchAgent entry for print_loop.py. Sources .env next to this script.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="$ROOT/.venv/bin/python"
cd "$ROOT"
if [[ ! -x "$PY" ]]; then
  echo "print_loop: missing $PY" >&2
  exit 1
fi
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
exec "$PY" "$ROOT/print_loop.py"
