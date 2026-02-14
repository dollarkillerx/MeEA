import math

from .config import VolRegime


class VolatilityRegime:
    """Realized volatility regime detection.

    1:1 port of CVolatilityRegime.mqh — dual ring buffer.
    """

    def __init__(self):
        self._period = 100
        self._hist_period = 500
        # Returns ring buffer
        self._returns: list[float] = []
        self._ret_head = 0
        self._ret_count = 0
        # Vol history ring buffer
        self._vol_history: list[float] = []
        self._vol_head = 0
        self._vol_count = 0
        self._current_vol = 0.0
        self._percentile = 0.5

    def init(self, period: int, hist_period: int):
        self._period = period
        self._hist_period = hist_period
        self._returns = [0.0] * period
        self._ret_head = 0
        self._ret_count = 0
        self._vol_history = [0.0] * hist_period
        self._vol_head = 0
        self._vol_count = 0
        self._current_vol = 0.0
        self._percentile = 0.5

    def update(self, close: float, prev_close: float):
        if prev_close <= 0.0 or close <= 0.0:
            return

        ret = math.log(close / prev_close)

        # Ring buffer write for returns
        if self._ret_count < self._period:
            self._returns[self._ret_count] = ret
            self._ret_count += 1
        else:
            self._returns[self._ret_head] = ret
            self._ret_head = (self._ret_head + 1) % self._period

        # Calculate current realized volatility (population std of returns)
        if self._ret_count >= 2:
            length = min(self._ret_count, self._period)

            mean = 0.0
            for i in range(length):
                mean += self._returns[i]
            mean /= length

            sum_sq = 0.0
            for i in range(length):
                diff = self._returns[i] - mean
                sum_sq += diff * diff

            self._current_vol = math.sqrt(sum_sq / length)  # ddof=0

        # Store current vol in history ring buffer
        if self._current_vol > 0.0:
            if self._vol_count < self._hist_period:
                self._vol_history[self._vol_count] = self._current_vol
                self._vol_count += 1
            else:
                self._vol_history[self._vol_head] = self._current_vol
                self._vol_head = (self._vol_head + 1) % self._hist_period

            # Calculate percentile rank
            if self._vol_count >= 2:
                length = min(self._vol_count, self._hist_period)
                count_below = 0
                for i in range(length):
                    if self._vol_history[i] < self._current_vol:
                        count_below += 1
                self._percentile = count_below / length

    def get_current_vol(self) -> float:
        return self._current_vol

    def get_percentile(self) -> float:
        return self._percentile

    def get_regime(self) -> VolRegime:
        if self._percentile < 0.25:
            return VolRegime.LOW
        elif self._percentile > 0.75:
            return VolRegime.HIGH
        else:
            return VolRegime.NORMAL

    def is_ready(self) -> bool:
        return self._ret_count >= self._period and self._vol_count >= 20
