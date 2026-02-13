//+------------------------------------------------------------------+
//|                                              CSignalEngine.mqh   |
//|                Signal Generation Engine                          |
//|                                                                  |
//| Integrates Kalman Filter, Hurst Exponent, and Volatility Regime  |
//| to produce entry/exit trading signals.                           |
//+------------------------------------------------------------------+
#ifndef C_SIGNAL_ENGINE_MQH
#define C_SIGNAL_ENGINE_MQH

#property copyright "MeEA"

#include "CKalmanFilter.mqh"
#include "CHurstExponent.mqh"
#include "CVolatilityRegime.mqh"

enum ENUM_SIGNAL
{
    SIGNAL_NONE,
    SIGNAL_BUY,
    SIGNAL_SELL,
    SIGNAL_CLOSE_BUY,
    SIGNAL_CLOSE_SELL
};

class CSignalEngine
{
private:
    CKalmanFilter     m_kalman;
    CHurstExponent    m_hurst;
    CVolatilityRegime m_volRegime;
    double            m_confBand;        // confidence band multiplier
    double            m_hurstThreshold;  // minimum Hurst for trending

public:
    CSignalEngine() : m_confBand(2.0), m_hurstThreshold(0.55) {}

    void Init(double kfProcessNoise, double kfObservNoise, double confBand,
              int hurstPeriod, double hurstThreshold,
              int volPeriod, int volHistPeriod)
    {
        m_kalman.Init(kfProcessNoise, kfObservNoise);
        m_hurst.Init(hurstPeriod);
        m_volRegime.Init(volPeriod, volHistPeriod);
        m_confBand       = confBand;
        m_hurstThreshold = hurstThreshold;
    }

    //--- Feed new bar data to all modules
    void OnNewBar(double close, double prevClose)
    {
        m_kalman.Update(close);
        m_hurst.Update(close, prevClose);
        m_volRegime.Update(close, prevClose);
    }

    //--- Get entry signal based on current price
    ENUM_SIGNAL GetEntrySignal(double currentPrice)
    {
        if(!m_kalman.IsInitialized() || !m_hurst.IsReady())
            return SIGNAL_NONE;

        double slope     = m_kalman.GetSlope();
        double hurst     = m_hurst.GetHurst();
        double upperBand = m_kalman.GetUpperBand(m_confBand);
        double lowerBand = m_kalman.GetLowerBand(m_confBand);

        // BUY: upward slope + trending market + price breaks above upper band
        if(slope > 0.0 && hurst > m_hurstThreshold && currentPrice > upperBand)
            return SIGNAL_BUY;

        // SELL: downward slope + trending market + price breaks below lower band
        if(slope < 0.0 && hurst > m_hurstThreshold && currentPrice < lowerBand)
            return SIGNAL_SELL;

        return SIGNAL_NONE;
    }

    //--- Should close existing buy positions?
    bool ShouldCloseBuy()
    {
        if(!m_kalman.IsInitialized()) return false;
        double slope = m_kalman.GetSlope();
        double hurst = m_hurst.GetHurst();
        // slope confirms reversal AND hurst falls below random walk
        return (slope < 0.0 && hurst < 0.50);
    }

    //--- Should close existing sell positions?
    bool ShouldCloseSell()
    {
        if(!m_kalman.IsInitialized()) return false;
        double slope = m_kalman.GetSlope();
        double hurst = m_hurst.GetHurst();
        // slope confirms reversal AND hurst falls below random walk
        return (slope > 0.0 && hurst < 0.50);
    }

    //--- Access sub-modules for risk manager / trailing stop
    double GetKalmanLevel()          { return m_kalman.GetLevel(); }
    double GetKalmanSlope()          { return m_kalman.GetSlope(); }
    double GetEstimationError()      { return m_kalman.GetEstimationError(); }
    double GetUpperBand()            { return m_kalman.GetUpperBand(m_confBand); }
    double GetLowerBand()            { return m_kalman.GetLowerBand(m_confBand); }
    double GetHurst()                { return m_hurst.GetHurst(); }
    ENUM_VOL_REGIME GetVolRegime()   { return m_volRegime.GetRegime(); }
    double GetCurrentVol()           { return m_volRegime.GetCurrentVol(); }
    double GetVolPercentile()        { return m_volRegime.GetPercentile(); }
};

#endif // C_SIGNAL_ENGINE_MQH
