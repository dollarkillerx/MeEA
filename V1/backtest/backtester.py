from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from .config import EAConfig, InstrumentConfig, Signal, PositionType, VolRegime
from .signal_engine import SignalEngine
from .risk_manager import RiskManager
from .position import Position, ClosedTrade


@dataclass
class BacktestResult:
    equity_curve: list[float] = field(default_factory=list)
    trades: list[ClosedTrade] = field(default_factory=list)
    kalman_levels: list[float] = field(default_factory=list)
    kalman_upper: list[float] = field(default_factory=list)
    kalman_lower: list[float] = field(default_factory=list)
    hurst_values: list[float] = field(default_factory=list)
    vol_regimes: list[VolRegime] = field(default_factory=list)
    signals: list[Signal] = field(default_factory=list)
    dates: list[object] = field(default_factory=list)


class Backtester:
    """Bar-by-bar backtester mirroring MeEA.mq5 OnTick loop."""

    def __init__(self, ea_cfg: EAConfig, inst_cfg: InstrumentConfig):
        self._ea = ea_cfg
        self._inst = inst_cfg

    def run(self, data: pd.DataFrame) -> BacktestResult:
        closes = data["close"].values.astype(float)
        highs = data["high"].values.astype(float)
        lows = data["low"].values.astype(float)
        dates = data.index.tolist()
        n_bars = len(closes)

        # --- Init modules ---
        signal_engine = SignalEngine()
        signal_engine.init(
            self._ea.kf_process_noise, self._ea.kf_observ_noise,
            self._ea.kf_conf_band, self._ea.hurst_period,
            self._ea.hurst_threshold, self._ea.vol_period,
            self._ea.vol_hist_period,
            hurst_exit_threshold=self._ea.hurst_exit_threshold,
        )
        risk_mgr = RiskManager(self._ea, self._inst)

        # --- State ---
        equity = self._ea.initial_equity
        realized_pnl = 0.0
        positions: list[Position] = []
        closed_trades: list[ClosedTrade] = []
        next_ticket = 1

        bars_since_close = 100  # start high to allow initial trades
        last_day = None

        # Spread / slippage in price terms
        half_spread = self._inst.spread_points * self._inst.point / 2.0
        slippage = self._ea.slippage_points * self._inst.point

        # --- Recording arrays ---
        result = BacktestResult()

        # --- Warmup ---
        warmup_bars = max(self._ea.hurst_period, self._ea.vol_hist_period) + 50
        warmup_bars = min(warmup_bars, n_bars - 1)

        # First bar: init Kalman with same-value prev
        signal_engine.on_new_bar(closes[0], closes[0])
        for i in range(1, warmup_bars):
            signal_engine.on_new_bar(closes[i], closes[i - 1])

        # --- Main trading loop ---
        for i in range(warmup_bars, n_bars):
            entry_this_bar = False
            bars_since_close += 1

            # New day detection
            current_date = dates[i]
            if hasattr(current_date, "date"):
                today = current_date.date()
            else:
                today = current_date
            if today != last_day:
                risk_mgr.on_new_day(equity)
                last_day = today

            # Feed new bar
            signal_engine.on_new_bar(closes[i], closes[i - 1])

            bar_close = closes[i]
            bar_high = highs[i]
            bar_low = lows[i]

            # --- Stop loss check (use high/low of bar) ---
            sl_closed: list[int] = []
            for idx, pos in enumerate(positions):
                if pos.type == PositionType.BUY and bar_low <= pos.stop_loss:
                    # SL hit — close at SL price
                    close_price = pos.stop_loss
                    pnl = (close_price - pos.open_price) * pos.lots * self._inst.contract_size
                    realized_pnl += pnl
                    closed_trades.append(ClosedTrade(
                        ticket=pos.ticket, type=pos.type,
                        open_time=pos.open_time, close_time=current_date,
                        open_price=pos.open_price, close_price=close_price,
                        lots=pos.lots, profit=pnl,
                        close_reason="stop_loss",
                        entry_bar_index=pos.entry_bar_index,
                        exit_bar_index=i,
                    ))
                    sl_closed.append(idx)
                    bars_since_close = 0
                elif pos.type == PositionType.SELL and bar_high >= pos.stop_loss:
                    close_price = pos.stop_loss
                    pnl = (pos.open_price - close_price) * pos.lots * self._inst.contract_size
                    realized_pnl += pnl
                    closed_trades.append(ClosedTrade(
                        ticket=pos.ticket, type=pos.type,
                        open_time=pos.open_time, close_time=current_date,
                        open_price=pos.open_price, close_price=close_price,
                        lots=pos.lots, profit=pnl,
                        close_reason="stop_loss",
                        entry_bar_index=pos.entry_bar_index,
                        exit_bar_index=i,
                    ))
                    sl_closed.append(idx)
                    bars_since_close = 0

            # Remove SL-closed positions (reverse order to keep indices valid)
            for idx in sorted(sl_closed, reverse=True):
                positions.pop(idx)

            # --- Signal exit (skip positions held < min_hold_bars) ---
            min_hold = self._ea.min_hold_bars
            if any(p.type == PositionType.BUY for p in positions) and signal_engine.should_close_buy():
                bid = bar_close - half_spread
                to_close = [p for p in positions if p.type == PositionType.BUY and (i - p.entry_bar_index) >= min_hold]
                for pos in to_close:
                    pnl = (bid - pos.open_price) * pos.lots * self._inst.contract_size
                    realized_pnl += pnl
                    closed_trades.append(ClosedTrade(
                        ticket=pos.ticket, type=pos.type,
                        open_time=pos.open_time, close_time=current_date,
                        open_price=pos.open_price, close_price=bid,
                        lots=pos.lots, profit=pnl,
                        close_reason="signal",
                        entry_bar_index=pos.entry_bar_index,
                        exit_bar_index=i,
                    ))
                    positions.remove(pos)
                bars_since_close = 0

            if any(p.type == PositionType.SELL for p in positions) and signal_engine.should_close_sell():
                ask = bar_close + half_spread
                to_close = [p for p in positions if p.type == PositionType.SELL and (i - p.entry_bar_index) >= min_hold]
                for pos in to_close:
                    pnl = (pos.open_price - ask) * pos.lots * self._inst.contract_size
                    realized_pnl += pnl
                    closed_trades.append(ClosedTrade(
                        ticket=pos.ticket, type=pos.type,
                        open_time=pos.open_time, close_time=current_date,
                        open_price=pos.open_price, close_price=ask,
                        lots=pos.lots, profit=pnl,
                        close_reason="signal",
                        entry_bar_index=pos.entry_bar_index,
                        exit_bar_index=i,
                    ))
                    positions.remove(pos)
                bars_since_close = 0

            # --- Entry signal ---
            entry_signal = signal_engine.get_entry_signal(bar_close)

            # Reverse position protection
            if entry_signal == Signal.BUY and any(p.type == PositionType.SELL for p in positions):
                entry_signal = Signal.NONE
            if entry_signal == Signal.SELL and any(p.type == PositionType.BUY for p in positions):
                entry_signal = Signal.NONE

            # Cooldown
            if entry_signal != Signal.NONE and bars_since_close < self._ea.close_cooldown:
                entry_signal = Signal.NONE

            if entry_signal != Signal.NONE:
                kalman_level = signal_engine.get_kalman_level()
                est_error = signal_engine.get_estimation_error()
                regime = signal_engine.get_vol_regime()

                sl = risk_mgr.get_stop_loss(entry_signal, kalman_level, est_error, self._ea.kf_conf_band)

                if entry_signal == Signal.BUY:
                    entry_price = bar_close + half_spread + slippage
                else:
                    entry_price = bar_close - half_spread - slippage

                stop_points = risk_mgr.get_stop_points(entry_price, sl, self._inst.point)
                lots = risk_mgr.calc_lots(stop_points, regime, equity, positions, entry_price)

                if lots > 0.0 and risk_mgr.can_open_trade(
                    positions, equity, self._inst.spread_points, lots, entry_price
                ):
                    pos = Position(
                        ticket=next_ticket,
                        type=PositionType.BUY if entry_signal == Signal.BUY else PositionType.SELL,
                        open_time=current_date,
                        open_price=entry_price,
                        lots=lots,
                        stop_loss=sl,
                        entry_bar_index=i,
                    )
                    positions.append(pos)
                    next_ticket += 1
                    entry_this_bar = True

            # --- Trailing stop (skip entry bar + min hold bars) ---
            if not entry_this_bar and positions:
                level = signal_engine.get_kalman_level()
                err = signal_engine.get_estimation_error()
                trail_buy = level - err * self._ea.trail_multiplier
                trail_sell = level + err * self._ea.trail_multiplier

                for pos in positions:
                    if pos.entry_bar_index == i:
                        continue  # skip positions opened this bar
                    if (i - pos.entry_bar_index) < min_hold:
                        continue  # skip positions held less than min_hold_bars
                    if pos.type == PositionType.BUY and trail_buy > 0.0:
                        if pos.stop_loss > 0.0 and trail_buy > pos.stop_loss:
                            pos.stop_loss = trail_buy
                    elif pos.type == PositionType.SELL and trail_sell > 0.0:
                        if pos.stop_loss > 0.0 and trail_sell < pos.stop_loss:
                            pos.stop_loss = trail_sell

            # --- Update equity ---
            unrealized = 0.0
            for pos in positions:
                if pos.type == PositionType.BUY:
                    unrealized += (bar_close - pos.open_price) * pos.lots * self._inst.contract_size
                else:
                    unrealized += (pos.open_price - bar_close) * pos.lots * self._inst.contract_size

            equity = self._ea.initial_equity + realized_pnl + unrealized

            # --- Record ---
            result.equity_curve.append(equity)
            result.kalman_levels.append(signal_engine.get_kalman_level())
            result.kalman_upper.append(signal_engine.get_upper_band())
            result.kalman_lower.append(signal_engine.get_lower_band())
            result.hurst_values.append(signal_engine.get_hurst())
            result.vol_regimes.append(signal_engine.get_vol_regime())
            result.signals.append(entry_signal if entry_this_bar else Signal.NONE)
            result.dates.append(current_date)

        # --- Close remaining positions at last bar ---
        if positions:
            last_close = closes[-1]
            last_date = dates[-1]
            for pos in positions:
                if pos.type == PositionType.BUY:
                    cp = last_close - half_spread
                    pnl = (cp - pos.open_price) * pos.lots * self._inst.contract_size
                else:
                    cp = last_close + half_spread
                    pnl = (pos.open_price - cp) * pos.lots * self._inst.contract_size
                realized_pnl += pnl
                closed_trades.append(ClosedTrade(
                    ticket=pos.ticket, type=pos.type,
                    open_time=pos.open_time, close_time=last_date,
                    open_price=pos.open_price, close_price=cp,
                    lots=pos.lots, profit=pnl,
                    close_reason="end_of_data",
                    entry_bar_index=pos.entry_bar_index,
                    exit_bar_index=n_bars - 1,
                ))

        result.trades = closed_trades
        return result
