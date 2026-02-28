#!/bin/bash
# =============================================================================
# MT5 Backtest Runner — runs inside the Docker container via docker exec
#
# Usage:
#   backtest.sh --ea FibonacciGoldenZone [options]
#
# Options:
#   --ea NAME         EA name (required, without .ex5 extension)
#   --symbol SYM      Symbol to test (default: "Volatility 10 (1s) Index")
#   --period TF       Timeframe: M1,M5,M15,M30,H1,H4,D1,W1,MN (default: H1)
#   --from DATE       Start date YYYY.MM.DD (default: 3 months ago)
#   --to DATE         End date YYYY.MM.DD (default: today)
#   --deposit AMT     Initial deposit (default: 10000)
#   --model NUM       Tick model: 0=Every tick, 1=1min OHLC, 2=Open price (default: 0)
#   --format FMT      Output: text, json, csv (default: text)
#   --no-restart      Don't restart MT5 for live trading after backtest
# =============================================================================
set -e

# --- Helper functions ---
# Only output status messages to stderr so stdout is clean for json/csv
log() { echo "$@" >&2; }

# Ensure lock file is always cleaned up
cleanup_lock() {
    rm -f /tmp/backtest-running
}
trap cleanup_lock EXIT

restart_mt5() {
    local MT5_ARGS="/portable"
    if [ -n "$MT5_LOGIN" ] && [ -n "$MT5_SERVER" ]; then
        MT5_ARGS="${MT5_ARGS} /login:${MT5_LOGIN} /password:${MT5_PASSWORD} /server:${MT5_SERVER}"
    fi
    cd "${MT5_DIR}"
    wine "${MT5_DIR}/terminal64.exe" ${MT5_ARGS} 2>/dev/null &
    disown
    log "MT5 restarted for live trading (PID: $!)"
}

# --- Defaults ---
EA_NAME=""
SYMBOL="Volatility 10 (1s) Index"
PERIOD="H1"
FROM_DATE=""
TO_DATE=""
DEPOSIT="10000"
MODEL="0"
OUTPUT_FORMAT="text"
RESTART_MT5=true

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ea)       EA_NAME="$2"; shift 2 ;;
        --symbol)   SYMBOL="$2"; shift 2 ;;
        --period)   PERIOD="$2"; shift 2 ;;
        --from)     FROM_DATE="$2"; shift 2 ;;
        --to)       TO_DATE="$2"; shift 2 ;;
        --deposit)  DEPOSIT="$2"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        --format)   OUTPUT_FORMAT="$2"; shift 2 ;;
        --no-restart) RESTART_MT5=false; shift ;;
        --help|-h)
            head -20 "$0" | grep -E '^\s*#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Validate ---
if [ -z "$EA_NAME" ]; then
    echo "ERROR: --ea is required. Example: --ea FibonacciGoldenZone" >&2
    exit 1
fi

# Strip extensions if provided
EA_NAME="${EA_NAME%.mq5}"
EA_NAME="${EA_NAME%.ex5}"

# Calculate default dates if not provided
if [ -z "$FROM_DATE" ]; then
    FROM_DATE=$(date -d "-3 months" +%Y.%m.%d 2>/dev/null || date -v-3m +%Y.%m.%d 2>/dev/null || echo "2025.12.01")
fi
if [ -z "$TO_DATE" ]; then
    TO_DATE=$(date +%Y.%m.%d)
fi

# --- Locate MT5 ---
MT5_PATH_FILE="${WINEPREFIX}/.mt5-path"
if [ -f "$MT5_PATH_FILE" ]; then
    MT5_DIR=$(cat "$MT5_PATH_FILE")
else
    MT5_EXE=$(find "${WINEPREFIX}" -name "terminal64.exe" -print -quit 2>/dev/null)
    if [ -n "$MT5_EXE" ]; then
        MT5_DIR=$(dirname "$MT5_EXE")
    fi
fi

if [ -z "$MT5_DIR" ] || [ ! -f "${MT5_DIR}/terminal64.exe" ]; then
    echo "ERROR: MT5 not found. Is it installed?" >&2
    exit 1
fi

# --- Sync EA files ---
EA_MOUNT="/mnt/experts"
EA_DEST="${MT5_DIR}/MQL5/Experts"
mkdir -p "$EA_DEST"

if [ -d "$EA_MOUNT" ]; then
    cp -f ${EA_MOUNT}/*.mq5 "$EA_DEST/" 2>/dev/null || true
    cp -f ${EA_MOUNT}/*.ex5 "$EA_DEST/" 2>/dev/null || true
fi

# Check EA exists (either .ex5 compiled or .mq5 source)
if [ ! -f "${EA_DEST}/${EA_NAME}.ex5" ] && [ ! -f "${EA_DEST}/${EA_NAME}.mq5" ]; then
    echo "ERROR: EA '${EA_NAME}' not found in ${EA_DEST}/" >&2
    echo "Available EAs:" >&2
    ls -1 "${EA_DEST}/"*.mq5 "${EA_DEST}/"*.ex5 2>/dev/null | xargs -I{} basename {} >&2 || echo "  (none)" >&2
    exit 1
fi

# --- Map timeframe to MT5 period constant ---
case "$PERIOD" in
    M1)  PERIOD_NUM="1" ;;
    M5)  PERIOD_NUM="5" ;;
    M15) PERIOD_NUM="15" ;;
    M30) PERIOD_NUM="30" ;;
    H1)  PERIOD_NUM="16385" ;;
    H4)  PERIOD_NUM="16388" ;;
    D1)  PERIOD_NUM="16408" ;;
    W1)  PERIOD_NUM="32769" ;;
    MN)  PERIOD_NUM="49153" ;;
    *)   PERIOD_NUM="16385" ;;  # default H1
esac

# --- Generate backtest INI ---
REPORT_NAME="backtest-report"
REPORT_DIR="${MT5_DIR}"
# Use /tmp to avoid spaces in path (Wine quoting issues with "Program Files")
INI_FILE="/tmp/backtest-auto.ini"

cat > "$INI_FILE" << EOF
[Common]
Login=${MT5_LOGIN:-0}
Password=${MT5_PASSWORD:-}
Server=${MT5_SERVER:-}
KeepPrivate=1
NewsEnable=0
CertInstall=1

[Experts]
AllowLiveTrading=0
AllowDllImport=0
Enabled=1
Account=${MT5_LOGIN:-0}
Profile=Default

[Tester]
Expert=${EA_NAME}
Symbol=${SYMBOL}
Period=${PERIOD}
Model=${MODEL}
Optimization=0
FromDate=${FROM_DATE}
ToDate=${TO_DATE}
ForwardMode=0
Deposit=${DEPOSIT}
Currency=USD
ProfitInPips=0
Leverage=100
ExecutionMode=0
Report=${REPORT_NAME}
ReplaceReport=1
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0
Visual=0
EOF

# Convert INI path to Windows format
WIN_INI=$(winepath -w "$INI_FILE" 2>/dev/null || echo "Z:${INI_FILE}")

# --- Stop running MT5 ---
log "=== MT5 Backtest Runner ==="
log "EA:      ${EA_NAME}"
log "Symbol:  ${SYMBOL}"
log "Period:  ${PERIOD}"
log "Range:   ${FROM_DATE} to ${TO_DATE}"
log "Deposit: ${DEPOSIT}"
log "Model:   ${MODEL} (0=Every tick, 1=1min OHLC, 2=Open price)"
log ""

# Signal entrypoint that backtest is running (prevents container exit)
touch /tmp/backtest-running

log "Stopping running MT5 instance..."
wineserver --kill 2>/dev/null || true
sleep 3

# Clean up old report
rm -f "${REPORT_DIR}/${REPORT_NAME}.htm"
rm -f "${REPORT_DIR}/${REPORT_NAME}.html"

# --- Run backtest ---
log "Starting MT5 backtest..."
log "Command: wine ${MT5_DIR}/terminal64.exe /portable /config:${WIN_INI}"

cd "${MT5_DIR}"
MT5_CMD_ARGS="/portable /config:${WIN_INI}"
wine "${MT5_DIR}/terminal64.exe" ${MT5_CMD_ARGS} 2>/dev/null &
MT5_PID=$!

# Wait for MT5 to finish (ShutdownTerminal=1 makes it exit after test)
ELAPSED=0
TIMEOUT=600  # 10 minutes
log "Waiting for backtest to complete (timeout: ${TIMEOUT}s)..."

while kill -0 $MT5_PID 2>/dev/null && [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log "  Still running... (${ELAPSED}s)"
    fi
done

if kill -0 $MT5_PID 2>/dev/null; then
    log "WARNING: Backtest timed out after ${TIMEOUT}s. Killing MT5..."
    kill $MT5_PID 2>/dev/null || true
    wineserver --kill 2>/dev/null || true
    sleep 2
fi

# Make sure Wine is fully stopped
wineserver --kill 2>/dev/null || true
sleep 2

log "MT5 process exited after ${ELAPSED}s"

# --- Find and parse report ---
REPORT_FILE=""
for ext in htm html; do
    for loc in "${REPORT_DIR}/${REPORT_NAME}.${ext}" \
               "${REPORT_DIR}/${REPORT_NAME}-${EA_NAME}.${ext}"; do
        if [ -f "$loc" ]; then
            REPORT_FILE="$loc"
            break 2
        fi
    done
done

# Also search more broadly
if [ -z "$REPORT_FILE" ]; then
    REPORT_FILE=$(find "${MT5_DIR}" -maxdepth 2 -name "${REPORT_NAME}*" \( -name "*.htm" -o -name "*.html" \) -print -quit 2>/dev/null)
fi

if [ -z "$REPORT_FILE" ] || [ ! -f "$REPORT_FILE" ]; then
    log ""
    log "ERROR: Backtest report not found."
    log "Expected at: ${REPORT_DIR}/${REPORT_NAME}.htm"
    log ""
    log "Possible causes:"
    log "  - EA needs to be compiled first (only .mq5 source found, no .ex5)"
    log "  - Symbol '${SYMBOL}' not available or no history data"
    log "  - EA has errors preventing backtest"
    log ""
    log "Check MT5 logs:"
    ls -lt "${MT5_DIR}/logs/"*.log 2>/dev/null | head -3 >&2
    LATEST_LOG=$(ls -t "${MT5_DIR}/logs/"*.log 2>/dev/null | head -1)
    if [ -n "$LATEST_LOG" ]; then
        log ""
        log "=== Last 30 lines of MT5 log ==="
        tail -30 "$LATEST_LOG" >&2
    fi

    # Still restart MT5 if needed
    if [ "$RESTART_MT5" = true ]; then
        log ""
        log "Restarting MT5 for live trading..."
        restart_mt5
    fi
    exit 1
fi

log "Report found: ${REPORT_FILE}"
log ""

# Parse and output report
python3 /scripts/parse_report.py "$REPORT_FILE" "$OUTPUT_FORMAT"

# --- Restart MT5 for live trading ---
if [ "$RESTART_MT5" = true ]; then
    log ""
    log "Restarting MT5 for live trading..."
    restart_mt5
fi
