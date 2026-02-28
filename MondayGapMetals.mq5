//+------------------------------------------------------------------+
//|                                             MondayGapMetals.mq5  |
//|                        Monday Opening Gap - Mean Reversion on XAU|
//+------------------------------------------------------------------+
#property copyright "MondayGapMetals EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input parameters                                                  |
//+------------------------------------------------------------------+
input double LotSize        = 0.1;    // Fixed lot size
input int    MinGapPoints   = 50;     // Minimum gap size in points to trigger trade
input int    StopLossPoints = 500;    // Stop loss distance in points
input int    MagicNumber    = 202601; // Unique EA magic number
input int    MaxSlippage    = 30;     // Maximum slippage in points
input int    EntryHour      = 0;      // Hour (server time) to check for gap on Monday

//+------------------------------------------------------------------+
//| Global variables                                                  |
//+------------------------------------------------------------------+
CTrade trade;
bool   hasTraded;
int    lastTradedWeek;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hasTraded      = false;
   lastTradedWeek = -1;

   Print("MondayGapMetals EA initialized | Lot=", LotSize,
         " MinGap=", MinGapPoints, " SL=", StopLossPoints);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MondayGapMetals EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Check if a position with our magic number is already open         |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get the ISO week number for a given datetime                      |
//+------------------------------------------------------------------+
int GetWeekNumber(datetime time)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);
   // Use day_of_year / 7 as a simple week identifier
   return (dt.year * 100) + (dt.day_of_year / 7);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Get current server time
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   // Only trade on Monday (day_of_week == 1)
   if(dt.day_of_week != 1)
   {
      // Reset the flag when it's no longer Monday
      // (handled via week number check below)
      return;
   }

   // Only check at or after the configured entry hour
   if(dt.hour < EntryHour)
      return;

   // Check if we already traded this week
   int currentWeek = GetWeekNumber(currentTime);
   if(currentWeek == lastTradedWeek)
      return;

   // Don't trade if we already have an open position
   if(HasOpenPosition())
      return;

   // Get daily bars for Friday close and Monday open
   double dailyClose[];
   double dailyOpen[];
   ArraySetAsSeries(dailyClose, true);
   ArraySetAsSeries(dailyOpen, true);

   // Copy the last 2 daily bars: index 0 = today (Monday), index 1 = previous (Friday)
   if(CopyClose(_Symbol, PERIOD_D1, 0, 2, dailyClose) < 2)
   {
      Print("Failed to copy daily close prices");
      return;
   }
   if(CopyOpen(_Symbol, PERIOD_D1, 0, 2, dailyOpen) < 2)
   {
      Print("Failed to copy daily open prices");
      return;
   }

   double fridayClose = dailyClose[1];
   double mondayOpen  = dailyOpen[0];

   // Calculate gap in points
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double gapSize = MathAbs(mondayOpen - fridayClose) / point;

   Print("Monday Gap Check | FridayClose=", fridayClose,
         " MondayOpen=", mondayOpen,
         " GapPoints=", gapSize);

   // Check minimum gap threshold
   if(gapSize < MinGapPoints)
   {
      Print("Gap too small (", gapSize, " < ", MinGapPoints, "). No trade.");
      lastTradedWeek = currentWeek; // Don't recheck this week
      return;
   }

   // Determine trade direction (mean reversion = trade against the gap)
   double sl, tp;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(mondayOpen > fridayClose)
   {
      // Gap Up -> SELL (expect price to fall back to Friday's close)
      sl = bid + StopLossPoints * point;
      tp = fridayClose;

      Print("Gap UP detected. SELL signal | Entry~", bid, " SL=", sl, " TP=", tp);

      if(!trade.Sell(LotSize, _Symbol, bid, sl, tp, "MondayGap SELL"))
      {
         Print("Sell order failed. Error: ", GetLastError());
         return;
      }
   }
   else
   {
      // Gap Down -> BUY (expect price to rise back to Friday's close)
      sl = ask - StopLossPoints * point;
      tp = fridayClose;

      Print("Gap DOWN detected. BUY signal | Entry~", ask, " SL=", sl, " TP=", tp);

      if(!trade.Buy(LotSize, _Symbol, ask, sl, tp, "MondayGap BUY"))
      {
         Print("Buy order failed. Error: ", GetLastError());
         return;
      }
   }

   // Mark this week as traded
   lastTradedWeek = currentWeek;
   hasTraded      = true;

   Print("Trade placed successfully. Week marked as traded: ", currentWeek);
}
//+------------------------------------------------------------------+
