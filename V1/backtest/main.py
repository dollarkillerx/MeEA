"""MeEA Python Backtest — entry point.

Usage examples:

  # CSV data
  python -m backtest.main --equity 10000 --leverage 100 --symbol EURUSD \
      --data backtest/data/EURUSD_H1.csv

  # yfinance daily download
  python -m backtest.main --equity 5000 --leverage 200 --symbol GBPUSD \
      --download --start 2023-01-01 --end 2024-12-31

  # Override strategy parameters
  python -m backtest.main --equity 10000 --leverage 100 --symbol EURUSD \
      --data data.csv --risk 0.02 --max-positions 5
"""
from __future__ import annotations

import argparse
import sys

from .config import EAConfig, InstrumentConfig, get_instrument
from .data_loader import load_csv, download_daily, validate_data
from .backtester import Backtester
from .reporting import compute_metrics, print_report, print_report_zh, trades_to_dataframe
from .visualize import plot_backtest, plot_backtest_zh


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="MeEA Kalman Filter Adaptive Trend Following — Python Backtest",
    )

    # Required
    p.add_argument("--equity", type=float, default=10000.0,
                   help="Initial account equity (default: 10000)")
    p.add_argument("--leverage", type=int, default=100,
                   help="Account leverage (default: 100)")
    p.add_argument("--symbol", type=str, default="EURUSD",
                   help="Trading symbol (default: EURUSD)")

    # Data source (mutually exclusive)
    data_grp = p.add_mutually_exclusive_group(required=True)
    data_grp.add_argument("--data", type=str,
                          help="Path to OHLCV CSV file")
    data_grp.add_argument("--download", action="store_true",
                          help="Download daily data via yfinance")

    # Download options
    p.add_argument("--start", type=str, default="2023-01-01",
                   help="Download start date (default: 2023-01-01)")
    p.add_argument("--end", type=str, default="2024-12-31",
                   help="Download end date (default: 2024-12-31)")

    # Strategy parameter overrides
    p.add_argument("--risk", type=float, default=None,
                   help="Risk per trade (e.g. 0.01 = 1%%)")
    p.add_argument("--max-positions", type=int, default=None,
                   help="Max concurrent positions")
    p.add_argument("--kf-process-noise", type=float, default=None)
    p.add_argument("--kf-observ-noise", type=float, default=None)
    p.add_argument("--kf-conf-band", type=float, default=None)
    p.add_argument("--hurst-period", type=int, default=None)
    p.add_argument("--hurst-threshold", type=float, default=None)
    p.add_argument("--vol-period", type=int, default=None)
    p.add_argument("--vol-hist-period", type=int, default=None)
    p.add_argument("--max-daily-dd", type=float, default=None)
    p.add_argument("--max-spread-points", type=float, default=None)
    p.add_argument("--slippage-points", type=float, default=None)
    p.add_argument("--hurst-exit-threshold", type=float, default=None,
                   help="Hurst threshold for signal exit (default: 0.40)")
    p.add_argument("--trail-multiplier", type=float, default=None,
                   help="Trailing stop estimation_error multiplier (default: 3.0)")
    p.add_argument("--min-hold-bars", type=int, default=None,
                   help="Min bars to hold before signal/trail exit (default: 5)")

    # Output
    p.add_argument("--lang", type=str, default="en", choices=["en", "zh"],
                   help="Report language: en (default) or zh (Chinese)")
    p.add_argument("--no-plot", action="store_true",
                   help="Skip chart display")
    p.add_argument("--save-plot", type=str, default=None,
                   help="Save chart to file path")
    p.add_argument("--export-trades", type=str, default=None,
                   help="Export trades to CSV file path")

    return p.parse_args(argv)


def main(argv: list[str] | None = None):
    args = parse_args(argv)

    # --- Build configs ---
    ea_cfg = EAConfig(
        initial_equity=args.equity,
        leverage=args.leverage,
    )

    # Apply overrides
    overrides = {
        "risk_per_trade": args.risk,
        "max_positions": args.max_positions,
        "kf_process_noise": args.kf_process_noise,
        "kf_observ_noise": args.kf_observ_noise,
        "kf_conf_band": args.kf_conf_band,
        "hurst_period": args.hurst_period,
        "hurst_threshold": args.hurst_threshold,
        "vol_period": args.vol_period,
        "vol_hist_period": args.vol_hist_period,
        "max_daily_dd": args.max_daily_dd,
        "max_spread_points": args.max_spread_points,
        "slippage_points": args.slippage_points,
        "hurst_exit_threshold": args.hurst_exit_threshold,
        "trail_multiplier": args.trail_multiplier,
        "min_hold_bars": args.min_hold_bars,
    }
    for key, val in overrides.items():
        if val is not None:
            setattr(ea_cfg, key, val)

    inst_cfg = get_instrument(args.symbol)

    # --- Load data ---
    print(f"Symbol: {inst_cfg.symbol}  |  Equity: {ea_cfg.initial_equity:,.0f}  |  Leverage: 1:{ea_cfg.leverage}")

    if args.data:
        print(f"Loading CSV: {args.data}")
        df = load_csv(args.data)
    else:
        print(f"Downloading {args.symbol} daily data: {args.start} — {args.end}")
        df = download_daily(args.symbol, args.start, args.end)

    min_bars = max(ea_cfg.hurst_period, ea_cfg.vol_hist_period) + 50
    validate_data(df, min_bars)
    print(f"Data loaded: {len(df)} bars  ({df.index[0]} — {df.index[-1]})")

    # --- Run backtest ---
    print("Running backtest...")
    bt = Backtester(ea_cfg, inst_cfg)
    result = bt.run(df)

    # --- Report ---
    metrics = compute_metrics(result, ea_cfg, inst_cfg, len(df))
    if args.lang == "zh":
        print_report_zh(metrics)
    else:
        print_report(metrics)

    # --- Export trades ---
    if args.export_trades:
        tdf = trades_to_dataframe(result.trades)
        tdf.to_csv(args.export_trades, index=False)
        print(f"Trades exported to {args.export_trades}")

    # --- Visualize ---
    if not args.no_plot or args.save_plot:
        plot_fn = plot_backtest_zh if args.lang == "zh" else plot_backtest
        plot_fn(result, ea_cfg, inst_cfg,
                price_data=df, show=not args.no_plot,
                save_path=args.save_plot)


if __name__ == "__main__":
    main()
