#ifndef C_RISK_MANAGER_V2_MQH
#define C_RISK_MANAGER_V2_MQH

class CRiskManagerV2
{
private:
   double m_softDDPct;
   double m_hardDDPct;
   double m_dailyLossPct;
   double m_weeklyLossPct;
   double m_minMarginLevelPct;
   double m_maxSpreadPoints;

   datetime m_cooldownUntil;

   double m_sessionStartEquity;
   double m_dayStartEquity;
   double m_weekStartEquity;
   int m_lastDayOfYear;
   int m_lastWeekOfYear;

public:
   CRiskManagerV2() : m_softDDPct(0.10), m_hardDDPct(0.20), m_dailyLossPct(0.05), m_weeklyLossPct(0.10),
      m_minMarginLevelPct(900.0), m_maxSpreadPoints(15.0), m_cooldownUntil(0),
      m_sessionStartEquity(0.0), m_dayStartEquity(0.0), m_weekStartEquity(0.0),
      m_lastDayOfYear(-1), m_lastWeekOfYear(-1) {}

   void Init(double softDDPct, double hardDDPct, double dailyLossPct, double weeklyLossPct,
             double minMarginLevelPct, double maxSpreadPoints)
   {
      m_softDDPct = softDDPct;
      m_hardDDPct = hardDDPct;
      m_dailyLossPct = dailyLossPct;
      m_weeklyLossPct = weeklyLossPct;
      m_minMarginLevelPct = minMarginLevelPct;
      m_maxSpreadPoints = maxSpreadPoints;

      m_sessionStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_dayStartEquity = m_sessionStartEquity;
      m_weekStartEquity = m_sessionStartEquity;
   }

   void OnNewBar(datetime barTime)
   {
      MqlDateTime dt;
      TimeToStruct(barTime, dt);
      int dayOfYear = dt.day_of_year;
      int weekOfYear = dt.day_of_year / 7;

      if(m_lastDayOfYear < 0)
         m_lastDayOfYear = dayOfYear;
      if(m_lastWeekOfYear < 0)
         m_lastWeekOfYear = weekOfYear;

      if(dayOfYear != m_lastDayOfYear)
      {
         m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_lastDayOfYear = dayOfYear;
      }

      if(weekOfYear != m_lastWeekOfYear)
      {
         m_weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_lastWeekOfYear = weekOfYear;
      }
   }

   bool IsInCooldown(datetime now) const
   {
      return (now < m_cooldownUntil);
   }

   void SetHardCooldown(datetime now, int hours)
   {
      m_cooldownUntil = now + hours * 3600;
   }

   void SetSoftCooldown(datetime now, int hours)
   {
      datetime until = now + hours * 3600;
      if(until > m_cooldownUntil)
         m_cooldownUntil = until;
   }

   bool IsSpreadOk() const
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      return ((double)spread <= m_maxSpreadPoints);
   }

   bool IsMarginOk() const
   {
      double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(marginLevel <= 0.0)
         return false;
      return (marginLevel >= m_minMarginLevelPct);
   }

   bool HardStopTriggered() const
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_sessionStartEquity <= 0.0)
         return false;

      double drawdown = (m_sessionStartEquity - equity) / m_sessionStartEquity;
      if(drawdown >= m_hardDDPct)
         return true;

      if(!IsMarginOk())
         return true;

      return false;
   }

   bool SoftLockActive() const
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_sessionStartEquity <= 0.0 || m_dayStartEquity <= 0.0 || m_weekStartEquity <= 0.0)
         return false;

      double ddSession = (m_sessionStartEquity - equity) / m_sessionStartEquity;
      double ddDay = (m_dayStartEquity - equity) / m_dayStartEquity;
      double ddWeek = (m_weekStartEquity - equity) / m_weekStartEquity;

      if(ddSession >= m_softDDPct) return true;
      if(ddDay >= m_dailyLossPct) return true;
      if(ddWeek >= m_weeklyLossPct) return true;

      return false;
   }

   double CalcLotsByRisk(double stopPoints, double riskPct)
   {
      if(stopPoints <= 0.0 || riskPct <= 0.0)
         return 0.0;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double pointVal  = (tickSize > 0.0) ? tickValue / tickSize * _Point : tickValue;
      if(pointVal <= 0.0)
         return 0.0;

      double riskAmount = equity * riskPct;
      double lots = riskAmount / (stopPoints * pointVal);

      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      if(step > 0.0)
         lots = MathFloor(lots / step) * step;
      if(lots < minLot) lots = minLot;
      if(lots > maxLot) lots = maxLot;
      return lots;
   }
};

#endif
