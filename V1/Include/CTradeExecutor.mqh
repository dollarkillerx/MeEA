//+------------------------------------------------------------------+
//|                                            CTradeExecutor.mqh    |
//|                    Trade Execution & Order Management            |
//|                                                                  |
//| - Market order execution (Buy/Sell)                              |
//| - SL/TP management                                               |
//| - Position modification (trailing stop)                          |
//| - Close by direction                                             |
//| - Magic number filtering                                         |
//+------------------------------------------------------------------+
#ifndef C_TRADE_EXECUTOR_MQH
#define C_TRADE_EXECUTOR_MQH

#property copyright "MeEA"

#include <Trade/Trade.mqh>

class CTradeExecutor
{
private:
    CTrade m_trade;
    ulong  m_magic;
    int    m_slippage;

public:
    CTradeExecutor() : m_magic(20240101), m_slippage(10) {}

    void Init(ulong magic, int slippage)
    {
        m_magic    = magic;
        m_slippage = slippage;
        m_trade.SetExpertMagicNumber(magic);
        m_trade.SetDeviationInPoints(slippage);

        // Detect broker-supported filling mode
        long fillType = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
        if((fillType & SYMBOL_FILLING_FOK) != 0)
            m_trade.SetTypeFilling(ORDER_FILLING_FOK);
        else if((fillType & SYMBOL_FILLING_IOC) != 0)
            m_trade.SetTypeFilling(ORDER_FILLING_IOC);
        else
            m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
    }

    //--- Open a buy position
    bool OpenBuy(double lots, double sl, double tp, string comment)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if(ask <= 0.0) return false;

        // Normalize prices
        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        sl = NormalizeDouble(sl, digits);
        tp = NormalizeDouble(tp, digits);

        return m_trade.Buy(lots, _Symbol, ask, sl, tp, comment);
    }

    //--- Open a sell position
    bool OpenSell(double lots, double sl, double tp, string comment)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(bid <= 0.0) return false;

        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        sl = NormalizeDouble(sl, digits);
        tp = NormalizeDouble(tp, digits);

        return m_trade.Sell(lots, _Symbol, bid, sl, tp, comment);
    }

    //--- Modify stop loss of a specific position
    bool ModifySL(ulong ticket, double newSL)
    {
        if(!PositionSelectByTicket(ticket)) return false;

        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        newSL = NormalizeDouble(newSL, digits);

        double currentTP = PositionGetDouble(POSITION_TP);
        if(!m_trade.PositionModify(ticket, newSL, currentTP))
        {
            Print("MeEA: ModifySL failed for ticket ", ticket,
                  " Error: ", GetLastError());
            return false;
        }
        return true;
    }

    //--- Close all positions of a given type owned by this EA
    bool CloseByType(ENUM_POSITION_TYPE posType)
    {
        bool allClosed = true;
        int total = PositionsTotal();

        for(int i = total - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;

            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

            if(!m_trade.PositionClose(ticket))
                allClosed = false;
        }
        return allClosed;
    }

    //--- Count positions of a specific type for this EA on current symbol
    int CountPositions(ENUM_POSITION_TYPE posType)
    {
        int count = 0;
        int total = PositionsTotal();

        for(int i = 0; i < total; i++)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;

            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
                count++;
        }
        return count;
    }

    //--- Count all positions for this EA on current symbol
    int CountAllPositions()
    {
        int count = 0;
        int total = PositionsTotal();

        for(int i = 0; i < total; i++)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;

            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
            count++;
        }
        return count;
    }

    //--- Update trailing stop for all positions of this EA
    void TrailStopLoss(double newSL_Buy, double newSL_Sell)
    {
        int total = PositionsTotal();
        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

        for(int i = total - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;

            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;

            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double currentSL = PositionGetDouble(POSITION_SL);

            if(posType == POSITION_TYPE_BUY && newSL_Buy > 0.0)
            {
                double sl = NormalizeDouble(newSL_Buy, digits);
                // Only tighten SL: original SL must exist and new SL must be higher
                if(currentSL > 0.0 && sl > currentSL)
                    ModifySL(ticket, sl);
            }
            else if(posType == POSITION_TYPE_SELL && newSL_Sell > 0.0)
            {
                double sl = NormalizeDouble(newSL_Sell, digits);
                // Only tighten SL: original SL must exist and new SL must be lower
                if(currentSL > 0.0 && sl < currentSL)
                    ModifySL(ticket, sl);
            }
        }
    }

    //--- Get the magic number
    ulong GetMagic() { return m_magic; }
};

#endif // C_TRADE_EXECUTOR_MQH
