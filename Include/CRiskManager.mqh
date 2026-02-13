//+------------------------------------------------------------------+
//|                                              CRiskManager.mqh    |
//|                    Risk Management & Position Sizing             |
//|                                                                  |
//| - Position sizing based on risk percentage                       |
//| - Volatility regime adjustment                                   |
//| - Daily drawdown limit                                           |
//| - Max positions & spread filter                                  |
//+------------------------------------------------------------------+
#ifndef C_RISK_MANAGER_MQH
#define C_RISK_MANAGER_MQH

#property copyright "MeEA"

#include "CSignalEngine.mqh"

class CRiskManager
{
private:
    double m_riskPerTrade;     // risk per trade as fraction (e.g. 0.01 = 1%)
    int    m_maxPositions;     // max concurrent positions
    double m_maxDailyDD;       // max daily drawdown fraction
    double m_maxSpread;        // max spread in points
    double m_dayStartEquity;   // equity at start of day

public:
    CRiskManager() : m_riskPerTrade(0.01), m_maxPositions(3),
                     m_maxDailyDD(0.03), m_maxSpread(30.0),
                     m_dayStartEquity(0.0) {}

    void Init(double riskPct, int maxPos, double maxDD, double maxSpread)
    {
        m_riskPerTrade   = riskPct;
        m_maxPositions   = maxPos;
        m_maxDailyDD     = maxDD;
        m_maxSpread      = maxSpread;
        m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    }

    //--- Reset daily equity tracker (call on new trading day)
    void OnNewDay()
    {
        m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    }

    //--- Calculate position size in lots
    double CalcLots(double stopPoints, ENUM_VOL_REGIME regime)
    {
        if(stopPoints <= 0.0) return 0.0;

        double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double pointVal  = (tickSize > 0) ? tickValue / tickSize * _Point : tickValue;

        if(pointVal <= 0.0) return 0.0;

        double riskAmount = equity * m_riskPerTrade;
        double lots = riskAmount / (stopPoints * pointVal);

        // Volatility regime adjustment:
        // LOW vol = reduce size (avoid choppy false breakouts)
        // HIGH vol = reduce size (wider stops, higher risk per point)
        switch(regime)
        {
            case VOL_LOW:    lots *= 0.5; break;
            case VOL_NORMAL: lots *= 1.0; break;
            case VOL_HIGH:   lots *= 0.7; break;
        }

        // Normalize to broker constraints
        double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

        if(lotStep > 0.0)
            lots = MathFloor(lots / lotStep) * lotStep;

        if(lots < minLot) lots = minLot;
        if(lots > maxLot) lots = maxLot;

        return lots;
    }

    //--- Comprehensive check: can we open a new trade?
    bool CanOpenTrade(int currentPositions)
    {
        // Max positions check
        if(currentPositions >= m_maxPositions)
            return false;

        // Daily drawdown check
        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        if(m_dayStartEquity > 0.0)
        {
            double dayPnL = equity - m_dayStartEquity;
            if(dayPnL < 0 && MathAbs(dayPnL) / m_dayStartEquity > m_maxDailyDD)
                return false;
        }

        // Spread check (SYMBOL_SPREAD returns spread in points directly)
        long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
        if((double)spreadPoints > m_maxSpread)
            return false;

        return true;
    }

    //--- Calculate stop loss price
    double GetStopLoss(ENUM_SIGNAL signal, double kalmanLevel, double estError, double multiplier)
    {
        double stopDist = estError * multiplier;

        if(signal == SIGNAL_BUY)
            return kalmanLevel - stopDist;
        else if(signal == SIGNAL_SELL)
            return kalmanLevel + stopDist;

        return 0.0;
    }

    //--- Get stop distance in points for position sizing
    double GetStopPoints(double entryPrice, double stopLoss)
    {
        return MathAbs(entryPrice - stopLoss) / _Point;
    }
};

#endif // C_RISK_MANAGER_MQH
