from __future__ import annotations

import numpy as np

from .config import EAConfig, InstrumentConfig, Signal, PositionType
from .backtester import BacktestResult


def plot_backtest(
    result: BacktestResult,
    ea_cfg: EAConfig,
    inst_cfg: InstrumentConfig,
    price_data=None,
    show: bool = True,
    save_path: str | None = None,
):
    """4-subplot chart: price + Kalman / equity / Hurst / drawdown."""
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates

    dates = result.dates
    n = len(dates)
    if n == 0:
        print("No data to plot.")
        return

    fig, axes = plt.subplots(4, 1, figsize=(16, 12), sharex=True,
                              gridspec_kw={"height_ratios": [3, 1.5, 1, 1]})

    # --- Subplot 1: Price + Kalman bands + signals ---
    ax1 = axes[0]
    if price_data is not None and len(price_data) >= n:
        # Use the close prices aligned with result dates
        close_vals = price_data["close"].reindex(dates).values
    else:
        close_vals = None

    if close_vals is not None:
        ax1.plot(dates, close_vals, color="black", linewidth=0.8, alpha=0.7, label="Close")
    ax1.plot(dates, result.kalman_levels, color="dodgerblue", linewidth=1.2, label="Kalman Level")
    ax1.plot(dates, result.kalman_upper, color="gray", linewidth=0.6, linestyle="--", label="Upper Band")
    ax1.plot(dates, result.kalman_lower, color="gray", linewidth=0.6, linestyle="--", label="Lower Band")

    # Signal arrows
    for i, sig in enumerate(result.signals):
        if sig == Signal.BUY:
            price_y = result.kalman_lower[i] if close_vals is None else close_vals[i]
            ax1.annotate("", xy=(dates[i], price_y), xytext=(dates[i], price_y * 0.999),
                         arrowprops=dict(arrowstyle="->", color="lime", lw=2))
        elif sig == Signal.SELL:
            price_y = result.kalman_upper[i] if close_vals is None else close_vals[i]
            ax1.annotate("", xy=(dates[i], price_y), xytext=(dates[i], price_y * 1.001),
                         arrowprops=dict(arrowstyle="->", color="red", lw=2))

    # Trade markers from closed trades
    for t in result.trades:
        color = "green" if t.profit > 0 else "red"
        marker_open = "^" if t.type == PositionType.BUY else "v"
        marker_close = "x"
        # Find index in dates
        if t.open_time in dates:
            oi = dates.index(t.open_time)
            ax1.plot(dates[oi], t.open_price, marker=marker_open, color=color,
                     markersize=8, zorder=5)
        if t.close_time in dates:
            ci = dates.index(t.close_time)
            ax1.plot(dates[ci], t.close_price, marker=marker_close, color=color,
                     markersize=8, zorder=5)

    ax1.set_ylabel("Price")
    ax1.set_title(f"MeEA Backtest — {inst_cfg.symbol}")
    ax1.legend(loc="upper left", fontsize=8)
    ax1.grid(True, alpha=0.3)

    # --- Subplot 2: Equity curve ---
    ax2 = axes[1]
    ax2.plot(dates, result.equity_curve, color="navy", linewidth=1.0)
    ax2.axhline(ea_cfg.initial_equity, color="gray", linestyle=":", linewidth=0.7)
    ax2.set_ylabel("Equity")
    ax2.grid(True, alpha=0.3)

    # --- Subplot 3: Hurst exponent ---
    ax3 = axes[2]
    ax3.plot(dates, result.hurst_values, color="purple", linewidth=0.8)
    ax3.axhline(ea_cfg.hurst_threshold, color="orange", linestyle="--",
                linewidth=0.7, label=f"Threshold ({ea_cfg.hurst_threshold})")
    ax3.axhline(0.50, color="gray", linestyle=":", linewidth=0.7, label="Random Walk (0.50)")
    ax3.set_ylabel("Hurst H")
    ax3.set_ylim(0, 1)
    ax3.legend(loc="upper left", fontsize=8)
    ax3.grid(True, alpha=0.3)

    # --- Subplot 4: Drawdown ---
    ax4 = axes[3]
    eq = np.array(result.equity_curve)
    peak = np.maximum.accumulate(eq)
    dd = (peak - eq) / peak
    ax4.fill_between(dates, dd, color="red", alpha=0.4)
    ax4.set_ylabel("Drawdown")
    ax4.set_xlabel("Date")
    ax4.grid(True, alpha=0.3)

    # Format x-axis
    for ax in axes:
        ax.tick_params(axis="x", rotation=30)

    plt.tight_layout()

    if save_path:
        plt.savefig(save_path, dpi=150, bbox_inches="tight")
        print(f"Chart saved to {save_path}")
    if show:
        plt.show()


def _configure_zh_font():
    """Configure matplotlib to use a CJK font available on macOS."""
    import matplotlib.pyplot as plt
    import matplotlib.font_manager as fm

    candidates = ["PingFang SC", "Heiti TC", "Arial Unicode MS"]
    for name in candidates:
        matches = [f for f in fm.fontManager.ttflist if name in f.name]
        if matches:
            plt.rcParams["font.sans-serif"] = [name] + plt.rcParams["font.sans-serif"]
            plt.rcParams["axes.unicode_minus"] = False
            return
    # If nothing matched, just disable minus sign mangling
    plt.rcParams["axes.unicode_minus"] = False


def plot_backtest_zh(
    result: BacktestResult,
    ea_cfg: EAConfig,
    inst_cfg: InstrumentConfig,
    price_data=None,
    show: bool = True,
    save_path: str | None = None,
):
    """4-subplot chart with Chinese labels: price + Kalman / equity / Hurst / drawdown."""
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates

    _configure_zh_font()

    dates = result.dates
    n = len(dates)
    if n == 0:
        print("No data to plot.")
        return

    fig, axes = plt.subplots(4, 1, figsize=(16, 12), sharex=True,
                              gridspec_kw={"height_ratios": [3, 1.5, 1, 1]})

    # --- Subplot 1: Price + Kalman bands + signals ---
    ax1 = axes[0]
    if price_data is not None and len(price_data) >= n:
        close_vals = price_data["close"].reindex(dates).values
    else:
        close_vals = None

    if close_vals is not None:
        ax1.plot(dates, close_vals, color="black", linewidth=0.8, alpha=0.7, label="收盘价")
    ax1.plot(dates, result.kalman_levels, color="dodgerblue", linewidth=1.2, label="卡尔曼水平")
    ax1.plot(dates, result.kalman_upper, color="gray", linewidth=0.6, linestyle="--", label="上轨")
    ax1.plot(dates, result.kalman_lower, color="gray", linewidth=0.6, linestyle="--", label="下轨")

    # Signal arrows
    for i, sig in enumerate(result.signals):
        if sig == Signal.BUY:
            price_y = result.kalman_lower[i] if close_vals is None else close_vals[i]
            ax1.annotate("", xy=(dates[i], price_y), xytext=(dates[i], price_y * 0.999),
                         arrowprops=dict(arrowstyle="->", color="lime", lw=2))
        elif sig == Signal.SELL:
            price_y = result.kalman_upper[i] if close_vals is None else close_vals[i]
            ax1.annotate("", xy=(dates[i], price_y), xytext=(dates[i], price_y * 1.001),
                         arrowprops=dict(arrowstyle="->", color="red", lw=2))

    # Trade markers from closed trades
    for t in result.trades:
        color = "green" if t.profit > 0 else "red"
        marker_open = "^" if t.type == PositionType.BUY else "v"
        marker_close = "x"
        if t.open_time in dates:
            oi = dates.index(t.open_time)
            ax1.plot(dates[oi], t.open_price, marker=marker_open, color=color,
                     markersize=8, zorder=5)
        if t.close_time in dates:
            ci = dates.index(t.close_time)
            ax1.plot(dates[ci], t.close_price, marker=marker_close, color=color,
                     markersize=8, zorder=5)

    ax1.set_ylabel("价格")
    ax1.set_title(f"MeEA 回测 — {inst_cfg.symbol}")
    ax1.legend(loc="upper left", fontsize=8)
    ax1.grid(True, alpha=0.3)

    # --- Subplot 2: Equity curve ---
    ax2 = axes[1]
    ax2.plot(dates, result.equity_curve, color="navy", linewidth=1.0)
    ax2.axhline(ea_cfg.initial_equity, color="gray", linestyle=":", linewidth=0.7)
    ax2.set_ylabel("权益")
    ax2.grid(True, alpha=0.3)

    # --- Subplot 3: Hurst exponent ---
    ax3 = axes[2]
    ax3.plot(dates, result.hurst_values, color="purple", linewidth=0.8)
    ax3.axhline(ea_cfg.hurst_threshold, color="orange", linestyle="--",
                linewidth=0.7, label=f"阈值 ({ea_cfg.hurst_threshold})")
    ax3.axhline(0.50, color="gray", linestyle=":", linewidth=0.7, label="随机游走 (0.50)")
    ax3.set_ylabel("Hurst H")
    ax3.set_ylim(0, 1)
    ax3.legend(loc="upper left", fontsize=8)
    ax3.grid(True, alpha=0.3)

    # --- Subplot 4: Drawdown ---
    ax4 = axes[3]
    eq = np.array(result.equity_curve)
    peak = np.maximum.accumulate(eq)
    dd = (peak - eq) / peak
    ax4.fill_between(dates, dd, color="red", alpha=0.4)
    ax4.set_ylabel("回撤")
    ax4.set_xlabel("日期")
    ax4.grid(True, alpha=0.3)

    # Format x-axis
    for ax in axes:
        ax.tick_params(axis="x", rotation=30)

    plt.tight_layout()

    if save_path:
        plt.savefig(save_path, dpi=150, bbox_inches="tight")
        print(f"Chart saved to {save_path}")
    if show:
        plt.show()
