"""FastAPI trading API server for MT5."""

import asyncio
import json
import logging
import os
import subprocess
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from server.bridge import MT5Bridge
from server.models import (
    AccountInfo,
    BacktestRequest,
    CloseRequest,
    Deal,
    HealthStatus,
    LoginRequest,
    ModifyRequest,
    Order,
    Position,
    SymbolInfo,
    Tick,
    TradeRequest,
    TradeResult,
)

logger = logging.getLogger("mt5-api")
logging.basicConfig(level=logging.INFO)

bridge = MT5Bridge(
    host="0.0.0.0",
    port=int(os.environ.get("BRIDGE_PORT", "15555")),
)

_start_time = time.time()


@asynccontextmanager
async def lifespan(app: FastAPI):
    await bridge.start()
    logger.info("MT5 Trading API started")
    yield
    await bridge.stop()
    logger.info("MT5 Trading API stopped")


app = FastAPI(title="MT5 Trading API", version="1.0.0", lifespan=lifespan)


async def _cmd(command: str, params: dict | None = None, timeout: float = 10.0) -> dict:
    """Send command to EA, raise HTTP error on failure."""
    try:
        resp = await bridge.send_command(command, params, timeout)
        if resp.get("error"):
            raise HTTPException(status_code=400, detail=resp["error"])
        return resp
    except ConnectionError:
        raise HTTPException(status_code=503, detail="EA not connected to MT5")
    except TimeoutError:
        raise HTTPException(status_code=504, detail="EA command timed out")


# === Account ===

@app.get("/account", response_model=AccountInfo)
async def get_account():
    resp = await _cmd("account_info")
    return resp.get("data", {})


# === Positions ===

@app.get("/positions", response_model=list[Position])
async def get_positions():
    resp = await _cmd("positions")
    return resp.get("data", [])


# === Orders ===

@app.get("/orders", response_model=list[Order])
async def get_orders():
    resp = await _cmd("orders")
    return resp.get("data", [])


# === History ===

@app.get("/history", response_model=list[Deal])
async def get_history(
    from_ts: Optional[int] = Query(None, description="Start Unix timestamp"),
    to_ts: Optional[int] = Query(None, description="End Unix timestamp"),
):
    params = {}
    if from_ts is not None:
        params["from_ts"] = from_ts
    if to_ts is not None:
        params["to_ts"] = to_ts
    resp = await _cmd("history", params, timeout=15.0)
    return resp.get("data", [])


# === Trading ===

@app.post("/trade/buy", response_model=TradeResult)
async def trade_buy(req: TradeRequest):
    resp = await _cmd("market_buy", req.model_dump())
    return resp.get("data", {})


@app.post("/trade/sell", response_model=TradeResult)
async def trade_sell(req: TradeRequest):
    resp = await _cmd("market_sell", req.model_dump())
    return resp.get("data", {})


@app.post("/trade/close", response_model=TradeResult)
async def trade_close(req: CloseRequest):
    resp = await _cmd("close_position", req.model_dump())
    return resp.get("data", {})


@app.post("/trade/modify", response_model=TradeResult)
async def trade_modify(req: ModifyRequest):
    resp = await _cmd("modify_position", req.model_dump())
    return resp.get("data", {})


# === Market Data ===

@app.get("/symbol/{name}", response_model=SymbolInfo)
async def get_symbol(name: str):
    resp = await _cmd("symbol_info", {"symbol": name})
    return resp.get("data", {})


@app.get("/symbols", response_model=list[str])
async def list_symbols():
    resp = await _cmd("symbols_list", timeout=15.0)
    return resp.get("data", [])


@app.get("/tick/{symbol}", response_model=Tick)
async def get_tick(symbol: str):
    resp = await _cmd("tick", {"symbol": symbol})
    return resp.get("data", {})


# === Account Switching ===

@app.post("/account/login")
async def switch_account(req: LoginRequest):
    """Switch to a different broker account. Kills and restarts MT5."""
    # Write lock file so entrypoint doesn't exit
    lock_file = "/tmp/account-switch-running"
    try:
        with open(lock_file, "w") as f:
            f.write("1")

        # Kill MT5
        subprocess.run(["wineserver", "--kill"], capture_output=True, timeout=10)
        await asyncio.sleep(3)

        # Update env for the new session
        os.environ["MT5_LOGIN"] = str(req.login)
        os.environ["MT5_PASSWORD"] = req.password
        os.environ["MT5_SERVER"] = req.server

        # Find MT5 path
        mt5_path_file = os.path.join(os.environ.get("WINEPREFIX", ""), ".mt5-path")
        mt5_dir = ""
        if os.path.isfile(mt5_path_file):
            with open(mt5_path_file) as f:
                mt5_dir = f.read().strip()

        if not mt5_dir or not os.path.isfile(os.path.join(mt5_dir, "terminal64.exe")):
            raise HTTPException(status_code=500, detail="MT5 installation not found")

        # Generate new config
        config_file = os.path.join(mt5_dir, "mt5-auto.ini")
        with open(config_file, "w") as f:
            f.write(f"""[Common]
Login={req.login}
Password={req.password}
Server={req.server}
KeepPrivate=1
NewsEnable=0
CertInstall=1
[Experts]
AllowLiveTrading=1
AllowDllImport=0
Enabled=1
Account={req.login}
Profile=Default
""")

        # Convert path to Windows format
        try:
            result = subprocess.run(
                ["winepath", "-w", config_file],
                capture_output=True, text=True, timeout=5
            )
            win_config = result.stdout.strip() if result.returncode == 0 else f"Z:{config_file}"
        except Exception:
            win_config = f"Z:{config_file}"

        # Start MT5 with new credentials
        mt5_args = f"/portable /login:{req.login} /password:{req.password} /server:{req.server} /config:{win_config}"
        subprocess.Popen(
            f'wine "{mt5_dir}/terminal64.exe" {mt5_args}',
            shell=True, cwd=mt5_dir,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

        return {
            "success": True,
            "message": f"Switched to account {req.login} on {req.server}. EA will reconnect shortly.",
        }

    finally:
        # Remove lock file
        try:
            os.remove(lock_file)
        except OSError:
            pass


# === Backtesting ===

@app.post("/backtest")
async def run_backtest(req: BacktestRequest):
    """Run a backtest using the existing backtest.sh script."""
    cmd = [
        "/scripts/backtest.sh",
        "--ea", req.ea,
        "--symbol", req.symbol,
        "--period", req.period,
        "--deposit", str(req.deposit),
        "--model", str(req.model),
        "--format", req.format,
    ]
    if req.from_date:
        cmd.extend(["--from", req.from_date])
    if req.to_date:
        cmd.extend(["--to", req.to_date])

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=660,
            env={**os.environ}
        )

        if result.returncode != 0:
            return {
                "success": False,
                "error": result.stderr.strip(),
                "data": None,
            }

        # Parse output based on format
        stdout = result.stdout.strip()
        if req.format == "json" and stdout:
            try:
                data = json.loads(stdout)
            except json.JSONDecodeError:
                data = stdout
        else:
            data = stdout

        return {
            "success": True,
            "data": data,
            "logs": result.stderr.strip(),
        }

    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Backtest timed out (11 min)")


# === Health ===

@app.get("/health", response_model=HealthStatus)
async def health():
    # Check if MT5 is running
    try:
        result = subprocess.run(
            ["pgrep", "-f", "terminal64.exe"],
            capture_output=True, timeout=5
        )
        mt5_running = result.returncode == 0
    except Exception:
        mt5_running = False

    return HealthStatus(
        server="running",
        ea_connected=bridge.connected,
        ea_last_seen=bridge.last_seen,
        mt5_running=mt5_running,
        uptime=time.time() - _start_time,
    )


def main():
    """Entry point for running the API server."""
    import uvicorn

    port = int(os.environ.get("API_PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")


if __name__ == "__main__":
    main()
