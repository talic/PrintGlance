#!/bin/bash
# Proves PrintGlance's SwiftUI screens with swift test. Never opens the menu bar app:
# that copy talks to real printers, and only one copy can run.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EVIDENCE_ROOT="${PG_VERIFY_EVIDENCE:-/tmp/printglance-verify-evidence}"
RUNS_ROOT="${PG_VERIFY_RUNS:-/tmp/printglance-verify-runs}"
RUN_ID="${PG_VERIFY_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
EVIDENCE="$EVIDENCE_ROOT/$RUN_ID"
PIDFILE="$RUNS_ROOT/$RUN_ID.pid"
XCODE_DEV="/Applications/Xcode.app/Contents/Developer"

mkdir -p "$EVIDENCE" "$RUNS_ROOT"

if [[ -d "$XCODE_DEV" ]]; then
  export DEVELOPER_DIR="$XCODE_DEV"
fi

doctor() {
  local pid=""
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  fi
  {
    echo "run_id=$RUN_ID"
    echo "evidence=$EVIDENCE"
    echo "root=$ROOT"
    uname -srm
    if command -v swift >/dev/null 2>&1; then
      swift --version
    else
      echo "swift: not on PATH"
    fi
    echo "DEVELOPER_DIR=${DEVELOPER_DIR:-unset}"
    if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
      echo "developer_dir=present"
    else
      echo "developer_dir=missing"
    fi
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "drive_pid=$pid still running"
    elif [[ -n "$pid" ]]; then
      echo "drive_pid=not running"
    else
      echo "drive_pid=none"
    fi
  } | tee "$EVIDENCE/doctor.txt"

  if ! command -v swift >/dev/null 2>&1; then
    echo "doctor: swift is not installed. Stop. Do not open PrintGlance.app." | tee -a "$EVIDENCE/doctor.txt"
    return 1
  fi
  if [[ ! -d "${DEVELOPER_DIR:-}" ]]; then
    echo "doctor: DEVELOPER_DIR is not Xcode. Stop. Do not open PrintGlance.app." | tee -a "$EVIDENCE/doctor.txt"
    return 1
  fi
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "doctor: drive pid $pid is still running. Wait, or run cleanup for this run id." | tee -a "$EVIDENCE/doctor.txt"
      return 1
    fi
  fi
  echo "doctor: ok" | tee -a "$EVIDENCE/doctor.txt"
  return 0
}

run_filter() {
  local name="$1"
  local filter="$2"
  local log="$EVIDENCE/${name}.log"
  echo "command=DEVELOPER_DIR=${DEVELOPER_DIR:-} swift test --filter $filter" | tee "$log"
  (
    cd "$ROOT"
    swift test --filter "$filter"
  ) >>"$log" 2>&1 &
  local pid=$!
  echo "$pid" >"$PIDFILE"
  local status=0
  wait "$pid" || status=$?
  rm -f "$PIDFILE"
  echo "exit=$status" | tee -a "$log"
  return "$status"
}

drive() {
  local feature="${1:-}"
  doctor || return $?
  case "$feature" in
    watch-a-print)
      export PG_RENDER_DIR="$EVIDENCE/renders"
      mkdir -p "$PG_RENDER_DIR"
      run_filter "drive" 'CardScreenTests/testPrinting$' || return $?
      run_filter "render" 'RenderStatesTests/testRenderPrinterDetail' || return $?
      local light="$PG_RENDER_DIR/detail-printing-light.png"
      local dark="$PG_RENDER_DIR/detail-printing-dark.png"
      if [[ ! -f "$light" || ! -f "$dark" ]]; then
        echo "drive: missing $light or $dark" | tee -a "$EVIDENCE/drive.log"
        return 1
      fi
      echo "proof=$light" | tee -a "$EVIDENCE/drive.log"
      echo "proof=$dark" | tee -a "$EVIDENCE/drive.log"
      ;;
    why-it-stopped)
      run_filter "drive" 'CardScreenTests/testPausedSaysWhyAndOffersTheLookup|CardScreenTests/testFailed$' || return $?
      ;;
    several-printers)
      run_filter "drive" 'PanelScreenTests/testPrintingCardWithTheListAndSwitchingPrinters' || return $?
      ;;
    history)
      run_filter "drive" 'PanelScreenTests/testEmptyHistory|PanelScreenTests/testHistoryRowsSayHowEachPrintEnded' || return $?
      ;;
    add-a-printer)
      run_filter "drive" 'SetupScreenTests/testFoundPrintersArePickedAndAddedOnesAreNot|SetupScreenTests/testTypingTheAccessCodeEnablesConnectAndHintsAtItsLength|SetupScreenTests/testConnectingWelcomesAfterThePrinterAnswers' || return $?
      ;;
    *)
      echo "drive: unknown feature '$feature'. Use watch-a-print, why-it-stopped, several-printers, history, or add-a-printer." >&2
      return 2
      ;;
  esac
  echo "evidence=$EVIDENCE"
}

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  echo "cleanup: stopped this run's swift test if it was still alive"
  echo "cleanup: left evidence at $EVIDENCE"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  doctor) doctor ;;
  drive) drive "$@" ;;
  cleanup) cleanup ;;
  *)
    echo "usage: verify-printglance.sh doctor|drive <feature>|cleanup" >&2
    exit 2
    ;;
esac
