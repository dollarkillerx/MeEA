from dataclasses import dataclass, field
from enum import Enum


class VolRegime(Enum):
    LOW = 0
    NORMAL = 1
    HIGH = 2


class Signal(Enum):
    NONE = 0
    BUY = 1
    SELL = 2
    CLOSE_BUY = 3
    CLOSE_SELL = 4


class PositionType(Enum):
    BUY = 0
    SELL = 1


@dataclass
class EAConfig:
    # Kalman Filter
    kf_process_noise: float = 0.01
    kf_observ_noise: float = 1.0
    kf_conf_band: float = 2.0

    # Hurst Exponent
    hurst_period: int = 200
    hurst_threshold: float = 0.55

    # Volatility Regime
    vol_period: int = 100
    vol_hist_period: int = 500

    # Risk Management
    risk_per_trade: float = 0.01
    max_positions: int = 3
    max_daily_dd: float = 0.03
    max_spread_points: float = 30.0

    # Trend holding
    hurst_exit_threshold: float = 0.40
    trail_multiplier: float = 3.0
    min_hold_bars: int = 5

    # Execution
    slippage_points: float = 10.0
    close_cooldown: int = 2

    # Account (backtest only)
    initial_equity: float = 10000.0
    leverage: int = 100


@dataclass
class InstrumentConfig:
    symbol: str = "EURUSD"
    digits: int = 5
    point: float = 0.00001
    point_value: float = 1.0       # value of 1 point move per standard lot (in USD)
    min_lot: float = 0.01
    max_lot: float = 100.0
    lot_step: float = 0.01
    spread_points: float = 15.0
    contract_size: float = 100_000.0


# Preset instrument configurations
_INSTRUMENTS = {
    "EURUSD": InstrumentConfig(
        symbol="EURUSD", digits=5, point=0.00001,
        point_value=1.0, spread_points=15.0, contract_size=100_000.0,
    ),
    "GBPUSD": InstrumentConfig(
        symbol="GBPUSD", digits=5, point=0.00001,
        point_value=1.0, spread_points=18.0, contract_size=100_000.0,
    ),
    "USDJPY": InstrumentConfig(
        symbol="USDJPY", digits=3, point=0.001,
        point_value=0.67, spread_points=15.0, contract_size=100_000.0,
    ),
    "AUDUSD": InstrumentConfig(
        symbol="AUDUSD", digits=5, point=0.00001,
        point_value=1.0, spread_points=18.0, contract_size=100_000.0,
    ),
    "XAUUSD": InstrumentConfig(
        symbol="XAUUSD", digits=2, point=0.01,
        point_value=1.0, spread_points=30.0, contract_size=100.0,
    ),
}


def get_instrument(symbol: str) -> InstrumentConfig:
    key = symbol.upper()
    if key in _INSTRUMENTS:
        return _INSTRUMENTS[key]
    raise ValueError(
        f"Unknown symbol '{symbol}'. Available: {list(_INSTRUMENTS.keys())}"
    )
