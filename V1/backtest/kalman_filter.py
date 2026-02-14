import math


class KalmanFilter:
    """2-state Kalman Filter: [level, slope].

    1:1 port of CKalmanFilter.mqh — uses scalar floats,
    no numpy matrices, to match MQL5 floating-point order.
    """

    def __init__(self):
        # State vector [level, slope]
        self._state = [0.0, 0.0]
        # Estimation error covariance P (2x2)
        self._P = [[1.0, 0.0],
                    [0.0, 1.0]]
        # Process noise covariance Q (2x2)
        self._Q = [[0.01, 0.0],
                    [0.0, 0.01]]
        # Observation noise
        self._R = 1.0
        self._initialized = False

    def init(self, process_noise: float, observ_noise: float):
        self._Q = [[process_noise, 0.0],
                    [0.0, process_noise]]
        self._R = observ_noise
        self._initialized = False

    def update(self, price: float):
        # First observation: initialize state with price-scaled P
        if not self._initialized:
            self._state[0] = price   # level = price
            self._state[1] = 0.0     # slope = 0
            price_scale = price * 0.01
            self._P[0][0] = price_scale * price_scale
            self._P[0][1] = 0.0
            self._P[1][0] = 0.0
            self._P[1][1] = price_scale * price_scale * 0.01
            self._initialized = True
            return

        # --- PREDICT ---
        # X_pred = F * X,  F = [[1,1],[0,1]]
        x_pred0 = self._state[0] + self._state[1]  # level + slope
        x_pred1 = self._state[1]                     # slope unchanged

        # P_pred = F * P * F' + Q
        # F * P:
        FP00 = self._P[0][0] + self._P[1][0]
        FP01 = self._P[0][1] + self._P[1][1]
        FP10 = self._P[1][0]
        FP11 = self._P[1][1]

        # (F * P) * F':   F' = [[1,0],[1,1]]
        P_pred00 = FP00 + FP01 + self._Q[0][0]
        P_pred01 = FP01 + self._Q[0][1]
        P_pred10 = FP10 + FP11 + self._Q[1][0]
        P_pred11 = FP11 + self._Q[1][1]

        # --- UPDATE ---
        # H = [1, 0]
        y = price - x_pred0   # innovation

        S = P_pred00 + self._R  # innovation covariance

        # Innovation gate: reject outliers beyond 3 sigma
        innovation_sigma = math.sqrt(S)
        if abs(y) > 3.0 * innovation_sigma:
            # Outlier — only predict, skip update
            self._state[0] = x_pred0
            self._state[1] = x_pred1
            self._P[0][0] = P_pred00
            self._P[0][1] = P_pred01
            self._P[1][0] = P_pred10
            self._P[1][1] = P_pred11
            return

        # Kalman gain  K = P_pred * H' / S
        K0 = P_pred00 / S
        K1 = P_pred10 / S

        # State update  X = X_pred + K * y
        self._state[0] = x_pred0 + K0 * y
        self._state[1] = x_pred1 + K1 * y

        # Covariance update  P = (I - K*H) * P_pred
        self._P[0][0] = (1.0 - K0) * P_pred00
        self._P[0][1] = (1.0 - K0) * P_pred01
        self._P[1][0] = -K1 * P_pred00 + P_pred10
        self._P[1][1] = -K1 * P_pred01 + P_pred11

    def get_level(self) -> float:
        return self._state[0]

    def get_slope(self) -> float:
        return self._state[1]

    def get_estimation_error(self) -> float:
        return math.sqrt(abs(self._P[0][0]))

    def get_upper_band(self, k: float) -> float:
        return self._state[0] + k * self.get_estimation_error()

    def get_lower_band(self, k: float) -> float:
        return self._state[0] - k * self.get_estimation_error()

    def is_initialized(self) -> bool:
        return self._initialized
