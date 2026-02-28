# MT5 Headless Docker on Apple Silicon — Complete Build Context

**Purpose**: This document contains everything needed to understand, recreate, modify, or debug the MT5 headless Docker setup running on an Apple Silicon Mac. Give this to Claude to restore full context.

---

## 1. What This Project Does

Runs MetaTrader 5 (MT5) — a Windows-only x86_64 trading terminal — headlessly inside a Docker container on an Apple Silicon (ARM64) Mac. The container:

- Installs MT5 automatically on first run
- Auto-connects to a broker using credentials from `.env`
- Syncs MQL5 Expert Advisor (EA) source files into MT5
- Compiles EAs automatically
- Supports live/demo trading and backtesting
- Persists all state across container restarts via a volume mount

## 2. The Problem and Why It Was Hard

MT5 is a **Windows x86_64 binary**. Apple Silicon is **ARM64**. Running MT5 requires solving two translation layers:

```
MT5 (Windows x86_64) → Wine (Linux x86_64) → ARM64 host
```

### Approaches That Failed

| Approach | What Happened | Root Cause |
|----------|--------------|------------|
| `--platform=linux/amd64` (QEMU/Rosetta) | Wine crashes with page-size assertion | Apple Silicon uses 16KB pages; Wine expects 4KB. QEMU/Rosetta expose host page size. |
| Box64 + Wine 11.x | "A debugger has been found" dialog | Wine 11.x changed something that triggers MT5's anti-debug protection. |
| Box64 + Wine 10.0 | MT5 installs fine, but `terminal64.exe` spins at 100% CPU forever — no GUI, no network, no further log output | MT5's anti-tampering code enters an infinite userspace loop when running through box64's x86_64→ARM64 translation. Confirmed same behavior with dynarec disabled (interpreter mode). Not a box64 bug — MT5's own code. |
| Copying MT5 out of Wine prefix | `terminal64.exe` exits immediately with code 0 | MT5 checks the Windows registry for its install path and refuses to run from a different location. |

### The Working Solution: Hangover Wine

**Hangover** (https://github.com/AndreRH/hangover) is a purpose-built project that pairs Wine with the FEX emulator for running Windows x86_64 apps on ARM64 Linux.

**Key difference from box64 + Wine:**
- **Box64 approach**: Both Wine AND the Windows app run through box64 emulation. Wine's entire x86_64 codebase is translated instruction-by-instruction.
- **Hangover approach**: Wine runs **natively on ARM64**. Only the Windows application code (terminal64.exe) is emulated via FEX. Wine's message loop, display driver, networking, and system calls all execute as native ARM64 code.

This matters because MT5's anti-tampering apparently detects the quality of the emulation environment. With box64, everything is emulated and the detection triggers. With Hangover, Wine itself is native-quality and only the app code goes through FEX, which MT5 tolerates.

**Results:**
- CPU usage: ~8% (vs 99% with box64)
- MT5 renders its full GUI
- MT5 connects to broker servers
- MT5 compiles MQL5 files
- No debugger detection dialog (even though Hangover is based on Wine 11.0)

## 3. Architecture

```
┌─────────────────────────────────────────────────┐
│  Docker Container (ARM64 native, Ubuntu 22.04)  │
│                                                 │
│  Xvfb :99 (virtual framebuffer, 1024x768x24)   │
│  Openbox (window manager — required for MT5)    │
│  x11vnc → websockify → noVNC (port 6080)       │
│    └─ Browser GUI: http://localhost:6080/vnc.html│
│                                                 │
│  Hangover Wine 11.0 (ARM64 native)              │
│    └─ FEX emulator (x86_64 → ARM64)            │
│        └─ terminal64.exe (MT5)                  │
│            ├─ Connected to broker               │
│            ├─ EAs loaded from /mnt/experts      │
│            └─ Logs in Wine prefix               │
│                                                 │
│  Volumes:                                       │
│    /root/.wine ← ./data/wine (persisted)        │
│    /mnt/experts ← ../  (EA source, read-only)   │
└─────────────────────────────────────────────────┘
```

## 4. Directory Structure

```
ea/                              # Parent repo with EA source files
├── FibonacciGoldenZone.mq5      # EA source file
├── MondayGapMetals.mq5          # EA source file
└── mt5-docker/                  # This project
    ├── Dockerfile               # Single-stage, installs Hangover Wine
    ├── docker-compose.yml       # Container orchestration + volumes
    ├── .env                     # Broker credentials (gitignored)
    ├── .env.example             # Template for .env
    ├── .gitignore               # Ignores .env and data/
    ├── scripts/
    │   ├── entrypoint.sh        # Main entrypoint: Xvfb + openbox + Wine init + MT5
    │   └── healthcheck.sh       # Checks terminal64.exe is running
    ├── data/                    # Created at runtime, persisted via volume
    │   └── wine/                # Wine prefix with MT5 installation
    └── CLAUDE-CONTEXT.md        # This file
```

## 5. File Contents and Rationale

### Dockerfile

Single-stage build on `ubuntu:22.04` (ARM64 native). Three main steps:

1. **HTTPS bootstrap**: Install `ca-certificates` over HTTP, then switch apt sources to HTTPS. Required because the user's ISP (Safaricom Kenya) intercepts/corrupts plain HTTP traffic.

2. **Runtime deps**: `xvfb` (virtual display), `openbox` (window manager — MT5 won't render without one), `xdotool` (for dismissing dialogs programmatically), `wget`, `procps`, `x11vnc` + `novnc` + `python3-websockify` (browser-based GUI access via noVNC).

3. **Hangover Wine**: Downloaded as a `.tar` from GitHub releases containing `.deb` packages. Installed via `apt install ./hangover*.deb` which resolves all dependencies automatically. Hangover provides `/usr/bin/wine` and `/usr/bin/wineserver`.

**Why NOT build-time MT5 install**: MT5's installer (`mt5setup.exe`) is a stub downloader that requires network + GUI. It's unreliable during Docker builds (timeouts, no progress visibility). Runtime installation via the entrypoint is more robust and the result is persisted via the Wine prefix volume.

### docker-compose.yml

Key settings:
- **No `platform:` override** — container runs natively on ARM64
- **`../:/mnt/experts:ro`** — mounts parent directory (EA source files) read-only
- **`./data/wine:/root/.wine`** — persists the entire Wine prefix including MT5 installation. First run takes ~3 minutes; subsequent starts are instant.
- **`shm_size: 256m`** — Wine/Xvfb need shared memory
- **`memory: 4G`** — MT5 + Wine + FEX emulation use ~500MB normally, can spike during compilation
- **`start_period: 120s`** — healthcheck grace period for first-run installation
- **Port `6080:6080`** — noVNC browser-based GUI access at `http://localhost:6080/vnc.html`
- **Port `5900:5900`** (commented out) — direct VNC client access

### scripts/entrypoint.sh

Startup sequence:
1. Start Xvfb on display :99 with **24-bit color** (16-bit causes rendering issues)
2. Start openbox window manager (MT5 requires a WM for window mapping)
3. Start x11vnc + websockify (noVNC) for browser-based GUI access on port 6080
4. Initialize Wine prefix if first run (`wineboot --init`)
4. Find existing MT5 installation in Wine prefix, or install it:
   - Download `mt5setup.exe` from MetaQuotes CDN
   - Run `wine mt5setup.exe /auto` (silent install)
   - Wait up to 5 minutes, then find `terminal64.exe`
   - Save the install path to `$WINEPREFIX/.mt5-path`
5. Sync `.mq5` and `.ex5` files from `/mnt/experts` to MT5's `MQL5/Experts/`
6. Generate `mt5-auto.ini` config with broker credentials
7. Launch MT5: `wine terminal64.exe /portable /login:... /password:... /server:... /config:...`
8. Stream MT5 logs to stdout for `docker logs` visibility
9. Trap SIGTERM/SIGINT for graceful Wine shutdown

**Critical**: MT5 must be launched from its Wine prefix installation directory (`cd "${MT5_DIR}"`). It checks the Windows registry for its install path and exits immediately if run from elsewhere.

### scripts/healthcheck.sh

Checks `pgrep -f "terminal64.exe"` or `pgrep -f "wineserver"`. Simple process-based health check.

### .env

```
MT5_LOGIN=6021077
MT5_PASSWORD=#2JT7!@Df3ze5Ae
MT5_SERVER=Deriv-Demo
```

Passed to the container via `env_file:` in docker-compose.yml. The entrypoint reads these to build command-line args and generate the ini config.

## 6. How to Use

### First Time Setup
```bash
cd ea/mt5-docker
cp .env.example .env
# Edit .env with your broker credentials
docker compose build
docker compose up -d
# First run takes ~3 minutes (Wine init + MT5 download/install)
docker compose logs -f mt5
```

**IMPORTANT — Broker Discovery (required on first run and after full reset):**

The generic MT5 installer from MetaQuotes does NOT include broker-specific server addresses. After MT5 installs and starts, you **must** perform a one-time broker discovery step via the GUI:

1. Open the noVNC GUI at **http://localhost:6080/vnc.html**
2. In MT5, go to **File → Open an Account**
3. In the search field, type your broker name (e.g. `Deriv`) and click **"Find your company"**
4. Wait for the broker list to populate (this downloads server addresses from MetaQuotes' directory)
5. Click **Cancel** to close the dialog — the server addresses are now cached

Without this step, MT5 will show in the title bar that it knows the account/server name but will have **zero outbound network connections**, the Market Watch will show "Waiting for update" or be empty, and no symbols will load. The command-line `/server:Deriv-Demo` flag only tells MT5 *which* server to connect to — it doesn't provide the server's IP addresses.

Once broker discovery is done, the server addresses are persisted in the Wine prefix (`data/wine/`) and survive container restarts.

### Adding Symbols (e.g. Deriv Volatility Indices)

After broker discovery, the Market Watch may only show a few default symbols. To add more:

1. Open the noVNC GUI at **http://localhost:6080/vnc.html**
2. Press **Ctrl+U** or go to **View → Symbols** to open the Symbols dialog
3. In the left panel, scroll to find your desired category (e.g. **Volatility Indices**)
4. In the right panel, select the symbols you want (use Shift+click or Ctrl+A to select multiple)
5. Click **"Show Symbol"** to add them to Market Watch
6. Click **OK** to close

For Deriv, available symbol categories include:
- **Volatility Indices** — Volatility 10/25/50/75/100 Index, plus 1-second variants
- **Crash Boom Indices** — Crash/Boom 300/500/1000
- **Jump Indices** — Jump 10/25/50/75/100
- **Step Indices**, **Range Break**, **DEX Indices**, and many more
- **Forex Major/Minor/Exotic**, **Metals**, **Energies**, **Equities**, **ETFs**, **Crypto**

Symbol selections persist across container restarts.

### Subsequent Starts
```bash
docker compose up -d    # Starts in ~15 seconds (MT5 already installed)
```

### Accessing the GUI (noVNC)
Open **http://localhost:6080/vnc.html** in your browser for full MT5 GUI access. This is useful for:
- Initial broker discovery (required on first run)
- Adding/removing symbols in Market Watch
- Managing Expert Advisors
- Running backtests via the Strategy Tester
- Debugging connection or rendering issues

For direct VNC client access (e.g. RealVNC, TigerVNC), uncomment the port `5900:5900` line in `docker-compose.yml`.

### Check Status
```bash
docker compose ps       # Should show "healthy"
docker compose logs mt5 # View logs
```

### Restart
```bash
docker compose restart mt5
```

### Full Reset (reinstall MT5)
```bash
docker compose down
rm -rf data/wine
docker compose up -d    # Will reinstall MT5 from scratch
# IMPORTANT: You must redo broker discovery via the GUI after a full reset
```

### Add/Update EA Files
Place `.mq5` or `.ex5` files in the `ea/` parent directory. They sync on container start. To force a sync:
```bash
docker compose restart mt5
```

## 7. Key Technical Details

### Why Hangover and Not Box64
Box64 translates **all** x86_64 code (Wine + MT5) instruction-by-instruction. MT5's anti-tampering code detects this environment and enters an infinite busy loop (99% CPU, no network, no GUI). This is not a bug in box64 — it's MT5's intentional DRM behavior.

Hangover runs Wine **natively** on ARM64 and only emulates the Windows application code via FEX. MT5 tolerates this because the Wine infrastructure (system calls, message loop, display driver) operates at native speed/quality.

### Why Wine 11.0 Works with Hangover but Not with Box64
With raw box64, Wine 11.x triggers MT5's "debugger detected" dialog. This detection is based on how Wine implements certain Windows API calls (`NtQueryInformationProcess`, `IsDebuggerPresent`, etc.). When Wine itself is emulated through box64, the detection fires. When Wine runs natively (Hangover), the same API calls execute at native quality and don't trigger detection.

### WINEDLLOVERRIDES="mscoree=d"
Tells Wine to disable the Mono/.NET runtime. Without this, Wine shows a "Wine Mono installer" dialog that blocks headless operation. MT5 doesn't need .NET.

### WINEDEBUG=-all
Suppresses Wine debug output. Reduces log noise and may help avoid triggering MT5's anti-tamper checks that monitor debug output.

### Openbox Window Manager
MT5 requires a window manager for its GUI to render. Without one, MT5's windows are created at 1x1 pixel and never become visible. The Xvfb virtual framebuffer alone is not sufficient. Openbox is lightweight (~2MB) and works headlessly.

### 24-bit Color Depth
Xvfb must use 24-bit color (`1024x768x24`). MT5 does not render properly with 16-bit color.

### MT5 Install Path Constraint
MT5 registers its installation path in the Windows registry. If you copy `terminal64.exe` to a different location and run it, it exits with code 0 silently. Always run MT5 from its original Wine prefix path: `/root/.wine/drive_c/Program Files/MetaTrader 5/`.

### Safaricom HTTPS Workaround
The user's ISP (Safaricom, Kenya) intercepts plain HTTP apt traffic, causing package corruption. The Dockerfile installs `ca-certificates` over HTTP first (this one package works), then rewrites all apt sources from `http://` to `https://`.

## 8. Hangover Wine Details

- **Project**: https://github.com/AndreRH/hangover
- **Version used**: 11.0 (released 2026-01-13)
- **Base Wine**: 11.0
- **Download URL**: `https://github.com/AndreRH/hangover/releases/download/hangover-11.0/hangover_11.0_ubuntu2204_jammy_arm64.tar`
- **Size**: ~236MB tar containing 4 .deb packages
- **x86_64 emulator**: FEX (`libarm64ecfex.dll`) — for 64-bit Windows apps
- **i386 emulator**: Box64 (`wowbox64.dll`) — for 32-bit Windows apps
- **Key advantage**: Wine runs natively on ARM64; only Windows app code is emulated
- **Binary path**: `/usr/bin/wine`, `/usr/bin/wineserver`

### Updating Hangover
To upgrade to a newer version, change the download URL in the Dockerfile to point to the new release, rebuild, and delete `data/wine/` to force a fresh Wine prefix.

## 9. Troubleshooting

### MT5 connected but Market Watch empty / "Waiting for update" / no symbols
**This is the most common issue.** MT5 shows the account and server in the title bar but has zero outbound network connections and no market data.

**Cause**: The generic MT5 build from MetaQuotes CDN does not include broker-specific server IP addresses. The `/server:Deriv-Demo` command-line flag tells MT5 the server *name*, but MT5 doesn't know *where* that server is (IP addresses). MT5 needs to perform a one-time broker discovery via its "Open an Account" dialog, which queries the MetaQuotes central directory to download the broker's server addresses.

**Symptoms**:
- Title bar shows correct account/server (e.g. "6021077 - Deriv-Demo - Netting")
- Market Watch shows "Waiting for update" or is completely empty ("0 / 0")
- `netstat -tn` inside the container shows NO outbound connections (only VNC traffic)
- MT5 log (`logs/YYYYMMDD.log`) shows no "Network:" entries at all
- EAs fail to initialize with "code 0 (execution canceled)"

**Fix**:
1. Open **http://localhost:6080/vnc.html** in your browser
2. In MT5: **File → Open an Account**
3. Type your broker name (e.g. `Deriv`) in the search field
4. Click **"Find your company"**
5. Wait for broker list to populate (downloads server addresses)
6. Click **Cancel** — the addresses are now cached in the Wine prefix

After this, MT5 will connect automatically. The server addresses persist in `data/wine/` across restarts.

**How to verify the fix worked**: Run `docker exec mt5-headless netstat -tn` — you should see ESTABLISHED connections to port 443. The Market Watch will populate with symbols and live prices.

### MT5 "debugger detected" dialog
- Only happens with raw box64 + Wine 11.x
- Solution: use Hangover (current setup) or box64 + Wine 10.0 (but that has the 100% CPU issue)

### MT5 at 100% CPU, no network, no GUI
- Happens with raw box64 + Wine 10.0
- MT5's anti-tampering detects full emulation
- Solution: use Hangover (current setup)

### Black screen / MT5 not rendering
- Missing window manager → install and start openbox before MT5
- 16-bit color depth → use 24-bit (`1024x768x24`)
- Window too large for Xvfb → MT5 saves window size in `Config/terminal.ini`; delete it to reset

### MT5 exits immediately (code 0)
- Running from wrong directory → must `cd` to and launch from the Wine prefix install path
- Copied MT5 files to another location → don't copy, run in-place

### MT5 install times out
- Slow network → increase timeout in entrypoint.sh (currently 300s)
- ISP interference → ensure HTTPS is used (ca-certificates bootstrap)

### Wine prefix corruption
```bash
docker compose down
rm -rf data/wine
docker compose up -d
# IMPORTANT: Redo broker discovery via the GUI after reset
```

### LiveUpdate dialog blocks MT5
MT5 may show a "Welcome to LiveUpdate" dialog on startup. The entrypoint doesn't currently dismiss this automatically. Options:
- Use xdotool to dismiss: `docker exec mt5-headless xdotool search --name 'LiveUpdate' key Tab Return`
- Or add this to the entrypoint after MT5 starts

### Checking MT5 GUI (noVNC or screenshots)
**Preferred**: Open **http://localhost:6080/vnc.html** in your browser for live GUI access.

**Alternative** (CLI screenshots): Install imagemagick in the container and take screenshots:
```bash
docker exec mt5-headless bash -c "apt-get update -qq && apt-get install -y -qq imagemagick && import -window root -display :99 /tmp/screen.png"
docker cp mt5-headless:/tmp/screen.png ./screen.png
open screen.png
```

## 10. What Was Tried (Chronological Failure Log)

This section documents every approach attempted so you don't repeat failed experiments.

1. **`--platform=linux/amd64` with Wine on QEMU/Rosetta** — Wine page-size assertion crash (`page size 0x4000 incompatible with region alignment 0x1000`). Unfixable without kernel-level changes.

2. **Box64 (built from source) + Wine 11.0 x86_64 debs** — Box64 compiled, Wine downloaded, but `wineboot --init` hung on `wineserver --wait`. Fix: use `timeout 120 wineboot --init || true; wineserver --kill`.

3. **Box64 + Wine 11.0 + MT5 installer** — MT5 shows "A debugger has been found" dialog. Wine 11.x triggers MT5's anti-debug.

4. **Box64 + Wine 10.0** — No debugger dialog. MT5 installs successfully. But `terminal64.exe` runs at 99% CPU in an infinite userspace loop. No network connections. No GUI rendering. Confirmed with:
   - `strace`: only futex calls, all time in userspace
   - `BOX64_DYNAREC=0` (interpreter mode): same 99% CPU
   - `BOX64_DYNAREC_PAUSE=3`, `STRONGMEM=3`, `SAFEFLAGS=2`: no change
   - Wine registry GDI renderer (`MaxVersionGL=0`, `renderer=gdi`): no change
   - openbox window manager: no change
   - Wine virtual desktop (`explorer /desktop=MT5,1024x768`): no change
   - Modified `terminal.ini` window dimensions: no change
   - Different Xvfb color depth (24-bit): no change

5. **Hangover Wine 11.0** — Works. MT5 installs, renders GUI, connects to broker, compiles files, CPU ~8%. This is the current solution.

6. **MT5 connected to broker but no market data** — After container restart, MT5 showed the correct account/server in the title bar but had zero outbound TCP connections, empty Market Watch, and "Waiting for update". Root cause: the generic MT5 build from MetaQuotes CDN doesn't include broker-specific server IP addresses. The `/server:Deriv-Demo` flag tells MT5 the name but not the address. Fix: perform a one-time broker discovery via **File → Open an Account → search broker name → "Find your company"**. This queries the MetaQuotes central directory and caches server addresses in the Wine prefix. Once done, connections persist across restarts.
