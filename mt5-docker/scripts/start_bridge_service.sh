#!/bin/bash
# =============================================================================
# Setup BridgeService: whitelist 127.0.0.1 and verify connection.
# The service itself auto-starts (registered in services.ini).
# The WebRequest whitelist is the only one-time manual/automated step.
#
# Usage: start_bridge_service.sh [timeout_seconds]
# =============================================================================

TIMEOUT=${1:-30}
BRIDGE_PORT=${BRIDGE_PORT:-15555}
API_PORT=${API_PORT:-8000}

log() { echo "$@" >&2; }

# Check if bridge is already connected
check_bridge() {
    local health
    health=$(curl -s "http://localhost:${API_PORT}/health" 2>/dev/null)
    echo "$health" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ea_connected') else 1)" 2>/dev/null
    return $?
}

if check_bridge; then
    log "Bridge is already connected!"
    exit 0
fi

log "=== Setting up BridgeService ==="
log ""

# Find MT5 window
MT5_WIN=""
for pattern in "Demo Account" "Live Account" "MetaTrader" "Hedge"; do
    MT5_WIN=$(xdotool search --name "$pattern" 2>/dev/null | head -1)
    [ -n "$MT5_WIN" ] && break
done
if [ -z "$MT5_WIN" ]; then
    MT5_WIN=$(xdotool search --name "" 2>/dev/null | while read wid; do
        name=$(xdotool getwindowname "$wid" 2>/dev/null)
        [ -n "$name" ] && [ "$name" != "Openbox" ] && [ "$name" != "Default IME" ] && echo "$wid"
    done | head -1)
fi
if [ -z "$MT5_WIN" ]; then
    log "ERROR: MT5 window not found. Is MT5 running?"
    exit 1
fi
log "Found MT5 window: $MT5_WIN ($(xdotool getwindowname $MT5_WIN 2>/dev/null))"

# --- Step 1: Add 127.0.0.1 to WebRequest whitelist via GUI ---
log ""
log "Adding 127.0.0.1 to WebRequest whitelist..."

# Open Tools → Options (Ctrl+O)
xdotool windowactivate --sync "$MT5_WIN" 2>/dev/null
sleep 0.5
xdotool key ctrl+o
sleep 2

# Find Options dialog
OPT_WIN=$(xdotool search --name "Options" 2>/dev/null | head -1)
if [ -z "$OPT_WIN" ]; then
    log "WARNING: Could not open Options dialog"
else
    log "Options dialog opened"
    xdotool windowactivate --sync "$OPT_WIN" 2>/dev/null
    sleep 0.3

    # Navigate to Expert Advisors tab (4th tab from left)
    # Click on the tab — approximate position from tab bar
    # Tab order: Server, Charts, Trade, Expert Advisors, GPU, Events, ...
    xdotool mousemove --window "$OPT_WIN" 170 10
    sleep 0.2
    xdotool click --window "$OPT_WIN" 1
    sleep 1

    # Check "Allow WebRequest for listed URL:" checkbox
    # It's the 7th control from the top, at approximately y=214
    xdotool mousemove --window "$OPT_WIN" 30 214
    sleep 0.2
    xdotool click --window "$OPT_WIN" 1
    sleep 0.5

    # Click on the URL list area to start adding
    xdotool mousemove --window "$OPT_WIN" 200 245
    sleep 0.2
    xdotool click --window "$OPT_WIN" 1
    sleep 0.3
    xdotool click --window "$OPT_WIN" 1
    sleep 0.5

    # Type the address
    xdotool type --window "$OPT_WIN" --delay 50 "127.0.0.1"
    sleep 0.3
    xdotool key --window "$OPT_WIN" Return
    sleep 0.5

    # Click OK button (bottom center of dialog)
    xdotool mousemove --window "$OPT_WIN" 395 380
    sleep 0.2
    xdotool click --window "$OPT_WIN" 1
    sleep 2

    # Verify dialog closed
    OPT_CHECK=$(xdotool search --name "Options" 2>/dev/null | head -1)
    if [ -z "$OPT_CHECK" ]; then
        log "WebRequest whitelist configured via GUI"
    else
        log "WARNING: Options dialog may not have saved. Closing..."
        xdotool key --window "$OPT_WIN" Escape
        sleep 1
    fi
fi

# --- Step 2: Wait for BridgeService to connect ---
log ""
log "Waiting for BridgeService to connect..."
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if check_bridge; then
        log ""
        log "SUCCESS! BridgeService is connected."
        log "This setting persists — no further setup needed."
        exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    log "  Waiting... (${ELAPSED}s)"
done

log ""
log "BridgeService did not connect within ${TIMEOUT}s."
log ""
log "=== Manual Setup Required (one-time, takes 30 seconds) ==="
log ""
log "1. Open http://localhost:6080/vnc.html in your browser"
log "2. In MT5: Tools → Options → Expert Advisors tab"
log "3. Check 'Allow WebRequest for listed URL'"
log "4. Double-click the URL area, type: 127.0.0.1"
log "5. Click OK"
log ""
log "If BridgeService isn't in the Services list:"
log "  - Press Ctrl+N to open Navigator"
log "  - Expand 'Services' → right-click 'BridgeService' → Start"
log ""
log "Verify: curl http://localhost:${API_PORT}/health"
log "  → should show: \"ea_connected\": true"
exit 1
