import math


class HurstExponent:
    """R/S analysis for Hurst exponent.

    1:1 port of CHurstExponent.mqh — ring buffer + log-log regression.
    """

    def __init__(self):
        self._period = 200
        self._returns: list[float] = []
        self._head = 0
        self._count = 0
        self._hurst = 0.5

    def init(self, period: int):
        self._period = period
        self._returns = [0.0] * period
        self._head = 0
        self._count = 0
        self._hurst = 0.5

    def update(self, close: float, prev_close: float):
        if prev_close <= 0.0 or close <= 0.0:
            return

        ret = math.log(close / prev_close)

        if self._count < self._period:
            self._returns[self._count] = ret
            self._count += 1
        else:
            self._returns[self._head] = ret
            self._head = (self._head + 1) % self._period

        if self._count >= 20:
            self._hurst = self._calculate_hurst()

    def _linearize(self) -> list[float]:
        data_len = min(self._count, self._period)
        if self._count < self._period:
            return self._returns[:data_len]
        else:
            # Full ring buffer — oldest at head
            return [self._returns[(self._head + i) % self._period]
                    for i in range(data_len)]

    @staticmethod
    def _calc_rs(data: list[float], start: int, length: int) -> float:
        if length < 2:
            return 0.0

        # Mean
        mean = 0.0
        for i in range(start, start + length):
            mean += data[i]
        mean /= length

        # Population standard deviation (divide by N, not N-1)
        sum_sq = 0.0
        for i in range(start, start + length):
            diff = data[i] - mean
            sum_sq += diff * diff
        sd = math.sqrt(sum_sq / length)

        if sd < 1e-15:
            return 0.0

        # Cumulative deviation from mean
        cum_dev = 0.0
        max_cum = -1e30
        min_cum = 1e30
        for i in range(start, start + length):
            cum_dev += data[i] - mean
            if cum_dev > max_cum:
                max_cum = cum_dev
            if cum_dev < min_cum:
                min_cum = cum_dev

        return (max_cum - min_cum) / sd

    def _calculate_hurst(self) -> float:
        linear = self._linearize()
        data_len = len(linear)
        if data_len < 20:
            return 0.5

        log_n: list[float] = []
        log_rs: list[float] = []

        prev_n = 0
        n = 8
        while n <= data_len // 2:
            if n == prev_n:
                n += 1
                continue
            prev_n = n

            num_segments = data_len // n
            if num_segments < 1:
                break

            sum_rs = 0.0
            valid_segs = 0

            for seg in range(num_segments):
                rs = self._calc_rs(linear, seg * n, n)
                if rs > 0.0:
                    sum_rs += rs
                    valid_segs += 1

            if valid_segs > 0:
                avg_rs = sum_rs / valid_segs
                log_n.append(math.log(n))
                log_rs.append(math.log(avg_rs))

            n = int(n * 1.5)

        # Linear regression: log(R/S) = H * log(n) + c
        num_points = len(log_n)
        if num_points < 2:
            return 0.5

        sum_x = sum_y = sum_xy = sum_x2 = 0.0
        for i in range(num_points):
            sum_x += log_n[i]
            sum_y += log_rs[i]
            sum_xy += log_n[i] * log_rs[i]
            sum_x2 += log_n[i] * log_n[i]

        denom = num_points * sum_x2 - sum_x * sum_x
        if abs(denom) < 1e-15:
            return 0.5

        H = (num_points * sum_xy - sum_x * sum_y) / denom

        # Clamp to [0, 1]
        return max(0.0, min(1.0, H))

    def get_hurst(self) -> float:
        return self._hurst

    def is_trending(self, threshold: float) -> bool:
        return self._hurst > threshold

    def is_ready(self) -> bool:
        return self._count >= 20
