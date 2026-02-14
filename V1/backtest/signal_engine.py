from .config import Signal, VolRegime
from .kalman_filter import KalmanFilter
from .hurst_exponent import HurstExponent
from .volatility_regime import VolatilityRegime


class SignalEngine:
    """Signal generation engine.

    1:1 port of CSignalEngine.mqh — integrates Kalman, Hurst, VolRegime.
    """

    def __init__(self):
        self._kalman = KalmanFilter()
        self._hurst = HurstExponent()
        self._vol_regime = VolatilityRegime()
        self._conf_band = 2.0
        self._hurst_threshold = 0.55
        self._hurst_exit_threshold = 0.40

    def init(self, kf_process_noise: float, kf_observ_noise: float,
             conf_band: float, hurst_period: int, hurst_threshold: float,
             vol_period: int, vol_hist_period: int,
             hurst_exit_threshold: float = 0.40):
        self._kalman.init(kf_process_noise, kf_observ_noise)
        self._hurst.init(hurst_period)
        self._vol_regime.init(vol_period, vol_hist_period)
        self._conf_band = conf_band
        self._hurst_threshold = hurst_threshold
        self._hurst_exit_threshold = hurst_exit_threshold

    def on_new_bar(self, close: float, prev_close: float):
        self._kalman.update(close)
        self._hurst.update(close, prev_close)
        self._vol_regime.update(close, prev_close)

    def get_entry_signal(self, current_price: float) -> Signal:
        if not self._kalman.is_initialized() or not self._hurst.is_ready():
            return Signal.NONE

        slope = self._kalman.get_slope()
        hurst = self._hurst.get_hurst()
        upper_band = self._kalman.get_upper_band(self._conf_band)
        lower_band = self._kalman.get_lower_band(self._conf_band)

        # BUY: upward slope + trending + price > upper band
        if slope > 0.0 and hurst > self._hurst_threshold and current_price > upper_band:
            return Signal.BUY

        # SELL: downward slope + trending + price < lower band
        if slope < 0.0 and hurst > self._hurst_threshold and current_price < lower_band:
            return Signal.SELL

        return Signal.NONE

    def should_close_buy(self) -> bool:
        if not self._kalman.is_initialized():
            return False
        return self._kalman.get_slope() < 0.0 and self._hurst.get_hurst() < self._hurst_exit_threshold

    def should_close_sell(self) -> bool:
        if not self._kalman.is_initialized():
            return False
        return self._kalman.get_slope() > 0.0 and self._hurst.get_hurst() < self._hurst_exit_threshold

    # --- Sub-module accessors ---
    def get_kalman_level(self) -> float:
        return self._kalman.get_level()

    def get_kalman_slope(self) -> float:
        return self._kalman.get_slope()

    def get_estimation_error(self) -> float:
        return self._kalman.get_estimation_error()

    def get_upper_band(self) -> float:
        return self._kalman.get_upper_band(self._conf_band)

    def get_lower_band(self) -> float:
        return self._kalman.get_lower_band(self._conf_band)

    def get_hurst(self) -> float:
        return self._hurst.get_hurst()

    def get_vol_regime(self) -> VolRegime:
        return self._vol_regime.get_regime()

    def get_current_vol(self) -> float:
        return self._vol_regime.get_current_vol()

    def get_vol_percentile(self) -> float:
        return self._vol_regime.get_percentile()
