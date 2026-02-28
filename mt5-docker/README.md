# MT5 Headless Docker (Apple Silicon)

Run MetaTrader 5 Expert Advisors in a Docker container on your Mac without installing MT5 natively.

## Quick Start

```bash
cd mt5-docker

# 1. Set up broker credentials
cp .env.example .env
# Edit .env with your broker account details

# 2. Build the image (first time takes ~10-15 min due to x86 emulation)
docker compose build

# 3. Start the container
docker compose up -d

# 4. Check status
docker compose ps
docker compose logs -f mt5
```

## How It Works

- **Hangover Wine 11.0** runs natively on ARM64, emulating only Windows app code via FEX
- **Xvfb** provides a virtual display so MT5 can run headlessly
- **noVNC** gives browser-based GUI access at `http://localhost:6080/vnc.html`
- **Portable mode** keeps all data in one directory for clean volume mounts

## EA Files

Your `.mq5` and `.ex5` files from the parent directory (`../`) are mounted read-only into the container at `/mnt/experts/`. On startup, they're copied into MT5's Experts directory.

To add or update EAs:
1. Place files in the parent `ea/` directory
2. Restart the container: `docker compose restart mt5`

Pre-compiled `.ex5` files in `data/MQL5/Experts/` are also picked up directly.

## Backtesting from the Terminal

Run backtests directly from your macOS terminal using `make`:

```bash
# Run a backtest (results printed to terminal)
make backtest EA=FibonacciGoldenZone SYMBOL=XAUUSD

# With full options
make backtest EA=FibonacciGoldenZone SYMBOL=XAUUSD PERIOD=H1 FROM=2025.06.01 TO=2026.02.28

# Export to JSON or CSV
make backtest-json EA=FibonacciGoldenZone SYMBOL=XAUUSD > results.json
make backtest-csv EA=FibonacciGoldenZone SYMBOL=XAUUSD > results.csv

# List available EAs
make list-eas

# Show all commands and options
make help
```

### Backtest Options

| Option | Default | Description |
|--------|---------|-------------|
| `EA` | *(required)* | EA name without extension (e.g. `FibonacciGoldenZone`) |
| `SYMBOL` | `Volatility 10 (1s) Index` | Trading symbol |
| `PERIOD` | `H1` | Timeframe: `M1`, `M5`, `M15`, `M30`, `H1`, `H4`, `D1`, `W1`, `MN` |
| `FROM` | 3 months ago | Start date (`YYYY.MM.DD`) |
| `TO` | today | End date (`YYYY.MM.DD`) |
| `DEPOSIT` | `10000` | Initial deposit |
| `MODEL` | `0` | Tick model: `0`=Every tick, `1`=1min OHLC, `2`=Open price only |

### How It Works

The backtest script (`scripts/backtest.sh`):
1. Syncs the latest EA files from the host
2. Stops the running MT5 instance
3. Generates a backtest config (INI file)
4. Runs MT5 with `ShutdownTerminal=1` (exits after test)
5. Parses the HTML report into text/JSON/CSV
6. Restarts MT5 for live trading

**Note**: Backtesting temporarily pauses live trading. MT5 is automatically restarted after the test completes.

### Tips
- Use `MODEL=1` (1-min OHLC) for a good balance of speed and accuracy
- `MODEL=2` (Open price) won't work with EAs that use multi-timeframe analysis
- Match the symbol to your EA's design — e.g. `FibonacciGoldenZone` works well on `XAUUSD`, not on synthetic Volatility indices

## Broker Login

Fill in your credentials in `.env` — the container handles the rest automatically:

```env
MT5_LOGIN=12345678
MT5_PASSWORD=your_password
MT5_SERVER=YourBroker-Demo
```

The entrypoint passes these as command-line args (`/login`, `/password`, `/server`) and also generates a config `.ini` with auto-trading enabled. No separate machine or interactive login required.

If MT5 fails to connect (check `docker compose logs mt5`), verify:
- Your server name matches exactly what your broker provides (e.g. `ICMarkets-Demo`, `Pepperstone-Live01`)
- The account is active and credentials are correct
- Your broker allows MT5 (not all do — some are MT4-only)

## Commands

```bash
# View live logs
docker compose logs -f mt5
# or
make logs

# Stop / Start / Restart
docker compose down
docker compose up -d
make restart

# Rebuild after Dockerfile changes
docker compose build --no-cache
# or
make build

# Shell into running container
docker compose exec mt5 bash

# Check MT5 process inside container
docker compose exec mt5 pgrep -a terminal64
```

## Directory Structure

```
mt5-docker/
├── Dockerfile
├── docker-compose.yml
├── Makefile                # Easy CLI commands (make backtest, make help)
├── .env                    # Your broker credentials (git-ignored)
├── .env.example
├── scripts/
│   ├── entrypoint.sh       # Container entrypoint
│   ├── healthcheck.sh
│   ├── backtest.sh         # Backtest orchestrator (runs inside container)
│   └── parse_report.py     # MT5 HTML report parser → text/JSON/CSV
├── data/                   # Persisted MT5 data (git-ignored)
│   └── wine/               # Wine prefix with MT5 installation
```

## Troubleshooting

**Build fails at Wine init**: Increase Docker Desktop memory to 6GB+ in Settings > Resources.

**MT5 crashes on start**: Check `docker compose logs mt5`. Common cause is insufficient shared memory — the compose file sets `shm_size: 256m` which should suffice.

**Container unhealthy**: The health check looks for `terminal64.exe`. If MT5 exits immediately, check logs for broker connection errors or missing config.

**Slow performance**: Expected on Apple Silicon due to x86 emulation. Backtesting will be slower than native Windows. For heavy optimization runs, consider a Windows VPS.
