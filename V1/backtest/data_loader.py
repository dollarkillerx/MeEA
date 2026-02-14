from __future__ import annotations

import pandas as pd


def load_csv(
    filepath: str,
    time_col: str = "time",
    open_col: str = "open",
    high_col: str = "high",
    low_col: str = "low",
    close_col: str = "close",
    volume_col: str | None = "volume",
    sep: str | None = None,
) -> pd.DataFrame:
    """Load OHLCV CSV into a DatetimeIndex DataFrame.

    Supports comma / semicolon / tab separators (auto-detect if *sep* is None).
    Returns columns: open, high, low, close[, volume].
    """
    if sep is None:
        # peek first line to detect separator
        with open(filepath, "r") as f:
            header = f.readline()
        if ";" in header:
            sep = ";"
        elif "\t" in header:
            sep = "\t"
        else:
            sep = ","

    df = pd.read_csv(filepath, sep=sep)

    # Build column rename map
    rename = {
        time_col: "time",
        open_col: "open",
        high_col: "high",
        low_col: "low",
        close_col: "close",
    }
    if volume_col and volume_col in df.columns:
        rename[volume_col] = "volume"

    # Case-insensitive column matching
    lower_map = {c.lower().strip(): c for c in df.columns}
    final_rename: dict[str, str] = {}
    for src, dst in rename.items():
        if src in df.columns:
            final_rename[src] = dst
        elif src.lower() in lower_map:
            final_rename[lower_map[src.lower()]] = dst

    df = df.rename(columns=final_rename)

    df["time"] = pd.to_datetime(df["time"])
    df = df.set_index("time").sort_index()

    for col in ("open", "high", "low", "close"):
        df[col] = pd.to_numeric(df[col], errors="coerce")

    return df


def download_daily(
    symbol: str,
    start: str,
    end: str,
) -> pd.DataFrame:
    """Download daily forex data via yfinance.

    *symbol* is the base pair (e.g. ``"EURUSD"``); ``"=X"`` suffix is
    appended automatically.
    """
    try:
        import yfinance as yf
    except ImportError:
        raise ImportError(
            "yfinance is required for download. Install with: pip install yfinance"
        )

    ticker = symbol.upper()
    if not ticker.endswith("=X"):
        ticker += "=X"

    data = yf.download(ticker, start=start, end=end, auto_adjust=True)
    if data.empty:
        raise ValueError(f"No data returned for {ticker} ({start} — {end})")

    # yfinance may return MultiIndex columns when downloading single ticker
    if isinstance(data.columns, pd.MultiIndex):
        data.columns = data.columns.get_level_values(0)

    df = data.rename(columns=str.lower)
    for col in ("open", "high", "low", "close"):
        if col not in df.columns:
            raise ValueError(f"Missing column '{col}' in downloaded data")

    return df


def validate_data(df: pd.DataFrame, min_bars: int) -> None:
    """Raise if data is too short or contains NaN closes."""
    if len(df) < min_bars:
        raise ValueError(
            f"Data has {len(df)} bars but at least {min_bars} are required."
        )
    nan_count = df["close"].isna().sum()
    if nan_count > 0:
        raise ValueError(f"Data contains {nan_count} NaN close prices.")
