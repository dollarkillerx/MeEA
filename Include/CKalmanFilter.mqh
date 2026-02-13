//+------------------------------------------------------------------+
//|                                                CKalmanFilter.mqh |
//|                         Kalman Filter State Space Model          |
//|                                                                  |
//| State: X = [level, slope]                                        |
//| Transition: F = [[1,1],[0,1]]                                    |
//| Observation: H = [1, 0]                                          |
//+------------------------------------------------------------------+
#ifndef C_KALMAN_FILTER_MQH
#define C_KALMAN_FILTER_MQH

#property copyright "MeEA"

class CKalmanFilter
{
private:
    double m_state[2];      // [level, slope]
    double m_P[2][2];       // estimation error covariance
    double m_Q[2][2];       // process noise covariance
    double m_R;             // observation noise
    bool   m_initialized;

public:
    CKalmanFilter() : m_R(1.0), m_initialized(false)
    {
        ArrayInitialize(m_state, 0.0);
        m_P[0][0] = 1.0;  m_P[0][1] = 0.0;
        m_P[1][0] = 0.0;  m_P[1][1] = 1.0;
        m_Q[0][0] = 0.01; m_Q[0][1] = 0.0;
        m_Q[1][0] = 0.0;  m_Q[1][1] = 0.01;
    }

    //--- Initialize filter parameters
    void Init(double processNoise, double observNoise)
    {
        m_Q[0][0] = processNoise;
        m_Q[0][1] = 0.0;
        m_Q[1][0] = 0.0;
        m_Q[1][1] = processNoise;
        m_R       = observNoise;
        m_initialized = false;
    }

    //--- Predict + Update step
    void Update(double price)
    {
        // First observation: initialize state with price-scaled P matrix
        if(!m_initialized)
        {
            m_state[0] = price;   // level = price
            m_state[1] = 0.0;    // slope = 0
            // P adapts to price scale: 1% of price as initial uncertainty
            double priceScale = price * 0.01;
            m_P[0][0] = priceScale * priceScale;  m_P[0][1] = 0.0;
            m_P[1][0] = 0.0;  m_P[1][1] = priceScale * priceScale * 0.01;
            m_initialized = true;
            return;
        }

        //--- PREDICT ---
        // X_pred = F * X
        // F = [[1,1],[0,1]]
        double x_pred0 = m_state[0] + m_state[1]; // level + slope
        double x_pred1 = m_state[1];               // slope unchanged

        // P_pred = F * P * F' + Q
        // F * P:
        double FP00 = m_P[0][0] + m_P[1][0];
        double FP01 = m_P[0][1] + m_P[1][1];
        double FP10 = m_P[1][0];
        double FP11 = m_P[1][1];

        // (F * P) * F':
        // F' = [[1,0],[1,1]]
        double P_pred00 = FP00 + FP01 + m_Q[0][0];
        double P_pred01 = FP01 + m_Q[0][1];
        double P_pred10 = FP10 + FP11 + m_Q[1][0];
        double P_pred11 = FP11 + m_Q[1][1];

        //--- UPDATE ---
        // H = [1, 0]
        // Innovation: y = price - H * X_pred = price - x_pred0
        double y = price - x_pred0;

        // S = H * P_pred * H' + R = P_pred[0][0] + R
        double S = P_pred00 + m_R;

        // Innovation gate: reject outliers beyond 3σ (e.g. weekend gaps)
        double innovationSigma = MathSqrt(S);
        if(MathAbs(y) > 3.0 * innovationSigma)
        {
            // Outlier: only predict (P grows), skip update
            m_state[0] = x_pred0;
            m_state[1] = x_pred1;
            m_P[0][0] = P_pred00;  m_P[0][1] = P_pred01;
            m_P[1][0] = P_pred10;  m_P[1][1] = P_pred11;
            return;
        }

        // K = P_pred * H' / S = [P_pred[0][0], P_pred[1][0]]' / S
        double K0 = P_pred00 / S;
        double K1 = P_pred10 / S;

        // X = X_pred + K * y
        m_state[0] = x_pred0 + K0 * y;
        m_state[1] = x_pred1 + K1 * y;

        // P = (I - K * H) * P_pred
        // K*H = [[K0, 0], [K1, 0]]
        // I - K*H = [[1-K0, 0], [-K1, 1]]
        m_P[0][0] = (1.0 - K0) * P_pred00;
        m_P[0][1] = (1.0 - K0) * P_pred01;
        m_P[1][0] = -K1 * P_pred00 + P_pred10;
        m_P[1][1] = -K1 * P_pred01 + P_pred11;
    }

    //--- Trend level (filtered price)
    double GetLevel()
    {
        return m_state[0];
    }

    //--- Trend slope (rate of change)
    double GetSlope()
    {
        return m_state[1];
    }

    //--- Upper confidence band: level + k * sqrt(P[0][0])
    double GetUpperBand(double k)
    {
        return m_state[0] + k * GetEstimationError();
    }

    //--- Lower confidence band: level - k * sqrt(P[0][0])
    double GetLowerBand(double k)
    {
        return m_state[0] - k * GetEstimationError();
    }

    //--- Estimation uncertainty: sqrt(P[0][0])
    double GetEstimationError()
    {
        return MathSqrt(MathAbs(m_P[0][0]));
    }

    //--- Check if filter is initialized
    bool IsInitialized()
    {
        return m_initialized;
    }
};

#endif // C_KALMAN_FILTER_MQH
