#!/bin/bash
set -e

EA_MOUNT="/mnt/experts"
# File that stores the MT5 install path in the Wine prefix
MT5_PATH_FILE="${WINEPREFIX}/.mt5-path"

echo "=== MT5 Headless Container Starting ==="
echo "Date: $(date)"
echo "Architecture: $(uname -m) (Wine — native x86_64)"
echo "Wine: $(wine --version 2>/dev/null || echo 'not found')"

# Start Xvfb (virtual framebuffer) with 24-bit color
echo "Starting Xvfb on display :99..."
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 2

# Verify Xvfb is running
if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "ERROR: Xvfb failed to start"
    exit 1
fi
echo "Xvfb started (PID: $XVFB_PID)"

# Start openbox window manager (required for MT5 GUI rendering)
openbox --sm-disable &>/dev/null &
sleep 1
echo "Window manager started"

# Start VNC server + noVNC for browser-based GUI access
x11vnc -display :99 -forever -nopw -shared -rfbport 5900 &>/dev/null &
websockify --web /usr/share/novnc 6080 localhost:5900 &>/dev/null &
echo "noVNC started — open http://localhost:6080/vnc.html in your browser"

# --- Start API server early (so Railway healthcheck passes during MT5 install) ---
API_PID=""
if [ "${API_ENABLED:-true}" = "true" ]; then
    API_PORT="${API_PORT:-${PORT:-8000}}"
    BRIDGE_PORT="${BRIDGE_PORT:-15555}"
    echo "Starting Trading API server on port ${API_PORT} (bridge: ${BRIDGE_PORT})..."
    PYTHONPATH=/ python3 -m uvicorn server.api:app --host 0.0.0.0 --port "${API_PORT}" --log-level info &
    API_PID=$!
    sleep 2
    if kill -0 $API_PID 2>/dev/null; then
        echo "API server started (PID: $API_PID)"
    else
        echo "WARNING: API server failed to start"
        API_PID=""
    fi
fi

# --- First-run setup: Initialize Wine and install MT5 ---

# Initialize Wine prefix if not done yet
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    echo "=== Initializing Wine prefix (first run) ==="
    timeout 120 wineboot --init 2>/dev/null || true
    sleep 5
    wineserver --kill 2>/dev/null || true
    echo "Wine prefix initialized"
fi

# Determine MT5 installation path
MT5_DIR=""
if [ -f "$MT5_PATH_FILE" ]; then
    MT5_DIR=$(cat "$MT5_PATH_FILE")
    if [ ! -f "${MT5_DIR}/terminal64.exe" ]; then
        echo "WARNING: Saved MT5 path invalid, will search..."
        MT5_DIR=""
    fi
fi

# Search for existing MT5 installation
if [ -z "$MT5_DIR" ]; then
    MT5_EXE=$(find ${WINEPREFIX} -name "terminal64.exe" -print -quit 2>/dev/null)
    if [ -n "$MT5_EXE" ]; then
        MT5_DIR=$(dirname "$MT5_EXE")
        echo "$MT5_DIR" > "$MT5_PATH_FILE"
        echo "Found existing MT5 at: $MT5_DIR"
    fi
fi

# Install MT5 if not found
if [ -z "$MT5_DIR" ]; then
    echo "=== Installing MetaTrader 5 (first run — this may take a few minutes) ==="

    # Download MT5 installer
    echo "Downloading MT5 setup..."
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
        -O /tmp/mt5setup.exe
    echo "Download complete"

    # Run MT5 installer
    echo "Running MT5 installer (this downloads and installs MT5 components)..."
    wine /tmp/mt5setup.exe /auto &
    SETUP_PID=$!

    # Wait for installer to finish (up to 5 minutes)
    WAIT=0
    while kill -0 $SETUP_PID 2>/dev/null && [ $WAIT -lt 300 ]; do
        sleep 10
        WAIT=$((WAIT + 10))
        echo "  Installer running... (${WAIT}s)"
    done

    # Kill installer if still running
    if kill -0 $SETUP_PID 2>/dev/null; then
        echo "  Installer timeout — killing"
        kill $SETUP_PID 2>/dev/null || true
    fi

    sleep 5
    wineserver --kill 2>/dev/null || true
    rm -f /tmp/mt5setup.exe

    # Find MT5 installation
    echo "Searching for MT5 installation..."
    MT5_EXE=$(find ${WINEPREFIX} -name "terminal64.exe" -print -quit 2>/dev/null)
    if [ -n "$MT5_EXE" ]; then
        MT5_DIR=$(dirname "$MT5_EXE")
        echo "$MT5_DIR" > "$MT5_PATH_FILE"
        echo "MT5 installed at: $MT5_DIR"
    else
        echo "WARNING: MT5 installation not found. Will retry on next restart."
        echo "Check logs for download/install errors."
    fi
fi

# --- Normal startup ---

# Check if MT5 is available
if [ -z "$MT5_DIR" ] || [ ! -f "${MT5_DIR}/terminal64.exe" ]; then
    echo "ERROR: terminal64.exe not found. MT5 installation may have failed."
    echo "Container will stay running for debugging. Check logs above."
    tail -f /dev/null
fi

echo "MT5 directory: ${MT5_DIR}"
LOG_DIR="${MT5_DIR}/logs"
mkdir -p "$LOG_DIR"
mkdir -p "${MT5_DIR}/MQL5/Experts"

# Sync EA files from mount if they exist
if [ -d "$EA_MOUNT" ] && [ "$(ls -A $EA_MOUNT 2>/dev/null)" ]; then
    echo "Syncing EA files from ${EA_MOUNT}..."
    cp -v ${EA_MOUNT}/*.mq5 "${MT5_DIR}/MQL5/Experts/" 2>/dev/null || true
    cp -v ${EA_MOUNT}/*.ex5 "${MT5_DIR}/MQL5/Experts/" 2>/dev/null || true
    echo "EA sync complete"
fi

# Copy BridgeEA for the trading API
if [ -f "/opt/mt5/BridgeEA.mq5" ]; then
    cp -v /opt/mt5/BridgeEA.mq5 "${MT5_DIR}/MQL5/Experts/" 2>/dev/null || true
    echo "BridgeEA copied to Experts directory"
fi

# Copy BridgeService to Services directory
mkdir -p "${MT5_DIR}/MQL5/Services"
if [ -f "/opt/mt5/BridgeService.mq5" ]; then
    cp -v /opt/mt5/BridgeService.mq5 "${MT5_DIR}/MQL5/Services/" 2>/dev/null || true
    echo "BridgeService copied to Services directory"
fi

# NOTE: Socket whitelist (127.0.0.1) for MQL5 SocketConnect is stored
# encrypted in settings.ini — it CANNOT be set via text config files.
# It must be set once via GUI: Tools → Options → Expert Advisors →
# check "Allow WebRequest for listed URL" → add 127.0.0.1 → OK.
# Run: make setup-bridge (or /scripts/start_bridge_service.sh) to automate this.
# Once set, the whitelist persists across MT5 restarts.

# Compile BridgeService if .ex5 doesn't exist yet
if [ "${API_ENABLED:-true}" = "true" ]; then
    SERVICE_EX5="${MT5_DIR}/MQL5/Services/BridgeService.ex5"
    if [ ! -f "$SERVICE_EX5" ] && [ -f "${MT5_DIR}/MetaEditor64.exe" ]; then
        echo "Compiling BridgeService..."
        cd "${MT5_DIR}"
        timeout 60 wine "${MT5_DIR}/MetaEditor64.exe" /compile:"MQL5/Services/BridgeService.mq5" /log 2>/dev/null || true
        wineserver --kill 2>/dev/null || true
        sleep 2
        if [ -f "$SERVICE_EX5" ]; then
            echo "BridgeService compiled successfully"
        else
            echo "WARNING: BridgeService compilation may have failed — MT5 will auto-compile on start"
        fi
    fi
fi

# List available EAs
echo "Available Expert Advisors:"
ls -la "${MT5_DIR}/MQL5/Experts/" 2>/dev/null || echo "  (none found)"

# Build MT5 command line arguments
MT5_ARGS="/portable"

# Add broker credentials if provided
if [ -n "$MT5_LOGIN" ] && [ -n "$MT5_SERVER" ]; then
    echo "Broker credentials detected..."
    echo "  Login:  ${MT5_LOGIN}"
    echo "  Server: ${MT5_SERVER}"

    # Pass credentials directly as command-line args (most reliable)
    MT5_ARGS="${MT5_ARGS} /login:${MT5_LOGIN} /password:${MT5_PASSWORD} /server:${MT5_SERVER}"

    # Also generate config ini as fallback
    CONFIG_FILE="${MT5_DIR}/mt5-auto.ini"
    cat > "$CONFIG_FILE" << EOF
[Common]
Login=${MT5_LOGIN}
Password=${MT5_PASSWORD}
Server=${MT5_SERVER}
KeepPrivate=1
NewsEnable=0
CertInstall=1
[Experts]
AllowLiveTrading=1
AllowDllImport=0
Enabled=1
Account=${MT5_LOGIN}
Profile=Default
EOF
    WIN_CONFIG=$(winepath -w "$CONFIG_FILE" 2>/dev/null || echo "Z:${CONFIG_FILE}")
    MT5_ARGS="${MT5_ARGS} /config:${WIN_CONFIG}"
    echo "Config generated: ${CONFIG_FILE}"
else
    echo "WARNING: No broker credentials set. MT5 will start without auto-login."
    echo "  Set MT5_LOGIN, MT5_PASSWORD, MT5_SERVER in .env"
fi

# Graceful shutdown handler
cleanup() {
    echo ""
    echo "=== Shutting down MT5 ==="
    wineserver --kill 2>/dev/null || true
    kill $XVFB_PID 2>/dev/null || true
    if [ -n "$API_PID" ]; then
        kill $API_PID 2>/dev/null || true
        echo "API server stopped"
    fi
    echo "Shutdown complete"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# Start MT5 from its installation directory (must match Wine registry path)
echo "Starting MetaTrader 5..."
echo "Command: wine ${MT5_DIR}/terminal64.exe ${MT5_ARGS}"
cd "${MT5_DIR}"
wine "${MT5_DIR}/terminal64.exe" ${MT5_ARGS} &
MT5_PID=$!

# Wait for MT5 to initialize
sleep 15
echo "MT5 started (Wine PID: $MT5_PID)"

# Tail logs to stdout so docker logs works
echo "=== Streaming MT5 logs ==="

# Monitor MT5 process and stream logs
TAIL_PID=""
while true; do
    # Check if MT5 Wine process is alive
    if ! kill -0 $MT5_PID 2>/dev/null; then
        # MT5 died — check if a backtest or account switch is running
        if [ -f /tmp/backtest-running ] || [ -f /tmp/account-switch-running ]; then
            echo "MT5 stopped for backtest/account switch — waiting..."
            kill $TAIL_PID 2>/dev/null || true
            TAIL_PID=""
            # Wait for operation to finish (lock files removed)
            while [ -f /tmp/backtest-running ] || [ -f /tmp/account-switch-running ]; do
                sleep 5
            done
            echo "Operation complete — monitoring resumed"
            # Find new MT5 PID (backtest.sh restarts it)
            sleep 5
            NEW_PID=$(pgrep -f "terminal64.exe" | head -1)
            if [ -n "$NEW_PID" ]; then
                MT5_PID=$NEW_PID
                echo "MT5 restarted (PID: $MT5_PID)"
                continue
            else
                echo "WARNING: MT5 not restarted after backtest"
                break
            fi
        else
            # Normal exit — not a backtest
            kill $TAIL_PID 2>/dev/null || true
            break
        fi
    fi

    # Tail the most recent log file
    if [ -z "$TAIL_PID" ] || ! kill -0 $TAIL_PID 2>/dev/null; then
        LATEST_LOG=$(ls -t ${LOG_DIR}/*.log 2>/dev/null | head -1)
        if [ -n "$LATEST_LOG" ]; then
            tail -f "$LATEST_LOG" &
            TAIL_PID=$!
        fi
    fi
    sleep 5
done

# If MT5 exits on its own
echo "MT5 process exited"
cleanup
