#ifndef C_INVENTORY_ENGINE_MQH
#define C_INVENTORY_ENGINE_MQH

class CInventoryEngine
{
private:
   ulong m_magic;
   double m_budgetPct;
   double m_releaseRatio;
   int m_releaseBars;

   bool m_forcedLiq;
   int m_releaseCounter;

   int m_buyCount;
   int m_sellCount;
   double m_buyLots;
   double m_sellLots;
   double m_buyProfit;
   double m_sellProfit;
   ulong m_oldestBuyTicket;
   ulong m_oldestSellTicket;
   datetime m_oldestBuyTime;
   datetime m_oldestSellTime;
   double m_latestBuyPrice;
   double m_latestSellPrice;

public:
   CInventoryEngine() : m_magic(20240101), m_budgetPct(0.06), m_releaseRatio(0.8),
      m_releaseBars(2), m_forcedLiq(false), m_releaseCounter(0), m_buyCount(0),
      m_sellCount(0), m_buyLots(0.0), m_sellLots(0.0), m_buyProfit(0.0), m_sellProfit(0.0),
      m_oldestBuyTicket(0), m_oldestSellTicket(0), m_oldestBuyTime(0), m_oldestSellTime(0),
      m_latestBuyPrice(0.0), m_latestSellPrice(0.0) {}

   void Init(ulong magic, double budgetPct, double releaseRatio, int releaseBars)
   {
      m_magic = magic;
      m_budgetPct = budgetPct;
      m_releaseRatio = releaseRatio;
      m_releaseBars = releaseBars;
   }

   void Refresh()
   {
      m_buyCount = 0;
      m_sellCount = 0;
      m_buyLots = 0.0;
      m_sellLots = 0.0;
      m_buyProfit = 0.0;
      m_sellProfit = 0.0;
      m_oldestBuyTicket = 0;
      m_oldestSellTicket = 0;
      m_oldestBuyTime = 0;
      m_oldestSellTime = 0;
      m_latestBuyPrice = 0.0;
      m_latestSellPrice = 0.0;

      int total = PositionsTotal();
      datetime latestBuyTime = 0;
      datetime latestSellTime = 0;

      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;

         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;

         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         double lots = PositionGetDouble(POSITION_VOLUME);
         double profit = PositionGetDouble(POSITION_PROFIT);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

         if(type == POSITION_TYPE_BUY)
         {
            m_buyCount++;
            m_buyLots += lots;
            m_buyProfit += profit;

            if(m_oldestBuyTicket == 0 || openTime < m_oldestBuyTime)
            {
               m_oldestBuyTicket = ticket;
               m_oldestBuyTime = openTime;
            }

            if(openTime > latestBuyTime)
            {
               latestBuyTime = openTime;
               m_latestBuyPrice = openPrice;
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            m_sellCount++;
            m_sellLots += lots;
            m_sellProfit += profit;

            if(m_oldestSellTicket == 0 || openTime < m_oldestSellTime)
            {
               m_oldestSellTicket = ticket;
               m_oldestSellTime = openTime;
            }

            if(openTime > latestSellTime)
            {
               latestSellTime = openTime;
               m_latestSellPrice = openPrice;
            }
         }
      }
   }

   void UpdateForcedLiquidation(int trendDir, double equity)
   {
      if(trendDir == 0 || equity <= 0.0)
      {
         m_forcedLiq = false;
         m_releaseCounter = 0;
         return;
      }

      double adverseLoss = 0.0;
      int adverseCount = 0;

      if(trendDir > 0)
      {
         adverseLoss = (m_sellProfit < 0.0) ? -m_sellProfit : 0.0;
         adverseCount = m_sellCount;
      }
      else
      {
         adverseLoss = (m_buyProfit < 0.0) ? -m_buyProfit : 0.0;
         adverseCount = m_buyCount;
      }

      double budget = equity * m_budgetPct;

      if(!m_forcedLiq && adverseLoss >= budget)
      {
         m_forcedLiq = true;
         m_releaseCounter = 0;
      }

      if(m_forcedLiq)
      {
         bool releaseCandidate = (adverseLoss <= budget * m_releaseRatio || adverseCount <= 1);
         if(releaseCandidate)
            m_releaseCounter++;
         else
            m_releaseCounter = 0;

         if(m_releaseCounter >= m_releaseBars)
         {
            m_forcedLiq = false;
            m_releaseCounter = 0;
         }
      }
   }

   bool IsForcedLiquidation() const { return m_forcedLiq; }

   int GetBuyCount() const { return m_buyCount; }
   int GetSellCount() const { return m_sellCount; }
   double GetBuyLots() const { return m_buyLots; }
   double GetSellLots() const { return m_sellLots; }
   double GetBuyProfit() const { return m_buyProfit; }
   double GetSellProfit() const { return m_sellProfit; }
   double GetNetLots() const { return m_buyLots - m_sellLots; }
   double GetTotalProfit() const { return m_buyProfit + m_sellProfit; }
   bool HasPositions() const { return (m_buyCount + m_sellCount) > 0; }

   ulong GetOldestAdverseTicket(int trendDir) const
   {
      if(trendDir > 0) return m_oldestSellTicket;
      if(trendDir < 0) return m_oldestBuyTicket;
      return 0;
   }

   double GetLatestPriceByTrend(int trendDir, bool favorableSide) const
   {
      if(trendDir > 0)
         return favorableSide ? m_latestBuyPrice : m_latestSellPrice;
      if(trendDir < 0)
         return favorableSide ? m_latestSellPrice : m_latestBuyPrice;
      return 0.0;
   }
};

#endif
