//+------------------------------------------------------------------+
//|                                        FibonacciGoldenZone.mq5   |
//|                        Fibonacci Golden Zone Trading Strategy     |
//|                        Based on Trading Strategy Guides PDF       |
//+------------------------------------------------------------------+
#property copyright "Fibonacci Golden Zone EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   InpLotSize        = 0.1;     // Lot Size
input int      InpMagicNumber    = 123456;  // Magic Number
input int      InpMaxSpread      = 30;      // Max Spread (points)
input int      InpSlippage       = 10;      // Slippage (points)

input group "=== Swing Detection ==="
input int      InpSwingStrength  = 5;       // Swing Strength (bars on each side)
input int      InpLookback       = 100;     // Lookback Bars for Swing Detection

input group "=== Fibonacci Settings ==="
input double   InpGoldenZoneUpper = 61.8;   // Golden Zone Upper (%)
input double   InpGoldenZoneLower = 38.2;   // Golden Zone Lower (%)
input double   InpSLBuffer        = 10;     // SL Buffer Beyond 100% Fib (points)
input double   InpTPBuffer        = 10;     // TP Buffer Beyond Swing (points)

input group "=== Multi-Timeframe Settings ==="
input int      InpMTF_MinAgree   = 5;       // Min TFs Agreeing for Confirmation
input bool     InpUseMTF         = true;    // Use Multi-Timeframe Filter

input group "=== Trade Management ==="
input bool     InpOneTradePerSignal = true;  // Only One Trade at a Time
input bool     InpDrawFibLevels    = true;   // Draw Fibonacci Levels on Chart

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
int            lastTradeBar = 0;

// Fibonacci level storage
double         fibLevel_0   = 0;  // 0% (swing end - trend continuation side)
double         fibLevel_236 = 0;  // 23.6%
double         fibLevel_382 = 0;  // 38.2%
double         fibLevel_500 = 0;  // 50%
double         fibLevel_618 = 0;  // 61.8%
double         fibLevel_786 = 0;  // 78.6%
double         fibLevel_100 = 0;  // 100% (swing start - retracement origin)

// Swing points
double         swingHigh = 0;
double         swingLow  = 0;
int            swingHighBar = 0;
int            swingLowBar  = 0;

// Trend
enum ENUM_TREND { TREND_UP, TREND_DOWN, TREND_NONE };
ENUM_TREND     currentTrend = TREND_NONE;

// MTF timeframes to analyze
ENUM_TIMEFRAMES mtfTimeframes[] = {
   PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30,
   PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1, PERIOD_MN1
};

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("Fibonacci Golden Zone EA initialized");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(_Period));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up chart objects
   ObjectsDeleteAll(0, "FGZ_");
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process on new bar
   if(!IsNewBar())
      return;

   // Check spread
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
      return;

   // Check if we already have a position
   if(InpOneTradePerSignal && HasOpenPosition())
      return;

   // Step 1: Detect swing highs and swing lows
   if(!DetectSwingPoints())
      return;

   // Step 2: Determine the trend
   currentTrend = DetermineTrend();
   if(currentTrend == TREND_NONE)
      return;

   // Step 3: Calculate Fibonacci retracement levels
   CalculateFibLevels();

   // Step 4: Draw levels on chart
   if(InpDrawFibLevels)
      DrawFibonacciLevels();

   // Step 5: Check for trade entry signals
   CheckForEntry();

   // Update chart comment
   UpdateComment();
}

//+------------------------------------------------------------------+
//| Check for new bar                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if we have an open position for this EA                     |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Swing High and Swing Low points                            |
//| Swing High: candle with at least N lower highs on both sides      |
//| Swing Low:  candle with at least N higher lows on both sides      |
//+------------------------------------------------------------------+
bool DetectSwingPoints()
{
   int swingStr = InpSwingStrength;
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int copied_h = CopyHigh(_Symbol, _Period, 0, InpLookback, highs);
   int copied_l = CopyLow(_Symbol, _Period, 0, InpLookback, lows);

   if(copied_h < InpLookback || copied_l < InpLookback)
      return false;

   // Find the most recent swing high (start from bar swingStr+1 to allow confirmation)
   bool foundHigh = false;
   for(int i = swingStr; i < InpLookback - swingStr; i++)
   {
      if(IsSwingHigh(highs, i, swingStr))
      {
         swingHigh = highs[i];
         swingHighBar = i;
         foundHigh = true;
         break;
      }
   }

   // Find the most recent swing low
   bool foundLow = false;
   for(int i = swingStr; i < InpLookback - swingStr; i++)
   {
      if(IsSwingLow(lows, i, swingStr))
      {
         swingLow = lows[i];
         swingLowBar = i;
         foundLow = true;
         break;
      }
   }

   return (foundHigh && foundLow);
}

//+------------------------------------------------------------------+
//| Check if a bar is a swing high                                    |
//+------------------------------------------------------------------+
bool IsSwingHigh(const double &highs[], int index, int strength)
{
   double centerHigh = highs[index];

   // Check left side (bars with higher index = older bars)
   for(int i = 1; i <= strength; i++)
   {
      if(highs[index + i] >= centerHigh)
         return false;
   }

   // Check right side (bars with lower index = newer bars)
   for(int i = 1; i <= strength; i++)
   {
      if(highs[index - i] >= centerHigh)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check if a bar is a swing low                                     |
//+------------------------------------------------------------------+
bool IsSwingLow(const double &lows[], int index, int strength)
{
   double centerLow = lows[index];

   // Check left side
   for(int i = 1; i <= strength; i++)
   {
      if(lows[index + i] <= centerLow)
         return false;
   }

   // Check right side
   for(int i = 1; i <= strength; i++)
   {
      if(lows[index - i] <= centerLow)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Determine trend direction                                         |
//| Uptrend:   Higher Highs + Higher Lows                             |
//| Downtrend: Lower Lows + Lower Highs                               |
//+------------------------------------------------------------------+
ENUM_TREND DetermineTrend()
{
   int swingStr = InpSwingStrength;
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   CopyHigh(_Symbol, _Period, 0, InpLookback, highs);
   CopyLow(_Symbol, _Period, 0, InpLookback, lows);

   // Collect multiple swing highs and lows
   double swHighs[];
   double swLows[];
   ArrayResize(swHighs, 0);
   ArrayResize(swLows, 0);

   for(int i = swingStr; i < InpLookback - swingStr; i++)
   {
      if(IsSwingHigh(highs, i, swingStr))
      {
         int size = ArraySize(swHighs);
         ArrayResize(swHighs, size + 1);
         swHighs[size] = highs[i];
         if(ArraySize(swHighs) >= 3) break;
      }
   }

   for(int i = swingStr; i < InpLookback - swingStr; i++)
   {
      if(IsSwingLow(lows, i, swingStr))
      {
         int size = ArraySize(swLows);
         ArrayResize(swLows, size + 1);
         swLows[size] = lows[i];
         if(ArraySize(swLows) >= 3) break;
      }
   }

   if(ArraySize(swHighs) < 2 || ArraySize(swLows) < 2)
      return TREND_NONE;

   // swHighs[0] is most recent, swHighs[1] is previous
   // Uptrend: most recent swing high > previous swing high AND most recent swing low > previous swing low
   bool higherHighs = swHighs[0] > swHighs[1];
   bool higherLows  = swLows[0] > swLows[1];
   bool lowerHighs  = swHighs[0] < swHighs[1];
   bool lowerLows   = swLows[0] < swLows[1];

   if(higherHighs && higherLows)
      return TREND_UP;
   if(lowerHighs && lowerLows)
      return TREND_DOWN;

   // Partial trend detection: if at least one condition matches
   if(higherHighs || higherLows)
      return TREND_UP;
   if(lowerHighs || lowerLows)
      return TREND_DOWN;

   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| Calculate Fibonacci Retracement Levels                            |
//| Uptrend:   Fib from Swing Low (0%) to Swing High (100%)          |
//|            Retracement goes DOWN from the high                    |
//| Downtrend: Fib from Swing High (0%) to Swing Low (100%)          |
//|            Retracement goes UP from the low                       |
//+------------------------------------------------------------------+
void CalculateFibLevels()
{
   double range = 0;

   if(currentTrend == TREND_UP)
   {
      // In uptrend, we draw fib from swing low to swing high
      // Retracement levels measure how far price pulls back DOWN
      // 0% = swing high (top), 100% = swing low (bottom)
      range = swingHigh - swingLow;

      fibLevel_0   = swingHigh;                           // 0%   - no retracement
      fibLevel_236 = swingHigh - range * 0.236;           // 23.6%
      fibLevel_382 = swingHigh - range * 0.382;           // 38.2% - Golden Zone top
      fibLevel_500 = swingHigh - range * 0.500;           // 50%
      fibLevel_618 = swingHigh - range * 0.618;           // 61.8% - Golden Ratio
      fibLevel_786 = swingHigh - range * 0.786;           // 78.6%
      fibLevel_100 = swingLow;                            // 100% - full retracement
   }
   else if(currentTrend == TREND_DOWN)
   {
      // In downtrend, we draw fib from swing high to swing low
      // Retracement levels measure how far price pulls back UP
      // 0% = swing low (bottom), 100% = swing high (top)
      range = swingHigh - swingLow;

      fibLevel_0   = swingLow;                            // 0%   - no retracement
      fibLevel_236 = swingLow + range * 0.236;            // 23.6%
      fibLevel_382 = swingLow + range * 0.382;            // 38.2% - Golden Zone bottom
      fibLevel_500 = swingLow + range * 0.500;            // 50%
      fibLevel_618 = swingLow + range * 0.618;            // 61.8% - Golden Ratio
      fibLevel_786 = swingLow + range * 0.786;            // 78.6%
      fibLevel_100 = swingHigh;                           // 100% - full retracement
   }
}

//+------------------------------------------------------------------+
//| Check for trade entry                                             |
//| BUY:  Uptrend + price retraces to golden zone + closes above     |
//|       61.8% after testing it                                      |
//| SELL: Downtrend + price retraces to golden zone + closes below    |
//|       61.8% after testing it                                      |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   // Get the last closed candle (bar index 1)
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);

   // Get the candle before that (bar index 2) - to see if we were in the golden zone
   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol, _Period, 2);
   double low2   = iLow(_Symbol, _Period, 2);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // ================================================================
   // BUY SIGNAL (Uptrend)
   // ================================================================
   if(currentTrend == TREND_UP)
   {
      // In uptrend, price retraces DOWN into the golden zone
      // Golden zone: between fibLevel_382 (higher) and fibLevel_618 (lower)
      // Entry: price tests the 61.8% level and closes ABOVE it

      bool priceWasInGoldenZone = (low2 <= fibLevel_382 && low2 >= fibLevel_618) ||
                                   (close2 <= fibLevel_382 && close2 >= fibLevel_618);

      bool priceTestedGoldenRatio = (low1 <= fibLevel_618 + 20 * point);  // touched or came close to 61.8%

      bool closedAbove618 = (close1 > fibLevel_618);  // closed above the 61.8% level

      bool candleInZone = (low1 <= fibLevel_382);  // candle reached into the golden zone

      if((priceWasInGoldenZone || candleInZone) && priceTestedGoldenRatio && closedAbove618)
      {
         // Multi-timeframe confirmation
         if(InpUseMTF && !MTFConfirmation(true))
            return;

         // Calculate SL and TP
         double sl = fibLevel_100 - InpSLBuffer * point;  // Below swing low
         double tp = swingHigh + InpTPBuffer * point;      // Above previous swing high

         // Validate SL/TP
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(sl >= ask || tp <= ask)
            return;

         // Place BUY order
         if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "FGZ Buy - Golden Zone"))
         {
            Print("BUY order placed: Entry=", ask, " SL=", sl, " TP=", tp);
            Print("Fib 61.8%=", fibLevel_618, " Fib 38.2%=", fibLevel_382);
         }
      }
   }

   // ================================================================
   // SELL SIGNAL (Downtrend)
   // ================================================================
   if(currentTrend == TREND_DOWN)
   {
      // In downtrend, price retraces UP into the golden zone
      // Golden zone: between fibLevel_382 (lower) and fibLevel_618 (higher)
      // Entry: price tests the 61.8% level and closes BELOW it

      bool priceWasInGoldenZone = (high2 >= fibLevel_382 && high2 <= fibLevel_618) ||
                                   (close2 >= fibLevel_382 && close2 <= fibLevel_618);

      bool priceTestedGoldenRatio = (high1 >= fibLevel_618 - 20 * point);  // touched or came close to 61.8%

      bool closedBelow618 = (close1 < fibLevel_618);  // closed below the 61.8% level

      bool candleInZone = (high1 >= fibLevel_382);  // candle reached into the golden zone

      if((priceWasInGoldenZone || candleInZone) && priceTestedGoldenRatio && closedBelow618)
      {
         // Multi-timeframe confirmation
         if(InpUseMTF && !MTFConfirmation(false))
            return;

         // Calculate SL and TP
         double sl = fibLevel_100 + InpSLBuffer * point;  // Above swing high
         double tp = swingLow - InpTPBuffer * point;       // Below previous swing low

         // Validate SL/TP
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(sl <= bid || tp >= bid)
            return;

         // Place SELL order
         if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "FGZ Sell - Golden Zone"))
         {
            Print("SELL order placed: Entry=", bid, " SL=", sl, " TP=", tp);
            Print("Fib 61.8%=", fibLevel_618, " Fib 38.2%=", fibLevel_382);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Multi-Timeframe Confirmation                                      |
//| Checks if the majority of timeframes agree with trade direction   |
//| For BUY:  price should be ABOVE the golden zone on most TFs       |
//| For SELL: price should be BELOW the golden zone on most TFs       |
//+------------------------------------------------------------------+
bool MTFConfirmation(bool isBuy)
{
   int agreeCount = 0;
   int totalTF = ArraySize(mtfTimeframes);

   for(int t = 0; t < totalTF; t++)
   {
      ENUM_TIMEFRAMES tf = mtfTimeframes[t];

      // Get swing points on this timeframe
      double tfSwingHigh = 0, tfSwingLow = 0;
      if(!GetTFSwingPoints(tf, tfSwingHigh, tfSwingLow))
         continue;

      if(tfSwingHigh <= tfSwingLow)
         continue;

      double range = tfSwingHigh - tfSwingLow;
      double tfClose = iClose(_Symbol, tf, 0);

      if(isBuy)
      {
         // For buy: check if price is above the golden zone midpoint (bullish)
         // Golden zone in uptrend retracement: between high - 38.2%*range and high - 61.8%*range
         double goldenZoneMid = tfSwingHigh - range * 0.500;
         if(tfClose > goldenZoneMid)
            agreeCount++;
      }
      else
      {
         // For sell: check if price is below the golden zone midpoint (bearish)
         double goldenZoneMid = tfSwingLow + range * 0.500;
         if(tfClose < goldenZoneMid)
            agreeCount++;
      }
   }

   Print("MTF Confirmation: ", agreeCount, "/", totalTF, " TFs agree (need ", InpMTF_MinAgree, ")");
   return (agreeCount >= InpMTF_MinAgree);
}

//+------------------------------------------------------------------+
//| Get swing high/low for a specific timeframe                       |
//+------------------------------------------------------------------+
bool GetTFSwingPoints(ENUM_TIMEFRAMES tf, double &sh, double &sl)
{
   int strength = InpSwingStrength;
   int lookback = InpLookback;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int copied_h = CopyHigh(_Symbol, tf, 0, lookback, highs);
   int copied_l = CopyLow(_Symbol, tf, 0, lookback, lows);

   if(copied_h < lookback || copied_l < lookback)
      return false;

   bool foundHigh = false, foundLow = false;

   for(int i = strength; i < lookback - strength; i++)
   {
      if(!foundHigh && IsSwingHigh(highs, i, strength))
      {
         sh = highs[i];
         foundHigh = true;
      }
      if(!foundLow && IsSwingLow(lows, i, strength))
      {
         sl = lows[i];
         foundLow = true;
      }
      if(foundHigh && foundLow)
         break;
   }

   return (foundHigh && foundLow);
}

//+------------------------------------------------------------------+
//| Draw Fibonacci levels on the chart                                |
//+------------------------------------------------------------------+
void DrawFibonacciLevels()
{
   // Clean previous objects
   ObjectsDeleteAll(0, "FGZ_");

   datetime timeStart = iTime(_Symbol, _Period, MathMax(swingHighBar, swingLowBar));
   datetime timeEnd   = iTime(_Symbol, _Period, 0);

   color clrZone = (currentTrend == TREND_UP) ? clrDodgerBlue : clrOrangeRed;

   // Draw fib levels as horizontal lines
   DrawHLine("FGZ_Fib_0",     fibLevel_0,   clrGray,       STYLE_DOT,   1, "0%");
   DrawHLine("FGZ_Fib_236",   fibLevel_236, clrDarkGray,   STYLE_DOT,   1, "23.6%");
   DrawHLine("FGZ_Fib_382",   fibLevel_382, clrGold,       STYLE_SOLID, 2, "38.2% (Golden Zone)");
   DrawHLine("FGZ_Fib_500",   fibLevel_500, clrOrange,     STYLE_DASH,  1, "50%");
   DrawHLine("FGZ_Fib_618",   fibLevel_618, clrRed,        STYLE_SOLID, 2, "61.8% (Golden Ratio)");
   DrawHLine("FGZ_Fib_786",   fibLevel_786, clrDarkGray,   STYLE_DOT,   1, "78.6%");
   DrawHLine("FGZ_Fib_100",   fibLevel_100, clrGray,       STYLE_DOT,   1, "100%");

   // Draw golden zone rectangle
   datetime rectStart = iTime(_Symbol, _Period, InpLookback / 2);
   datetime rectEnd   = timeEnd + PeriodSeconds(_Period) * 20;

   ObjectCreate(0, "FGZ_GoldenZone", OBJ_RECTANGLE, 0, rectStart, fibLevel_382, rectEnd, fibLevel_618);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_FILL, true);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_BACK, true);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_WIDTH, 1);

   // Mark swing high and swing low
   DrawArrow("FGZ_SwingHigh", iTime(_Symbol, _Period, swingHighBar), swingHigh, 218, clrRed);
   DrawArrow("FGZ_SwingLow",  iTime(_Symbol, _Period, swingLowBar),  swingLow,  217, clrDodgerBlue);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Helper: Draw horizontal line                                      |
//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width, string label)
{
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString(0, name, OBJPROP_TEXT, label + " (" + DoubleToString(price, _Digits) + ")");

   // Label
   string lblName = name + "_lbl";
   ObjectCreate(0, lblName, OBJ_TEXT, 0, iTime(_Symbol, _Period, 0), price);
   ObjectSetString(0, lblName, OBJPROP_TEXT, label);
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, lblName, OBJPROP_FONT, "Arial");
}

//+------------------------------------------------------------------+
//| Helper: Draw arrow                                                |
//+------------------------------------------------------------------+
void DrawArrow(string name, datetime time, double price, int code, color clr)
{
   ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| Update chart comment with current state                           |
//+------------------------------------------------------------------+
void UpdateComment()
{
   string trendStr = "NONE";
   if(currentTrend == TREND_UP)   trendStr = "UPTREND (Buy Only)";
   if(currentTrend == TREND_DOWN) trendStr = "DOWNTREND (Sell Only)";

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string zoneStatus = "Outside Golden Zone";

   if(currentTrend == TREND_UP)
   {
      if(currentPrice <= fibLevel_382 && currentPrice >= fibLevel_618)
         zoneStatus = "INSIDE Golden Zone (Watch for Buy)";
      else if(currentPrice > fibLevel_382)
         zoneStatus = "Above Golden Zone";
      else if(currentPrice < fibLevel_618)
         zoneStatus = "Below Golden Zone";
   }
   else if(currentTrend == TREND_DOWN)
   {
      if(currentPrice >= fibLevel_382 && currentPrice <= fibLevel_618)
         zoneStatus = "INSIDE Golden Zone (Watch for Sell)";
      else if(currentPrice < fibLevel_382)
         zoneStatus = "Below Golden Zone";
      else if(currentPrice > fibLevel_618)
         zoneStatus = "Above Golden Zone";
   }

   // MTF status
   string mtfStatus = "";
   if(InpUseMTF)
   {
      int bullCount = 0, bearCount = 0;
      int totalTF = ArraySize(mtfTimeframes);

      for(int t = 0; t < totalTF; t++)
      {
         double tfSwingHigh = 0, tfSwingLow = 0;
         if(!GetTFSwingPoints(mtfTimeframes[t], tfSwingHigh, tfSwingLow))
            continue;

         if(tfSwingHigh <= tfSwingLow) continue;

         double range = tfSwingHigh - tfSwingLow;
         double tfClose = iClose(_Symbol, mtfTimeframes[t], 0);
         double mid = (tfSwingHigh + tfSwingLow) / 2.0;

         if(tfClose > mid) bullCount++;
         else bearCount++;
      }

      mtfStatus = StringFormat("\nMTF: %d Bullish / %d Bearish (need %d to confirm)",
                               bullCount, bearCount, InpMTF_MinAgree);
   }

   Comment(StringFormat(
      "=== Fibonacci Golden Zone EA ===\n"
      "Trend: %s\n"
      "Swing High: %s (bar %d)\n"
      "Swing Low:  %s (bar %d)\n"
      "---\n"
      "Fib 0%%:    %s\n"
      "Fib 23.6%%: %s\n"
      "Fib 38.2%%: %s  <- Golden Zone\n"
      "Fib 50%%:   %s\n"
      "Fib 61.8%%: %s  <- Golden Ratio\n"
      "Fib 78.6%%: %s\n"
      "Fib 100%%:  %s  <- SL Level\n"
      "---\n"
      "Price: %s\n"
      "Zone: %s%s",
      trendStr,
      DoubleToString(swingHigh, _Digits), swingHighBar,
      DoubleToString(swingLow, _Digits), swingLowBar,
      DoubleToString(fibLevel_0, _Digits),
      DoubleToString(fibLevel_236, _Digits),
      DoubleToString(fibLevel_382, _Digits),
      DoubleToString(fibLevel_500, _Digits),
      DoubleToString(fibLevel_618, _Digits),
      DoubleToString(fibLevel_786, _Digits),
      DoubleToString(fibLevel_100, _Digits),
      DoubleToString(currentPrice, _Digits),
      zoneStatus,
      mtfStatus
   ));
}
//+------------------------------------------------------------------+
