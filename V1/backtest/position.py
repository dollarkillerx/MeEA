from __future__ import annotations

from dataclasses import dataclass, field

from .config import PositionType


@dataclass
class Position:
    ticket: int
    type: PositionType
    open_time: object          # pandas Timestamp or datetime
    open_price: float
    lots: float
    stop_loss: float
    entry_bar_index: int


@dataclass
class ClosedTrade:
    ticket: int
    type: PositionType
    open_time: object
    close_time: object
    open_price: float
    close_price: float
    lots: float
    profit: float
    close_reason: str          # "signal", "stop_loss", "end_of_data"
    entry_bar_index: int
    exit_bar_index: int
