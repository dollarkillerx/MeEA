#property copyright "MeEA"
#property version   "2.10"

#include "../Include/CV2Types.mqh"
#include "../Include/CTradeExecutor.mqh"
#include "../Include/CRegimeEngine.mqh"
#include "../Include/CInventoryEngine.mqh"
#include "../Include/CDeRiskEngine.mqh"
#include "../Include/CRiskManagerV2.mqh"

input ENUM_TIMEFRAMES TF_Entry = PERIOD_M15;

input ulong  MagicNumber = 20260214;
input int    Slippage = 10;

input double Bias_On = 2.4;
input double Bias_Off = 1.6;
input double Bias_SeedMax = 1.2;
input double SlopeZ_Min = 0.04;
input double SlopeZ_Flat = 0.01;
input int    MinTrendHoldBars = 6;
input int    MinRangeHoldBars = 6;

input double StepRangeATRMult = 0.8;
input double StepTrendATRMult = 1.4;
input double StepMinPoints = 80.0;
input double StepMaxPoints = 180.0;

input double LotL1 = 0.01;
input double LotL2 = 0.01;
input double LotL3 = 0.02;
input double LotL4 = 0.03;
input double LotL5 = 0.05;

input double InventoryBudgetPerSidePct = 0.06;
input double ForcedLiqReleaseRatio = 0.8;
input int    ForcedLiqReleaseBars = 2;
input int    ForcedLiqMinReducePerBar = 1;

input double SoftDDPct = 0.10;
input double HardDDPct = 0.20;
input double DailyLossStopPct = 0.05;
input double WeeklyLossStopPct = 0.10;
input int    CooldownSoftHours = 2;
input int    CooldownHardHours = 24;

input double MinMarginLevelPct = 900.0;
input double MaxSpreadPoints = 15.0;
input bool   AllowTrendAddWhenNormal = true;

input double BasketTP_K = 0.4;
input double BasketHardTP_USD = 10.0;
input double RiskPerTrade = 0.005;

CTradeExecutor g_trade;
CRegimeEngine  g_regime;
CInventoryEngine g_inv;
CDeRiskEngine  g_derisk;
CRiskManagerV2 g_risk;

ENUM_V2_STATE g_state = V2_STATE_IDLE;
ENUM_V2_ACTION_GROUP g_action = V2_ACTION_NONE;
datetime g_lastBarTime = 0;
bool g_prevTrend = false;

int OnInit()
{
   g_trade.Init(MagicNumber, Slippage);
   if(!g_regime.Init(TF_Entry, Bias_On, Bias_Off, SlopeZ_Min, SlopeZ_Flat, MinTrendHoldBars, MinRangeHoldBars))
      return INIT_FAILED;

   g_inv.Init(MagicNumber, InventoryBudgetPerSidePct, ForcedLiqReleaseRatio, ForcedLiqReleaseBars);
   g_derisk.Init(StepTrendATRMult, StepMinPoints, StepMaxPoints);
   g_risk.Init(SoftDDPct, HardDDPct, DailyLossStopPct, WeeklyLossStopPct, MinMarginLevelPct, MaxSpreadPoints);

   return INIT_SUCCEEDED;
}

void OnTick()
{
   datetime barTime = iTime(_Symbol, TF_Entry, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;

   g_lastBarTime = barTime;
   g_action = V2_ACTION_NONE;

   g_risk.OnNewBar(barTime);
   if(!g_regime.Update())
      return;

   g_inv.Refresh();

   bool isTrend = g_regime.IsTrend();
   if(isTrend && !g_prevTrend)
      g_derisk.OnTrendEnter(iClose(_Symbol, TF_Entry, 1), g_regime.GetTrendDir());
   if(!isTrend && g_prevTrend)
      g_derisk.OnTrendExit();
   g_prevTrend = isTrend;

   if(g_risk.HardStopTriggered())
   {
      g_state = V2_STATE_FLATTEN;
      if(g_inv.HasPositions())
         g_trade.CloseAll();
      g_risk.SetHardCooldown(barTime, CooldownHardHours);
      g_action = V2_ACTION_FLATTEN;
      return;
   }

   if(g_risk.IsInCooldown(barTime))
   {
      g_state = V2_STATE_COOLDOWN;
      return;
   }

   bool softLock = g_risk.SoftLockActive();
   if(softLock)
      g_risk.SetSoftCooldown(barTime, CooldownSoftHours);

   g_inv.UpdateForcedLiquidation(g_regime.GetTrendDir(), AccountInfoDouble(ACCOUNT_EQUITY));
   bool forcedLiq = g_inv.IsForcedLiquidation();

   if(!g_inv.HasPositions())
   {
      g_state = V2_STATE_IDLE;
      TrySeedHedge(softLock, forcedLiq);
      return;
   }

   if(isTrend || softLock || forcedLiq)
      g_state = V2_STATE_TREND_DE_RISK;
   else
      g_state = V2_STATE_RANGE_GRID;

   if(g_state == V2_STATE_TREND_DE_RISK)
      RunTrendDeRisk(softLock, forcedLiq);

   if(g_action == V2_ACTION_NONE && g_state == V2_STATE_RANGE_GRID)
      RunRangeExitAndAdd(softLock, forcedLiq);

   PrintStatus(softLock, forcedLiq);
}

void TrySeedHedge(bool softLock, bool forcedLiq)
{
   if(softLock || forcedLiq) return;
   if(g_regime.IsTrend()) return;
   if(g_regime.GetBias() > Bias_SeedMax) return;
   if(!g_risk.IsSpreadOk()) return;
   if(IsNewsBlocked()) return;

   double slDistPoints = GetRangeStepPoints() * 2.0;
   double lots = GetLadderLot(0);
   if(lots <= 0.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   double slBuy = NormalizeDouble(ask - slDistPoints * _Point, _Digits);
   double slSell = NormalizeDouble(bid + slDistPoints * _Point, _Digits);

   bool buyOk = g_trade.OpenBuy(lots, slBuy, 0.0, "V2|SEED_BUY");
   bool sellOk = g_trade.OpenSell(lots, slSell, 0.0, "V2|SEED_SELL");

   if(buyOk || sellOk)
   {
      g_state = V2_STATE_SEED_HEDGE;
      g_action = V2_ACTION_ADD;
   }
}

void RunTrendDeRisk(bool softLock, bool forcedLiq)
{
   int trendDir = g_regime.GetTrendDir();
   if(trendDir == 0)
      return;

   double close1 = iClose(_Symbol, TF_Entry, 1);
   double stepTrend = g_derisk.GetTrendStepPoints(g_regime.GetATRPoints());
   bool triggerStep = g_derisk.StepTriggered(close1, stepTrend);

   bool didReduce = false;
   int reductions = 0;

   if(softLock || forcedLiq || triggerStep)
   {
      while(reductions < ForcedLiqMinReducePerBar)
      {
         ulong adverseTicket = g_inv.GetOldestAdverseTicket(trendDir);
         if(adverseTicket == 0) break;
         if(!g_trade.CloseTicket(adverseTicket)) break;
         didReduce = true;
         reductions++;
         g_inv.Refresh();
      }
   }

   bool allowAdd = (!softLock && !forcedLiq && AllowTrendAddWhenNormal);
   bool didAdd = false;

   if(allowAdd && triggerStep)
   {
      didAdd = AddByTrendDirection(trendDir, true);
   }

   if(didReduce || didAdd)
   {
      g_action = V2_ACTION_DE_RISK;
      if(triggerStep)
         g_derisk.AdvanceAnchor(stepTrend);
   }
}

void RunRangeExitAndAdd(bool softLock, bool forcedLiq)
{
   double totalProfit = g_inv.GetTotalProfit();
   double basketTP = CalcDynamicBasketTP();

   if(totalProfit >= BasketHardTP_USD || totalProfit >= basketTP)
   {
      if(g_trade.CloseAll())
      {
         g_action = V2_ACTION_EXIT;
         return;
      }
   }

   if(softLock || forcedLiq) return;
   if(!g_risk.IsSpreadOk()) return;
   if(IsNewsBlocked()) return;

   double stepRange = GetRangeStepPoints();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   double latestBuy = g_inv.GetLatestPriceByTrend(1, true);
   double latestSell = g_inv.GetLatestPriceByTrend(-1, true);

   bool buyTrigger = (latestBuy > 0.0 && bid <= latestBuy - stepRange * _Point);
   bool sellTrigger = (latestSell > 0.0 && ask >= latestSell + stepRange * _Point);

   if(buyTrigger)
   {
      if(AddSide(POSITION_TYPE_BUY, g_inv.GetBuyCount(), "V2|RANGE_BUY"))
         g_action = V2_ACTION_ADD;
      return;
   }

   if(sellTrigger)
   {
      if(AddSide(POSITION_TYPE_SELL, g_inv.GetSellCount(), "V2|RANGE_SELL"))
         g_action = V2_ACTION_ADD;
      return;
   }
}

bool AddByTrendDirection(int trendDir, bool trendMode)
{
   if(trendDir > 0)
      return AddSide(POSITION_TYPE_BUY, g_inv.GetBuyCount(), trendMode ? "V2|TREND_BUY" : "V2|RANGE_BUY");
   if(trendDir < 0)
      return AddSide(POSITION_TYPE_SELL, g_inv.GetSellCount(), trendMode ? "V2|TREND_SELL" : "V2|RANGE_SELL");
   return false;
}

bool AddSide(ENUM_POSITION_TYPE side, int sideCount, string comment)
{
   if(!g_risk.IsSpreadOk()) return false;

   double stopPoints = GetRangeStepPoints() * 2.0;
   double lotsRisk = g_risk.CalcLotsByRisk(stopPoints, RiskPerTrade);
   double lotsLadder = GetLadderLot(sideCount);
   double lots = MathMin(lotsRisk, lotsLadder);
   if(lots <= 0.0) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(side == POSITION_TYPE_BUY)
   {
      double sl = NormalizeDouble(ask - stopPoints * _Point, _Digits);
      return g_trade.OpenBuy(lots, sl, 0.0, comment);
   }

   double sl = NormalizeDouble(bid + stopPoints * _Point, _Digits);
   return g_trade.OpenSell(lots, sl, 0.0, comment);
}

double GetLadderLot(int layer)
{
   if(layer <= 0) return LotL1;
   if(layer == 1) return LotL2;
   if(layer == 2) return LotL3;
   if(layer == 3) return LotL4;
   return LotL5;
}

double GetRangeStepPoints()
{
   double step = g_regime.GetATRPoints() * StepRangeATRMult;
   if(step < StepMinPoints) step = StepMinPoints;
   if(step > StepMaxPoints) step = StepMaxPoints;
   return step;
}

double CalcDynamicBasketTP()
{
   double atrPips = g_regime.GetATRPoints() / 10.0;
   double netLots = MathAbs(g_inv.GetNetLots());
   if(netLots < 0.01) netLots = 0.01;

   double tp = BasketTP_K * atrPips * 10.0 * netLots;
   if(tp < 3.0) tp = 3.0;
   return tp;
}

bool IsNewsBlocked()
{
   // Placeholder: integrate calendar filter in execution environment.
   return false;
}

void PrintStatus(bool softLock, bool forcedLiq)
{
   PrintFormat("V2|State=%d|Action=%d|Trend=%d|Dir=%d|Bias=%.2f|SlopeZ=%.3f|Soft=%d|Forced=%d|PnL=%.2f",
               g_state, g_action, (int)g_regime.IsTrend(), g_regime.GetTrendDir(),
               g_regime.GetBias(), g_regime.GetSlopeZ(), (int)softLock, (int)forcedLiq,
               g_inv.GetTotalProfit());
}
