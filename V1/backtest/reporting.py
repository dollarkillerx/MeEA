from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import pandas as pd

from .config import EAConfig, InstrumentConfig, PositionType
from .backtester import BacktestResult
from .position import ClosedTrade


@dataclass
class Metrics:
    # Account
    initial_equity: float = 0.0
    final_equity: float = 0.0
    leverage: int = 0
    symbol: str = ""
    start_date: str = ""
    end_date: str = ""
    total_bars: int = 0

    # Trade stats
    total_trades: int = 0
    buy_trades: int = 0
    sell_trades: int = 0
    winning_trades: int = 0
    losing_trades: int = 0
    win_rate: float = 0.0
    avg_win: float = 0.0
    avg_loss: float = 0.0
    profit_loss_ratio: float = 0.0
    max_consec_wins: int = 0
    max_consec_losses: int = 0

    # Returns
    net_profit: float = 0.0
    gross_profit: float = 0.0
    gross_loss: float = 0.0
    profit_factor: float = 0.0
    cagr: float = 0.0

    # Risk
    sharpe_ratio: float = 0.0
    sortino_ratio: float = 0.0
    max_drawdown_pct: float = 0.0
    max_drawdown_duration: int = 0
    max_single_loss: float = 0.0

    # Position / margin
    avg_hold_bars: float = 0.0
    max_concurrent_positions: int = 0
    max_margin_usage_pct: float = 0.0


def compute_metrics(
    result: BacktestResult,
    ea_cfg: EAConfig,
    inst_cfg: InstrumentConfig,
    total_data_bars: int,
) -> Metrics:
    m = Metrics()
    m.initial_equity = ea_cfg.initial_equity
    m.final_equity = result.equity_curve[-1] if result.equity_curve else ea_cfg.initial_equity
    m.leverage = ea_cfg.leverage
    m.symbol = inst_cfg.symbol
    m.total_bars = total_data_bars

    if result.dates:
        m.start_date = str(result.dates[0])
        m.end_date = str(result.dates[-1])

    trades = result.trades
    m.total_trades = len(trades)
    if m.total_trades == 0:
        return m

    m.buy_trades = sum(1 for t in trades if t.type == PositionType.BUY)
    m.sell_trades = sum(1 for t in trades if t.type == PositionType.SELL)

    wins = [t for t in trades if t.profit > 0]
    losses = [t for t in trades if t.profit <= 0]
    m.winning_trades = len(wins)
    m.losing_trades = len(losses)
    m.win_rate = m.winning_trades / m.total_trades if m.total_trades else 0.0

    m.gross_profit = sum(t.profit for t in wins)
    m.gross_loss = abs(sum(t.profit for t in losses))
    m.net_profit = m.gross_profit - m.gross_loss

    m.avg_win = m.gross_profit / m.winning_trades if m.winning_trades else 0.0
    m.avg_loss = m.gross_loss / m.losing_trades if m.losing_trades else 0.0
    m.profit_loss_ratio = m.avg_win / m.avg_loss if m.avg_loss > 0 else float("inf")
    m.profit_factor = m.gross_profit / m.gross_loss if m.gross_loss > 0 else float("inf")

    # Max consecutive wins/losses
    streak_w = streak_l = max_w = max_l = 0
    for t in trades:
        if t.profit > 0:
            streak_w += 1
            streak_l = 0
        else:
            streak_l += 1
            streak_w = 0
        max_w = max(max_w, streak_w)
        max_l = max(max_l, streak_l)
    m.max_consec_wins = max_w
    m.max_consec_losses = max_l

    # CAGR
    eq = np.array(result.equity_curve)
    n_periods = len(eq)
    if n_periods > 1 and eq[0] > 0 and eq[-1] > 0:
        # Assume ~252 trading days per year for daily data
        years = n_periods / 252.0
        if years > 0:
            m.cagr = (eq[-1] / eq[0]) ** (1.0 / years) - 1.0

    # Sharpe & Sortino (annualised from bar returns)
    if n_periods > 1:
        returns = np.diff(eq) / eq[:-1]
        avg_ret = np.mean(returns)
        std_ret = np.std(returns, ddof=1)
        if std_ret > 0:
            m.sharpe_ratio = avg_ret / std_ret * math.sqrt(252)
        downside = returns[returns < 0]
        down_std = np.std(downside, ddof=1) if len(downside) > 1 else 0.0
        if down_std > 0:
            m.sortino_ratio = avg_ret / down_std * math.sqrt(252)

    # Max drawdown
    peak = eq[0]
    max_dd = 0.0
    dd_start = 0
    max_dd_dur = 0
    cur_dur = 0
    for i in range(len(eq)):
        if eq[i] > peak:
            peak = eq[i]
            cur_dur = 0
        dd = (peak - eq[i]) / peak
        if dd > max_dd:
            max_dd = dd
        if dd > 0:
            cur_dur += 1
            max_dd_dur = max(max_dd_dur, cur_dur)
        else:
            cur_dur = 0
    m.max_drawdown_pct = max_dd
    m.max_drawdown_duration = max_dd_dur

    # Max single loss
    m.max_single_loss = min(t.profit for t in trades) if trades else 0.0

    # Average hold duration in bars
    hold_bars = [t.exit_bar_index - t.entry_bar_index for t in trades]
    m.avg_hold_bars = sum(hold_bars) / len(hold_bars) if hold_bars else 0.0

    # Max concurrent positions (scan equity curve interval)
    # Approximate by checking at each trade-event bar
    from collections import Counter
    bar_opens: Counter[int] = Counter()
    bar_closes: Counter[int] = Counter()
    for t in trades:
        bar_opens[t.entry_bar_index] += 1
        bar_closes[t.exit_bar_index] += 1
    all_bars = sorted(set(bar_opens.keys()) | set(bar_closes.keys()))
    cur = 0
    max_conc = 0
    for b in all_bars:
        cur += bar_opens.get(b, 0)
        if cur > max_conc:
            max_conc = cur
        cur -= bar_closes.get(b, 0)
    m.max_concurrent_positions = max_conc

    # Max margin usage
    # Rough estimate: peak used_margin / equity
    max_margin_pct = 0.0
    cur_positions: list[ClosedTrade] = []
    events: list[tuple[int, str, ClosedTrade]] = []
    for t in trades:
        events.append((t.entry_bar_index, "open", t))
        events.append((t.exit_bar_index, "close", t))
    events.sort(key=lambda x: (x[0], 0 if x[1] == "close" else 1))
    active: list[ClosedTrade] = []
    for bar_idx, action, trade in events:
        if action == "open":
            active.append(trade)
        else:
            active = [a for a in active if a.ticket != trade.ticket]
        if active:
            used = sum(
                (a.lots * inst_cfg.contract_size * a.open_price) / ea_cfg.leverage
                for a in active
            )
            eq_idx = bar_idx - (total_data_bars - len(result.equity_curve))
            if 0 <= eq_idx < len(result.equity_curve):
                eq_val = result.equity_curve[eq_idx]
                if eq_val > 0:
                    ratio = used / eq_val
                    if ratio > max_margin_pct:
                        max_margin_pct = ratio
    m.max_margin_usage_pct = max_margin_pct

    return m


def print_report(m: Metrics):
    w = 40  # label width
    sep = "=" * 60

    print(f"\n{sep}")
    print("  MeEA BACKTEST REPORT")
    print(sep)

    print("\n--- Account ---")
    print(f"{'Symbol:':<{w}} {m.symbol}")
    print(f"{'Initial Equity:':<{w}} {m.initial_equity:,.2f}")
    print(f"{'Final Equity:':<{w}} {m.final_equity:,.2f}")
    print(f"{'Leverage:':<{w}} 1:{m.leverage}")
    print(f"{'Period:':<{w}} {m.start_date} — {m.end_date}")
    print(f"{'Data Bars:':<{w}} {m.total_bars}")

    print("\n--- Trade Statistics ---")
    print(f"{'Total Trades:':<{w}} {m.total_trades}")
    print(f"{'  Buy / Sell:':<{w}} {m.buy_trades} / {m.sell_trades}")
    print(f"{'  Win / Loss:':<{w}} {m.winning_trades} / {m.losing_trades}")
    print(f"{'Win Rate:':<{w}} {m.win_rate:.1%}")
    print(f"{'Avg Win:':<{w}} {m.avg_win:,.2f}")
    print(f"{'Avg Loss:':<{w}} {m.avg_loss:,.2f}")
    pf_str = f"{m.profit_loss_ratio:.2f}" if m.profit_loss_ratio != float("inf") else "inf"
    print(f"{'Profit/Loss Ratio:':<{w}} {pf_str}")
    print(f"{'Max Consec. Wins:':<{w}} {m.max_consec_wins}")
    print(f"{'Max Consec. Losses:':<{w}} {m.max_consec_losses}")

    print("\n--- Returns ---")
    print(f"{'Net Profit:':<{w}} {m.net_profit:,.2f}")
    print(f"{'Gross Profit:':<{w}} {m.gross_profit:,.2f}")
    print(f"{'Gross Loss:':<{w}} {m.gross_loss:,.2f}")
    pf_str = f"{m.profit_factor:.2f}" if m.profit_factor != float("inf") else "inf"
    print(f"{'Profit Factor:':<{w}} {pf_str}")
    print(f"{'CAGR:':<{w}} {m.cagr:.2%}")

    print("\n--- Risk ---")
    print(f"{'Sharpe Ratio:':<{w}} {m.sharpe_ratio:.3f}")
    print(f"{'Sortino Ratio:':<{w}} {m.sortino_ratio:.3f}")
    print(f"{'Max Drawdown:':<{w}} {m.max_drawdown_pct:.2%}")
    print(f"{'Max DD Duration (bars):':<{w}} {m.max_drawdown_duration}")
    print(f"{'Max Single Loss:':<{w}} {m.max_single_loss:,.2f}")

    print("\n--- Position / Margin ---")
    print(f"{'Avg Hold Duration (bars):':<{w}} {m.avg_hold_bars:.1f}")
    print(f"{'Max Concurrent Positions:':<{w}} {m.max_concurrent_positions}")
    print(f"{'Max Margin Usage:':<{w}} {m.max_margin_usage_pct:.1%}")

    print(sep)


def print_report_zh(m: Metrics):
    w = 40  # label width
    sep = "═" * 39

    print(f"\n{sep}")
    print("  MeEA 回测报告")
    print(sep)

    print("\n--- 账户信息 ---")
    print(f"{'交易品种:':<{w}} {m.symbol}")
    print(f"{'初始资金:':<{w}} {m.initial_equity:,.2f}")
    print(f"{'最终权益:':<{w}} {m.final_equity:,.2f}")
    print(f"{'杠杆:':<{w}} 1:{m.leverage}")
    print(f"{'回测区间:':<{w}} {m.start_date} — {m.end_date}")
    print(f"{'数据K线数:':<{w}} {m.total_bars}")

    print("\n--- 交易统计 ---")
    print(f"{'总交易次数:':<{w}} {m.total_trades}")
    print(f"{'  做多 / 做空:':<{w}} {m.buy_trades} / {m.sell_trades}")
    print(f"{'  盈利 / 亏损:':<{w}} {m.winning_trades} / {m.losing_trades}")
    print(f"{'胜率:':<{w}} {m.win_rate:.1%}")
    print(f"{'平均盈利:':<{w}} {m.avg_win:,.2f}")
    print(f"{'平均亏损:':<{w}} {m.avg_loss:,.2f}")
    pf_str = f"{m.profit_loss_ratio:.2f}" if m.profit_loss_ratio != float("inf") else "inf"
    print(f"{'盈亏比:':<{w}} {pf_str}")
    print(f"{'最大连续盈利:':<{w}} {m.max_consec_wins}")
    print(f"{'最大连续亏损:':<{w}} {m.max_consec_losses}")

    print("\n--- 收益 ---")
    print(f"{'净利润:':<{w}} {m.net_profit:,.2f}")
    print(f"{'总盈利:':<{w}} {m.gross_profit:,.2f}")
    print(f"{'总亏损:':<{w}} {m.gross_loss:,.2f}")
    pf_str = f"{m.profit_factor:.2f}" if m.profit_factor != float("inf") else "inf"
    print(f"{'利润因子:':<{w}} {pf_str}")
    print(f"{'年化收益率(CAGR):':<{w}} {m.cagr:.2%}")

    print("\n--- 风险 ---")
    print(f"{'夏普比率:':<{w}} {m.sharpe_ratio:.3f}")
    print(f"{'索提诺比率:':<{w}} {m.sortino_ratio:.3f}")
    print(f"{'最大回撤:':<{w}} {m.max_drawdown_pct:.2%}")
    print(f"{'最大回撤持续(K线):':<{w}} {m.max_drawdown_duration}")
    print(f"{'单笔最大亏损:':<{w}} {m.max_single_loss:,.2f}")

    print("\n--- 仓位 / 保证金 ---")
    print(f"{'平均持仓时长(K线):':<{w}} {m.avg_hold_bars:.1f}")
    print(f"{'最大同时持仓数:':<{w}} {m.max_concurrent_positions}")
    print(f"{'最大保证金使用率:':<{w}} {m.max_margin_usage_pct:.1%}")

    print(sep)


def trades_to_dataframe(trades: list[ClosedTrade]) -> pd.DataFrame:
    if not trades:
        return pd.DataFrame()
    records = []
    for t in trades:
        records.append({
            "ticket": t.ticket,
            "type": t.type.name,
            "open_time": t.open_time,
            "close_time": t.close_time,
            "open_price": t.open_price,
            "close_price": t.close_price,
            "lots": t.lots,
            "profit": t.profit,
            "close_reason": t.close_reason,
            "hold_bars": t.exit_bar_index - t.entry_bar_index,
        })
    return pd.DataFrame(records)
