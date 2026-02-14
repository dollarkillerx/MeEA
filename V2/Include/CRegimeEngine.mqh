#ifndef C_REGIME_ENGINE_MQH
#define C_REGIME_ENGINE_MQH

class CRegimeEngine
{
private:
   ENUM_TIMEFRAMES m_tf;
   int m_emaHandle;
   int m_atrHandle;

   double m_biasOn;
   double m_biasOff;
   double m_slopeZMin;
   double m_slopeZFlat;
   int m_minTrendHoldBars;
   int m_minRangeHoldBars;

   bool m_isTrend;
   int m_trendDir;
   int m_stateHoldBars;

   double m_emaNow;
   double m_emaPrev;
   double m_atr;
   double m_bias;
   double m_slopePoints;
   double m_slopeZ;

public:
   CRegimeEngine() : m_tf(PERIOD_M15), m_emaHandle(INVALID_HANDLE), m_atrHandle(INVALID_HANDLE),
      m_biasOn(2.4), m_biasOff(1.6), m_slopeZMin(0.04), m_slopeZFlat(0.01),
      m_minTrendHoldBars(6), m_minRangeHoldBars(6), m_isTrend(false), m_trendDir(0),
      m_stateHoldBars(100), m_emaNow(0.0), m_emaPrev(0.0), m_atr(0.0), m_bias(0.0),
      m_slopePoints(0.0), m_slopeZ(0.0) {}

   bool Init(ENUM_TIMEFRAMES tf, double biasOn, double biasOff, double slopeZMin, double slopeZFlat,
             int minTrendHoldBars, int minRangeHoldBars)
   {
      m_tf = tf;
      m_biasOn = biasOn;
      m_biasOff = biasOff;
      m_slopeZMin = slopeZMin;
      m_slopeZFlat = slopeZFlat;
      m_minTrendHoldBars = minTrendHoldBars;
      m_minRangeHoldBars = minRangeHoldBars;

      m_emaHandle = iMA(_Symbol, m_tf, 200, 0, MODE_EMA, PRICE_CLOSE);
      m_atrHandle = iATR(_Symbol, m_tf, 14);
      if(m_emaHandle == INVALID_HANDLE || m_atrHandle == INVALID_HANDLE)
         return false;

      return true;
   }

   bool Update()
   {
      m_stateHoldBars++;

      double emaBuf[3];
      double atrBuf[2];
      if(CopyBuffer(m_emaHandle, 0, 1, 3, emaBuf) < 3)
         return false;
      if(CopyBuffer(m_atrHandle, 0, 1, 2, atrBuf) < 2)
         return false;

      m_emaNow = emaBuf[0];
      m_emaPrev = emaBuf[1];
      m_atr = atrBuf[0];

      if(m_atr <= 0.0)
         return false;

      double close1 = iClose(_Symbol, m_tf, 1);
      if(close1 <= 0.0)
         return false;

      m_bias = MathAbs(close1 - m_emaNow) / m_atr;
      m_slopePoints = (m_emaNow - m_emaPrev) / _Point;
      double atrPoints = m_atr / _Point;
      m_slopeZ = (atrPoints > 0.0) ? MathAbs(m_slopePoints) / atrPoints : 0.0;

      int dirSlope = 0;
      if(m_slopePoints > 0.0) dirSlope = 1;
      else if(m_slopePoints < 0.0) dirSlope = -1;

      int dirPrice = 0;
      double dist = close1 - m_emaNow;
      if(dist > 0.0) dirPrice = 1;
      else if(dist < 0.0) dirPrice = -1;

      if(!m_isTrend)
      {
         bool canEnter = (m_stateHoldBars >= m_minRangeHoldBars);
         bool trendTrigger = (m_bias >= m_biasOn && dirPrice == dirSlope && dirSlope != 0 && m_slopeZ >= m_slopeZMin);
         if(canEnter && trendTrigger)
         {
            m_isTrend = true;
            m_trendDir = dirSlope;
            m_stateHoldBars = 0;
         }
      }
      else
      {
         bool canExit = (m_stateHoldBars >= m_minTrendHoldBars);
         bool trendExit = (m_bias <= m_biasOff || dirPrice != dirSlope || m_slopeZ <= m_slopeZFlat);
         if(canExit && trendExit)
         {
            m_isTrend = false;
            m_trendDir = 0;
            m_stateHoldBars = 0;
         }
         else
         {
            // trend_dir source must remain slope direction only
            m_trendDir = dirSlope;
         }
      }

      return true;
   }

   bool   IsTrend()        const { return m_isTrend; }
   int    GetTrendDir()    const { return m_trendDir; }
   int    GetHoldBars()    const { return m_stateHoldBars; }
   double GetATR()         const { return m_atr; }
   double GetATRPoints()   const { return m_atr / _Point; }
   double GetBias()        const { return m_bias; }
   double GetSlopePoints() const { return m_slopePoints; }
   double GetSlopeZ()      const { return m_slopeZ; }
};

#endif
