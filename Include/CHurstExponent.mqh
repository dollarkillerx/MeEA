//+------------------------------------------------------------------+
//|                                              CHurstExponent.mqh  |
//|                         R/S Analysis for Hurst Exponent          |
//|                                                                  |
//| H > 0.5: trending (persistent)                                   |
//| H = 0.5: random walk                                             |
//| H < 0.5: mean-reverting (anti-persistent)                        |
//+------------------------------------------------------------------+
#ifndef C_HURST_EXPONENT_MQH
#define C_HURST_EXPONENT_MQH

#property copyright "MeEA"

class CHurstExponent
{
private:
    int    m_period;
    double m_returns[];
    int    m_head;       // ring buffer write position
    int    m_count;
    double m_hurst;

    //--- Calculate R/S for a sub-segment of returns
    double CalcRS(const double &data[], int start, int length)
    {
        if(length < 2) return 0.0;

        // Mean
        double mean = 0.0;
        for(int i = start; i < start + length; i++)
            mean += data[i];
        mean /= length;

        // Standard deviation
        double sumSq = 0.0;
        for(int i = start; i < start + length; i++)
            sumSq += (data[i] - mean) * (data[i] - mean);
        double sd = MathSqrt(sumSq / length);

        if(sd < 1e-15) return 0.0;

        // Cumulative deviation from mean
        double cumDev = 0.0;
        double maxCum = -1e30;
        double minCum =  1e30;
        for(int i = start; i < start + length; i++)
        {
            cumDev += (data[i] - mean);
            if(cumDev > maxCum) maxCum = cumDev;
            if(cumDev < minCum) minCum = cumDev;
        }

        double range = maxCum - minCum;
        return range / sd;
    }

    //--- Linearize ring buffer into output array (oldest first)
    void Linearize(double &out[])
    {
        int dataLen = MathMin(m_count, m_period);
        ArrayResize(out, dataLen);
        if(m_count < m_period)
        {
            // Buffer not yet full — data is [0..m_count-1]
            for(int i = 0; i < dataLen; i++)
                out[i] = m_returns[i];
        }
        else
        {
            // Full ring buffer — oldest at m_head, newest at m_head-1
            for(int i = 0; i < dataLen; i++)
                out[i] = m_returns[(m_head + i) % m_period];
        }
    }

public:
    CHurstExponent() : m_period(200), m_head(0), m_count(0), m_hurst(0.5) {}

    void Init(int period)
    {
        m_period = period;
        ArrayResize(m_returns, m_period);
        ArrayInitialize(m_returns, 0.0);
        m_head  = 0;
        m_count = 0;
        m_hurst = 0.5;
    }

    //--- Add new return observation (O(1) ring buffer write)
    void Update(double close, double prevClose)
    {
        if(prevClose <= 0.0 || close <= 0.0) return;

        double ret = MathLog(close / prevClose);

        if(m_count < m_period)
        {
            m_returns[m_count] = ret;
            m_count++;
        }
        else
        {
            m_returns[m_head] = ret;
            m_head = (m_head + 1) % m_period;
        }

        // Recalculate Hurst when buffer is sufficiently filled
        if(m_count >= 20)
            m_hurst = CalculateHurst();
    }

    //--- R/S analysis to compute Hurst exponent
    double CalculateHurst()
    {
        // Linearize ring buffer for R/S calculation
        double linear[];
        Linearize(linear);
        int dataLen = ArraySize(linear);
        if(dataLen < 20) return 0.5;

        double logN[];
        double logRS[];
        int    numPoints = 0;

        // Denser sub-segment sizes: factor 1.5 instead of 2
        int prevN = 0;
        for(int n = 8; n <= dataLen / 2; n = (int)(n * 1.5))
        {
            // Avoid duplicate sizes from rounding
            if(n == prevN) { n++; continue; }
            prevN = n;

            int numSegments = dataLen / n;
            if(numSegments < 1) break;

            double sumRS = 0.0;
            int validSegs = 0;

            for(int seg = 0; seg < numSegments; seg++)
            {
                double rs = CalcRS(linear, seg * n, n);
                if(rs > 0.0)
                {
                    sumRS += rs;
                    validSegs++;
                }
            }

            if(validSegs > 0)
            {
                double avgRS = sumRS / validSegs;
                ArrayResize(logN,  numPoints + 1);
                ArrayResize(logRS, numPoints + 1);
                logN[numPoints]  = MathLog((double)n);
                logRS[numPoints] = MathLog(avgRS);
                numPoints++;
            }
        }

        // Linear regression: log(R/S) = H * log(n) + c
        if(numPoints < 2) return 0.5;

        double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
        for(int i = 0; i < numPoints; i++)
        {
            sumX  += logN[i];
            sumY  += logRS[i];
            sumXY += logN[i] * logRS[i];
            sumX2 += logN[i] * logN[i];
        }

        double denom = numPoints * sumX2 - sumX * sumX;
        if(MathAbs(denom) < 1e-15) return 0.5;

        double H = (numPoints * sumXY - sumX * sumY) / denom;

        // Clamp to valid range [0, 1]
        if(H < 0.0) H = 0.0;
        if(H > 1.0) H = 1.0;

        return H;
    }

    //--- Current Hurst exponent value
    double GetHurst()
    {
        return m_hurst;
    }

    //--- Is the market trending? (H > threshold)
    bool IsTrending(double threshold)
    {
        return m_hurst > threshold;
    }

    //--- Check if enough data collected
    bool IsReady()
    {
        return m_count >= 20;
    }
};

#endif // C_HURST_EXPONENT_MQH
