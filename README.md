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

- **Ubuntu 22.04 (x86_64)** runs under Docker's x86 emulation on Apple Silicon
- **Wine** executes the Windows MT5 binary inside Linux
- **Xvfb** provides a virtual display so MT5 can run headlessly
- **Portable mode** keeps all data in one directory for clean volume mounts

## EA Files

Your `.mq5` and `.ex5` files from the parent directory (`../`) are mounted read-only into the container at `/mnt/experts/`. On startup, they're copied into MT5's Experts directory.

To add or update EAs:
1. Place files in the parent `ea/` directory
2. Restart the container: `docker compose restart mt5`

Pre-compiled `.ex5` files in `data/MQL5/Experts/` are also picked up directly.

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

# Stop
docker compose down

# Rebuild after Dockerfile changes
docker compose build --no-cache

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
├── .env                    # Your broker credentials (git-ignored)
├── .env.example
├── scripts/
│   ├── entrypoint.sh       # Container entrypoint
│   └── healthcheck.sh
├── data/                   # Persisted MT5 data (git-ignored)
│   ├── MQL5/Experts/       # Compiled EAs
│   ├── MQL5/Logs/          # Trading logs
│   └── config/             # Broker/server configs
```

## Troubleshooting

**Build fails at Wine init**: Increase Docker Desktop memory to 6GB+ in Settings > Resources.

**MT5 crashes on start**: Check `docker compose logs mt5`. Common cause is insufficient shared memory — the compose file sets `shm_size: 256m` which should suffice.

**Container unhealthy**: The health check looks for `terminal64.exe`. If MT5 exits immediately, check logs for broker connection errors or missing config.

**Slow performance**: Expected on Apple Silicon due to x86 emulation. Backtesting will be slower than native Windows. For heavy optimization runs, consider a Windows VPS.
