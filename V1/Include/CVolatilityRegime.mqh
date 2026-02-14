//+------------------------------------------------------------------+
//|                                          CVolatilityRegime.mqh   |
//|                    Realized Volatility Regime Detection           |
//|                                                                  |
//| Classifies market into LOW/NORMAL/HIGH volatility regimes        |
//| based on historical percentile of realized volatility.           |
//+------------------------------------------------------------------+
#ifndef C_VOLATILITY_REGIME_MQH
#define C_VOLATILITY_REGIME_MQH

#property copyright "MeEA"

enum ENUM_VOL_REGIME
{
    VOL_LOW,       // < 25th percentile
    VOL_NORMAL,    // 25th - 75th percentile
    VOL_HIGH       // > 75th percentile
};

class CVolatilityRegime
{
private:
    int    m_period;        // window for current RV calculation
    int    m_histPeriod;    // window for historical RV percentile
    double m_returns[];     // recent returns ring buffer
    int    m_retHead;       // ring buffer write position for returns
    int    m_retCount;
    double m_volHistory[];  // historical RV ring buffer
    int    m_volHead;       // ring buffer write position for vol history
    int    m_volCount;
    double m_currentVol;
    double m_percentile;

public:
    CVolatilityRegime() : m_period(100), m_histPeriod(500),
                          m_retHead(0), m_retCount(0),
                          m_volHead(0), m_volCount(0),
                          m_currentVol(0.0), m_percentile(0.5) {}

    void Init(int period, int histPeriod)
    {
        m_period     = period;
        m_histPeriod = histPeriod;
        ArrayResize(m_returns, m_period);
        ArrayInitialize(m_returns, 0.0);
        ArrayResize(m_volHistory, m_histPeriod);
        ArrayInitialize(m_volHistory, 0.0);
        m_retHead    = 0;
        m_retCount   = 0;
        m_volHead    = 0;
        m_volCount   = 0;
        m_currentVol = 0.0;
        m_percentile = 0.5;
    }

    void Update(double close, double prevClose)
    {
        if(prevClose <= 0.0 || close <= 0.0) return;

        double ret = MathLog(close / prevClose);

        // Ring buffer write for returns
        if(m_retCount < m_period)
        {
            m_returns[m_retCount] = ret;
            m_retCount++;
        }
        else
        {
            m_returns[m_retHead] = ret;
            m_retHead = (m_retHead + 1) % m_period;
        }

        // Calculate current realized volatility (std dev of returns)
        if(m_retCount >= 2)
        {
            int len = MathMin(m_retCount, m_period);

            double mean = 0.0;
            for(int i = 0; i < len; i++)
                mean += m_returns[i];
            mean /= len;

            double sumSq = 0.0;
            for(int i = 0; i < len; i++)
                sumSq += (m_returns[i] - mean) * (m_returns[i] - mean);

            m_currentVol = MathSqrt(sumSq / len);
        }

        // Store current vol in history ring buffer
        if(m_currentVol > 0.0)
        {
            if(m_volCount < m_histPeriod)
            {
                m_volHistory[m_volCount] = m_currentVol;
                m_volCount++;
            }
            else
            {
                m_volHistory[m_volHead] = m_currentVol;
                m_volHead = (m_volHead + 1) % m_histPeriod;
            }

            // Calculate percentile rank of current vol
            if(m_volCount >= 2)
            {
                int len = MathMin(m_volCount, m_histPeriod);
                int countBelow = 0;
                for(int i = 0; i < len; i++)
                {
                    if(m_volHistory[i] < m_currentVol)
                        countBelow++;
                }
                m_percentile = (double)countBelow / len;
            }
        }
    }

    //--- Current realized volatility
    double GetCurrentVol()
    {
        return m_currentVol;
    }

    //--- Percentile rank [0, 1]
    double GetPercentile()
    {
        return m_percentile;
    }

    //--- Volatility regime classification
    ENUM_VOL_REGIME GetRegime()
    {
        if(m_percentile < 0.25)
            return VOL_LOW;
        else if(m_percentile > 0.75)
            return VOL_HIGH;
        else
            return VOL_NORMAL;
    }

    //--- Check if enough data collected
    bool IsReady()
    {
        return (m_retCount >= m_period && m_volCount >= 20);
    }
};

#endif // C_VOLATILITY_REGIME_MQH
