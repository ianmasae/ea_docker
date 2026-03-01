"""Pydantic models for the MT5 Trading API."""

from typing import Optional
from pydantic import BaseModel, Field


# === Request Models ===

class TradeRequest(BaseModel):
    symbol: str
    volume: float = Field(gt=0)
    sl: Optional[float] = None
    tp: Optional[float] = None
    comment: Optional[str] = ""


class CloseRequest(BaseModel):
    ticket: int


class ModifyRequest(BaseModel):
    ticket: int
    sl: Optional[float] = None
    tp: Optional[float] = None


class LoginRequest(BaseModel):
    login: int
    password: str
    server: str


class HistoryRequest(BaseModel):
    from_ts: Optional[int] = None  # Unix timestamp
    to_ts: Optional[int] = None


class BacktestRequest(BaseModel):
    ea: str
    symbol: str = "Volatility 10 (1s) Index"
    period: str = "H1"
    from_date: Optional[str] = None  # YYYY.MM.DD
    to_date: Optional[str] = None
    deposit: int = 10000
    model: int = 0
    format: str = "json"


# === Response Models ===

class AccountInfo(BaseModel):
    login: int = 0
    balance: float = 0.0
    equity: float = 0.0
    margin: float = 0.0
    free_margin: float = 0.0
    leverage: int = 0
    currency: str = ""
    server: str = ""
    name: str = ""
    company: str = ""
    trade_allowed: bool = False


class Position(BaseModel):
    ticket: int = 0
    symbol: str = ""
    type: int = 0  # 0=buy, 1=sell
    volume: float = 0.0
    price_open: float = 0.0
    price_current: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    profit: float = 0.0
    swap: float = 0.0
    commission: float = 0.0
    time: int = 0  # Unix timestamp
    magic: int = 0
    comment: str = ""


class Order(BaseModel):
    ticket: int = 0
    symbol: str = ""
    type: int = 0
    volume_initial: float = 0.0
    volume_current: float = 0.0
    price_open: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    time_setup: int = 0
    time_done: int = 0
    state: int = 0
    magic: int = 0
    comment: str = ""


class Deal(BaseModel):
    ticket: int = 0
    order: int = 0
    symbol: str = ""
    type: int = 0
    direction: int = 0
    volume: float = 0.0
    price: float = 0.0
    commission: float = 0.0
    swap: float = 0.0
    profit: float = 0.0
    time: int = 0
    magic: int = 0
    comment: str = ""


class SymbolInfo(BaseModel):
    name: str = ""
    bid: float = 0.0
    ask: float = 0.0
    spread: int = 0
    digits: int = 0
    volume_min: float = 0.0
    volume_max: float = 0.0
    volume_step: float = 0.0
    trade_mode: int = 0
    point: float = 0.0
    tick_size: float = 0.0
    tick_value: float = 0.0
    swap_long: float = 0.0
    swap_short: float = 0.0


class Tick(BaseModel):
    symbol: str = ""
    bid: float = 0.0
    ask: float = 0.0
    last: float = 0.0
    volume: float = 0.0
    time: int = 0


class TradeResult(BaseModel):
    success: bool = False
    retcode: int = 0
    order: int = 0
    deal: int = 0
    volume: float = 0.0
    price: float = 0.0
    comment: str = ""


class HealthStatus(BaseModel):
    server: str = "running"
    ea_connected: bool = False
    ea_last_seen: Optional[float] = None
    mt5_running: bool = False
    uptime: float = 0.0
