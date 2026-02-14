//+------------------------------------------------------------------+
//|                                                       MeEA.mq5   |
//|                 Kalman Filter Adaptive Trend Following EA        |
//|                                                                  |
//| Core: Kalman Filter trend estimation + Hurst persistence test   |
//|       + Realized Volatility regime detection                     |
//+------------------------------------------------------------------+
#property copyright "MeEA"
#property version   "1.00"

#include "../Include/CSignalEngine.mqh"
#include "../Include/CRiskManager.mqh"
#include "../Include/CTradeExecutor.mqh"

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

// Kalman Filter
input double KF_ProcessNoise    = 0.01;    // KF: Process noise (larger = more responsive)
input double KF_ObservNoise     = 1.0;     // KF: Observation noise (larger = smoother)
input double KF_ConfBand        = 2.0;     // KF: Confidence band multiplier

// Hurst Exponent
input int    Hurst_Period       = 200;     // Hurst: Lookback period
input double Hurst_Threshold    = 0.55;    // Hurst: Trend threshold

// Volatility Regime
input int    Vol_Period         = 100;     // Vol: RV calculation period
input int    Vol_HistPeriod     = 500;     // Vol: Historical percentile period

// Risk Management
input double Risk_PerTrade      = 0.01;    // Risk: Per trade (0.01 = 1%)
input int    Max_Positions      = 3;       // Risk: Max concurrent positions
input double Max_DailyDD        = 0.03;    // Risk: Max daily drawdown (0.03 = 3%)
input double Max_SpreadPoints   = 30;      // Risk: Max spread in points
input int    Slippage           = 10;      // Execution: Slippage in points
input ulong  MagicNumber        = 20240101;// EA: Magic number

// Timeframe
input ENUM_TIMEFRAMES TF_Entry  = PERIOD_H1; // Timeframe for signal generation

// Visualization
input bool   ShowVisuals        = true;    // Show Kalman bands and signals on chart

//+------------------------------------------------------------------+
//| Global Objects                                                    |
//+------------------------------------------------------------------+
CSignalEngine  g_signal;
CRiskManager   g_risk;
CTradeExecutor g_trade;

datetime       g_lastBarTime    = 0;
datetime       g_lastDay        = 0;
bool           g_entryThisBar   = false;   // track if we opened a position this bar
int            g_barsSinceClose = 100;     // cooldown counter (start high to allow initial trades)
int            g_closeCooldown  = 2;       // bars to wait after close before same-direction re-entry

// Visualization object names
string         g_objPrefix      = "MeEA_";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize modules
    g_signal.Init(KF_ProcessNoise, KF_ObservNoise, KF_ConfBand,
                  Hurst_Period, Hurst_Threshold,
                  Vol_Period, Vol_HistPeriod);

    g_risk.Init(Risk_PerTrade, Max_Positions, Max_DailyDD, Max_SpreadPoints);
    g_trade.Init(MagicNumber, Slippage);

    // Warmup: feed historical bars to Kalman and Hurst
    int warmupBars = MathMax(Hurst_Period, Vol_HistPeriod) + 50;
    int available  = Bars(_Symbol, TF_Entry);
    int barsToLoad = MathMin(warmupBars, available - 1);

    if(barsToLoad < 20)
    {
        Print("MeEA: Insufficient historical bars for warmup. Need at least 20, have ", barsToLoad);
        return INIT_FAILED;
    }

    double closeArr[];
    if(CopyClose(_Symbol, TF_Entry, 1, barsToLoad, closeArr) < barsToLoad)
    {
        Print("MeEA: Failed to copy historical close prices for warmup");
        return INIT_FAILED;
    }

    // Feed historical data — skip first bar (no valid prevClose), start from i=1
    g_signal.OnNewBar(closeArr[0], closeArr[0]);  // init Kalman level only
    for(int i = 1; i < barsToLoad; i++)
        g_signal.OnNewBar(closeArr[i], closeArr[i - 1]);

    Print("MeEA: Initialized. Warmup bars: ", barsToLoad,
          " | Kalman Level: ", DoubleToString(g_signal.GetKalmanLevel(), _Digits),
          " | Hurst: ", DoubleToString(g_signal.GetHurst(), 3),
          " | Vol Regime: ", EnumToString(g_signal.GetVolRegime()));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Clean up chart objects
    ObjectsDeleteAll(0, g_objPrefix);
    Comment("");
    Print("MeEA: Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- New bar detection
    datetime currentBarTime = iTime(_Symbol, TF_Entry, 0);
    if(currentBarTime == g_lastBarTime) return;
    g_lastBarTime = currentBarTime;
    g_entryThisBar = false;
    g_barsSinceClose++;

    //--- New day check (for daily DD reset)
    MqlDateTime dt;
    TimeToStruct(currentBarTime, dt);
    datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                  IntegerToString(dt.mon) + "." +
                                  IntegerToString(dt.day));
    if(today != g_lastDay)
    {
        g_risk.OnNewDay();
        g_lastDay = today;
    }

    //--- Get completed bar data (bar index 1 = just closed)
    double close1    = iClose(_Symbol, TF_Entry, 1);
    double close2    = iClose(_Symbol, TF_Entry, 2);
    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(close1 <= 0.0 || close2 <= 0.0 || currentBid <= 0.0) return;

    //--- Update all analysis modules with the new completed bar
    g_signal.OnNewBar(close1, close2);

    //--- Check exit conditions for existing positions
    if(g_trade.CountPositions(POSITION_TYPE_BUY) > 0 && g_signal.ShouldCloseBuy())
    {
        g_trade.CloseByType(POSITION_TYPE_BUY);
        g_barsSinceClose = 0;
        Print("MeEA: Closed BUY positions. Slope: ", DoubleToString(g_signal.GetKalmanSlope(), 6),
              " Hurst: ", DoubleToString(g_signal.GetHurst(), 3));
    }

    if(g_trade.CountPositions(POSITION_TYPE_SELL) > 0 && g_signal.ShouldCloseSell())
    {
        g_trade.CloseByType(POSITION_TYPE_SELL);
        g_barsSinceClose = 0;
        Print("MeEA: Closed SELL positions. Slope: ", DoubleToString(g_signal.GetKalmanSlope(), 6),
              " Hurst: ", DoubleToString(g_signal.GetHurst(), 3));
    }

    //--- Check entry signals
    ENUM_SIGNAL entrySignal = g_signal.GetEntrySignal(currentBid);
    int totalPos = g_trade.CountAllPositions();

    // Reverse position protection: block entry if opposite position exists
    if(entrySignal == SIGNAL_BUY && g_trade.CountPositions(POSITION_TYPE_SELL) > 0)
        entrySignal = SIGNAL_NONE;
    if(entrySignal == SIGNAL_SELL && g_trade.CountPositions(POSITION_TYPE_BUY) > 0)
        entrySignal = SIGNAL_NONE;

    // Cooldown: block re-entry too soon after close
    if(entrySignal != SIGNAL_NONE && g_barsSinceClose < g_closeCooldown)
        entrySignal = SIGNAL_NONE;

    if(entrySignal != SIGNAL_NONE && g_risk.CanOpenTrade(totalPos))
    {
        double kalmanLevel = g_signal.GetKalmanLevel();
        double estError    = g_signal.GetEstimationError();
        ENUM_VOL_REGIME regime = g_signal.GetVolRegime();

        // Calculate stop loss using Kalman estimation error
        double sl = g_risk.GetStopLoss(entrySignal, kalmanLevel, estError, KF_ConfBand);

        // Calculate position size
        double entryPrice = (entrySignal == SIGNAL_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double stopPoints = g_risk.GetStopPoints(entryPrice, sl);
        double lots = g_risk.CalcLots(stopPoints, regime);

        if(lots > 0.0)
        {
            string comment = StringFormat("MeEA|H=%.2f|S=%.6f|V=%s",
                                          g_signal.GetHurst(),
                                          g_signal.GetKalmanSlope(),
                                          EnumToString(regime));

            if(entrySignal == SIGNAL_BUY)
            {
                if(g_trade.OpenBuy(lots, sl, 0.0, comment))
                {
                    Print("MeEA: BUY ", DoubleToString(lots, 2), " lots @ ",
                          DoubleToString(entryPrice, _Digits), " SL=", DoubleToString(sl, _Digits));
                    g_entryThisBar = true;

                    if(ShowVisuals)
                        DrawArrow("BUY", currentBarTime, close1, clrLime, 233);  // arrow up
                }
            }
            else if(entrySignal == SIGNAL_SELL)
            {
                if(g_trade.OpenSell(lots, sl, 0.0, comment))
                {
                    Print("MeEA: SELL ", DoubleToString(lots, 2), " lots @ ",
                          DoubleToString(entryPrice, _Digits), " SL=", DoubleToString(sl, _Digits));
                    g_entryThisBar = true;

                    if(ShowVisuals)
                        DrawArrow("SELL", currentBarTime, close1, clrRed, 234);  // arrow down
                }
            }
        }
    }

    //--- Trailing stop update (skip on the bar of entry to preserve initial wider stop)
    if(!g_entryThisBar && g_trade.CountAllPositions() > 0)
    {
        double level = g_signal.GetKalmanLevel();
        double err   = g_signal.GetEstimationError();

        // Trail SL to Kalman level +/- 1*estimation error
        double trailBuy  = NormalizeDouble(level - err, _Digits);
        double trailSell = NormalizeDouble(level + err, _Digits);

        g_trade.TrailStopLoss(trailBuy, trailSell);
    }

    //--- Chart visualization
    if(ShowVisuals)
        UpdateVisuals(currentBarTime);
}

//+------------------------------------------------------------------+
//| Draw entry arrow on chart                                         |
//+------------------------------------------------------------------+
void DrawArrow(string label, datetime time, double price, color clr, int arrowCode)
{
    string name = g_objPrefix + label + "_" + IntegerToString((long)time);
    ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrowCode);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Update chart visualization: Kalman bands + info comment           |
//+------------------------------------------------------------------+
void UpdateVisuals(datetime barTime)
{
    double level    = g_signal.GetKalmanLevel();
    double upper    = g_signal.GetUpperBand();
    double lower    = g_signal.GetLowerBand();

    // Kalman Level line
    string nameLvl = g_objPrefix + "Level_" + IntegerToString((long)barTime);
    datetime prevBar = iTime(_Symbol, TF_Entry, 1);

    // Draw as trend line from previous bar to current
    ObjectCreate(0, nameLvl, OBJ_TREND, 0, prevBar, level, barTime, level);
    ObjectSetInteger(0, nameLvl, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, nameLvl, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, nameLvl, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, nameLvl, OBJPROP_SELECTABLE, false);

    // Upper band
    string nameUp = g_objPrefix + "Upper_" + IntegerToString((long)barTime);
    ObjectCreate(0, nameUp, OBJ_TREND, 0, prevBar, upper, barTime, upper);
    ObjectSetInteger(0, nameUp, OBJPROP_COLOR, clrGray);
    ObjectSetInteger(0, nameUp, OBJPROP_STYLE, STYLE_DOT);
    ObjectSetInteger(0, nameUp, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, nameUp, OBJPROP_SELECTABLE, false);

    // Lower band
    string nameLo = g_objPrefix + "Lower_" + IntegerToString((long)barTime);
    ObjectCreate(0, nameLo, OBJ_TREND, 0, prevBar, lower, barTime, lower);
    ObjectSetInteger(0, nameLo, OBJPROP_COLOR, clrGray);
    ObjectSetInteger(0, nameLo, OBJPROP_STYLE, STYLE_DOT);
    ObjectSetInteger(0, nameLo, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, nameLo, OBJPROP_SELECTABLE, false);

    // Info comment
    string volRegimeStr = EnumToString(g_signal.GetVolRegime());
    Comment(StringFormat("MeEA | Kalman: %."+IntegerToString(_Digits)+"f | Slope: %.6f | H: %.3f | Vol: %s (%.1f%%)",
            level, g_signal.GetKalmanSlope(), g_signal.GetHurst(),
            volRegimeStr, g_signal.GetVolPercentile() * 100.0));
}
