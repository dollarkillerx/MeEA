from __future__ import annotations

import math

from .config import EAConfig, InstrumentConfig, VolRegime, Signal, PositionType
from .position import Position


class RiskManager:
    """Risk management & position sizing.

    Adapted from CRiskManager.mqh for backtest context:
    replaces broker calls with explicit equity/margin calculations.
    """

    def __init__(self, ea_cfg: EAConfig, inst_cfg: InstrumentConfig):
        self._ea = ea_cfg
        self._inst = inst_cfg
        self._day_start_equity = ea_cfg.initial_equity

    def on_new_day(self, equity: float):
        self._day_start_equity = equity

    # --- Margin helpers (new for backtest) ---

    def calc_margin(self, lots: float, price: float) -> float:
        """Required margin to open *lots* at *price*."""
        return (lots * self._inst.contract_size * price) / self._ea.leverage

    def get_used_margin(self, positions: list[Position]) -> float:
        total = 0.0
        for pos in positions:
            total += self.calc_margin(pos.lots, pos.open_price)
        return total

    def get_free_margin(self, equity: float, positions: list[Position]) -> float:
        return equity - self.get_used_margin(positions)

    # --- Position sizing ---

    def calc_lots(
        self,
        stop_points: float,
        regime: VolRegime,
        equity: float,
        positions: list[Position],
        entry_price: float,
    ) -> float:
        if stop_points <= 0.0:
            return 0.0

        point_val = self._inst.point_value
        if point_val <= 0.0:
            return 0.0

        risk_amount = equity * self._ea.risk_per_trade
        lots = risk_amount / (stop_points * point_val)

        # Volatility regime adjustment
        if regime == VolRegime.LOW:
            lots *= 0.5
        elif regime == VolRegime.HIGH:
            lots *= 0.7

        # Normalize to lot constraints
        step = self._inst.lot_step
        if step > 0.0:
            lots = math.floor(lots / step) * step

        lots = max(lots, self._inst.min_lot)
        lots = min(lots, self._inst.max_lot)

        # Margin constraint: shrink lots if margin insufficient
        free = self.get_free_margin(equity, positions)
        required = self.calc_margin(lots, entry_price)
        if required > free:
            if free <= 0:
                return 0.0
            lots = (free * self._ea.leverage) / (self._inst.contract_size * entry_price)
            if step > 0.0:
                lots = math.floor(lots / step) * step
            if lots < self._inst.min_lot:
                return 0.0

        return lots

    # --- Trade gating ---

    def can_open_trade(
        self,
        positions: list[Position],
        equity: float,
        spread_points: float,
        new_lots: float,
        new_price: float,
    ) -> bool:
        # Max positions
        if len(positions) >= self._ea.max_positions:
            return False

        # Daily drawdown
        if self._day_start_equity > 0.0:
            day_pnl = equity - self._day_start_equity
            if day_pnl < 0 and abs(day_pnl) / self._day_start_equity > self._ea.max_daily_dd:
                return False

        # Spread check
        if spread_points > self._ea.max_spread_points:
            return False

        # Margin check
        required = self.calc_margin(new_lots, new_price)
        free = self.get_free_margin(equity, positions)
        if free < required:
            return False

        return True

    # --- Stop loss ---

    def get_stop_loss(
        self, signal: Signal, kalman_level: float,
        est_error: float, multiplier: float,
    ) -> float:
        stop_dist = est_error * multiplier
        if signal == Signal.BUY:
            return kalman_level - stop_dist
        elif signal == Signal.SELL:
            return kalman_level + stop_dist
        return 0.0

    @staticmethod
    def get_stop_points(
        entry_price: float, stop_loss: float, point: float,
    ) -> float:
        return abs(entry_price - stop_loss) / point
