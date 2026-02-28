//+------------------------------------------------------------------+
//|                                     FibonacciGoldenZone v2.0.mq5 |
//|                        Fibonacci Golden Zone Trading Strategy     |
//|                        Based on Trading Strategy Guides PDF       |
//+------------------------------------------------------------------+
#property copyright "Fibonacci Golden Zone EA v2.0"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double   InpRiskPercent     = 1.0;     // Risk Per Trade (% of equity)
input double   InpFixedLotSize    = 0.0;     // Fixed Lot Size (0 = use risk %)
input int      InpMagicNumber     = 123456;  // Magic Number
input int      InpMaxSpread       = 30;      // Max Spread (points)
input int      InpSlippage        = 10;      // Slippage (points)

input group "=== Swing Detection ==="
input int      InpSwingStrength   = 5;       // Swing Strength (bars on each side)
input int      InpLookback        = 100;     // Lookback Bars for Swing Detection

input group "=== Fibonacci Settings ==="
input double   InpSLBufferATR     = 0.5;     // SL Buffer Beyond 100% Fib (x ATR)
input double   InpTPBufferATR     = 0.2;     // TP Buffer Beyond Swing (x ATR)

input group "=== Entry Filters ==="
input int      InpRSI_Period      = 14;      // RSI Period
input int      InpRSI_OB          = 65;      // RSI Overbought (sell zone filter)
input int      InpRSI_OS          = 35;      // RSI Oversold (buy zone filter)
input int      InpEMA_Fast        = 50;      // EMA Fast Period
input int      InpEMA_Slow        = 200;     // EMA Slow Period
input bool     InpUseEMAFilter    = true;    // Use EMA Trend Filter
input bool     InpUseRSIFilter    = true;    // Use RSI Confirmation Filter
input bool     InpUseCandleFilter = true;    // Use Candlestick Rejection Filter
input int      InpATR_Period      = 14;      // ATR Period

input group "=== Multi-Timeframe Settings ==="
input int      InpMTF_MinAgree    = 4;       // Min TFs Agreeing for Confirmation
input bool     InpUseMTF          = true;    // Use Multi-Timeframe Filter

input group "=== Trade Management ==="
input bool     InpUseTrailingStop = true;    // Use Trailing Stop
input double   InpTrailStartATR   = 1.5;     // Trail Start (x ATR profit)
input double   InpTrailStepATR    = 0.5;     // Trail Step (x ATR)
input bool     InpUseBreakEven    = true;    // Use Break-Even
input double   InpBE_TriggerATR   = 1.0;     // Break-Even Trigger (x ATR profit)
input double   InpBE_LockPips     = 5;       // Break-Even Lock Profit (points)
input bool     InpOneTradeAtTime  = true;    // Only One Trade at a Time
input bool     InpDrawFibLevels   = true;    // Draw Fibonacci Levels on Chart

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;

// Indicator handles
int            hRSI        = INVALID_HANDLE;
int            hEMA_Fast   = INVALID_HANDLE;
int            hEMA_Slow   = INVALID_HANDLE;
int            hATR        = INVALID_HANDLE;

// Fibonacci level storage
double         fibLevel_0   = 0;
double         fibLevel_236 = 0;
double         fibLevel_382 = 0;
double         fibLevel_500 = 0;
double         fibLevel_618 = 0;
double         fibLevel_786 = 0;
double         fibLevel_100 = 0;

// Swing points
double         swingHigh    = 0;
double         swingLow     = 0;
int            swingHighBar = 0;
int            swingLowBar  = 0;

// Previous swing for TP
double         prevSwingHigh = 0;
double         prevSwingLow  = 0;

// Trend
enum ENUM_TREND { TREND_UP, TREND_DOWN, TREND_NONE };
ENUM_TREND     currentTrend = TREND_NONE;

// Volume constraints
double         volumeMin  = 0;
double         volumeMax  = 0;
double         volumeStep = 0;

// MTF timeframes
ENUM_TIMEFRAMES mtfTimeframes[] = {
   PERIOD_M5, PERIOD_M15, PERIOD_M30,
   PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1
};

// MTF EMA handles (fast/slow per TF)
int            mtfEMAFast[];
int            mtfEMASlow[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Volume constraints
   volumeMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   volumeMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Create indicator handles
   hRSI      = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
   hEMA_Fast = iMA(_Symbol, _Period, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow = iMA(_Symbol, _Period, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hATR      = iATR(_Symbol, _Period, InpATR_Period);

   if(hRSI == INVALID_HANDLE || hEMA_Fast == INVALID_HANDLE ||
      hEMA_Slow == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return(INIT_FAILED);
   }

   // Create MTF EMA handles
   int totalTF = ArraySize(mtfTimeframes);
   ArrayResize(mtfEMAFast, totalTF);
   ArrayResize(mtfEMASlow, totalTF);

   for(int i = 0; i < totalTF; i++)
   {
      mtfEMAFast[i] = iMA(_Symbol, mtfTimeframes[i], InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      mtfEMASlow[i] = iMA(_Symbol, mtfTimeframes[i], InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   }

   Print("Fibonacci Golden Zone EA v2.0 initialized");
   Print("Symbol: ", _Symbol, " | TF: ", EnumToString(_Period),
         " | Risk: ", InpRiskPercent, "%");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if(hRSI != INVALID_HANDLE)      IndicatorRelease(hRSI);
   if(hEMA_Fast != INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
   if(hEMA_Slow != INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
   if(hATR != INVALID_HANDLE)      IndicatorRelease(hATR);

   int totalTF = ArraySize(mtfTimeframes);
   for(int i = 0; i < totalTF; i++)
   {
      if(mtfEMAFast[i] != INVALID_HANDLE) IndicatorRelease(mtfEMAFast[i]);
      if(mtfEMASlow[i] != INVALID_HANDLE) IndicatorRelease(mtfEMASlow[i]);
   }

   ObjectsDeleteAll(0, "FGZ_");
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manage open positions on EVERY tick (trailing stop, break-even)
   ManageOpenPositions();

   // Only process new signals on new bar
   if(!IsNewBar())
      return;

   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
      return;

   // Check if we already have a position
   if(InpOneTradeAtTime && HasOpenPosition())
   {
      // Still update chart display
      if(DetectSwingPoints())
      {
         currentTrend = DetermineTrend();
         CalculateFibLevels();
         if(InpDrawFibLevels) DrawFibonacciLevels();
         UpdateComment();
      }
      return;
   }

   // Step 1: Detect swing highs and swing lows
   if(!DetectSwingPoints())
      return;

   // Step 2: Determine the trend (swing structure + EMA)
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
//| Normalize lot size to symbol constraints                          |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   if(volumeStep > 0)
      lots = MathFloor(lots / volumeStep) * volumeStep;

   if(lots < volumeMin) lots = volumeMin;
   if(lots > volumeMax) lots = volumeMax;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(InpFixedLotSize > 0)
      return NormalizeLotSize(InpFixedLotSize);

   if(slDistance <= 0)
      return NormalizeLotSize(volumeMin);

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount  = equity * InpRiskPercent / 100.0;
   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return NormalizeLotSize(volumeMin);

   double lots = riskAmount / (slDistance / tickSize * tickValue);

   return NormalizeLotSize(lots);
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
//| Get indicator value helper                                        |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift = 1, int buffer = 0)
{
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0)
      return 0;
   return val[0];
}

//+------------------------------------------------------------------+
//| Get ATR value                                                     |
//+------------------------------------------------------------------+
double GetATR(int shift = 1)
{
   return GetIndicatorValue(hATR, shift);
}

//+------------------------------------------------------------------+
//| Detect Swing High and Swing Low points                            |
//| Also finds previous swing points for TP targeting                 |
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

   // Find the two most recent swing highs
   int highCount = 0;
   for(int i = swingStr; i < InpLookback - swingStr; i++)
   {
      if(IsSwingHigh(highs, i, swingStr))
      {
         if(highCount == 0)
         {
            swingHigh = highs[i];
            swingHighBar = i;
         }
         else if(highCount == 1)
         {
            prevSwingHigh = highs[i];
         }
         highCount++;
         if(highCount >= 2) break;
      }
   }

   // Find the two most recent swing lows
   int lowCount = 0;
   for(int i = swingStr; i < InpLookback - swingStr; i++)
   {
      if(IsSwingLow(lows, i, swingStr))
      {
         if(lowCount == 0)
         {
            swingLow = lows[i];
            swingLowBar = i;
         }
         else if(lowCount == 1)
         {
            prevSwingLow = lows[i];
         }
         lowCount++;
         if(lowCount >= 2) break;
      }
   }

   return (highCount >= 1 && lowCount >= 1);
}

//+------------------------------------------------------------------+
//| Check if a bar is a swing high                                    |
//+------------------------------------------------------------------+
bool IsSwingHigh(const double &highs[], int index, int strength)
{
   double centerHigh = highs[index];

   for(int i = 1; i <= strength; i++)
   {
      if(highs[index + i] >= centerHigh)
         return false;
   }

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

   for(int i = 1; i <= strength; i++)
   {
      if(lows[index + i] <= centerLow)
         return false;
   }

   for(int i = 1; i <= strength; i++)
   {
      if(lows[index - i] <= centerLow)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Determine trend direction                                         |
//| Uses swing structure + EMA alignment for robust detection         |
//+------------------------------------------------------------------+
ENUM_TREND DetermineTrend()
{
   // --- Method 1: Swing structure (HH/HL or LL/LH) ---
   int swingStr = InpSwingStrength;
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   CopyHigh(_Symbol, _Period, 0, InpLookback, highs);
   CopyLow(_Symbol, _Period, 0, InpLookback, lows);

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

   ENUM_TREND swingTrend = TREND_NONE;

   if(ArraySize(swHighs) >= 2 && ArraySize(swLows) >= 2)
   {
      bool higherHighs = swHighs[0] > swHighs[1];
      bool higherLows  = swLows[0] > swLows[1];
      bool lowerHighs  = swHighs[0] < swHighs[1];
      bool lowerLows   = swLows[0] < swLows[1];

      if(higherHighs && higherLows) swingTrend = TREND_UP;
      else if(lowerHighs && lowerLows) swingTrend = TREND_DOWN;
      else if(higherHighs || higherLows) swingTrend = TREND_UP;
      else if(lowerHighs || lowerLows) swingTrend = TREND_DOWN;
   }

   // --- Method 2: EMA alignment ---
   ENUM_TREND emaTrend = TREND_NONE;

   if(InpUseEMAFilter)
   {
      double emaFast = GetIndicatorValue(hEMA_Fast, 1);
      double emaSlow = GetIndicatorValue(hEMA_Slow, 1);
      double close1  = iClose(_Symbol, _Period, 1);

      if(emaFast > 0 && emaSlow > 0)
      {
         // Uptrend: price > EMA fast > EMA slow
         if(emaFast > emaSlow && close1 > emaSlow)
            emaTrend = TREND_UP;
         // Downtrend: price < EMA fast < EMA slow
         else if(emaFast < emaSlow && close1 < emaSlow)
            emaTrend = TREND_DOWN;
      }

      // Both must agree when EMA filter is on
      if(swingTrend == emaTrend)
         return swingTrend;

      // If swing says trend but EMA says none, trust swing (EMA is lagging)
      if(swingTrend != TREND_NONE && emaTrend == TREND_NONE)
         return swingTrend;

      // If they disagree, no trade
      if(swingTrend != TREND_NONE && emaTrend != TREND_NONE && swingTrend != emaTrend)
         return TREND_NONE;

      return swingTrend;
   }

   return swingTrend;
}

//+------------------------------------------------------------------+
//| Calculate Fibonacci Retracement Levels                            |
//+------------------------------------------------------------------+
void CalculateFibLevels()
{
   double range = swingHigh - swingLow;
   if(range <= 0) return;

   if(currentTrend == TREND_UP)
   {
      // Uptrend retracement: price pulls back DOWN from swing high
      fibLevel_0   = swingHigh;
      fibLevel_236 = swingHigh - range * 0.236;
      fibLevel_382 = swingHigh - range * 0.382;
      fibLevel_500 = swingHigh - range * 0.500;
      fibLevel_618 = swingHigh - range * 0.618;
      fibLevel_786 = swingHigh - range * 0.786;
      fibLevel_100 = swingLow;
   }
   else if(currentTrend == TREND_DOWN)
   {
      // Downtrend retracement: price pulls back UP from swing low
      fibLevel_0   = swingLow;
      fibLevel_236 = swingLow + range * 0.236;
      fibLevel_382 = swingLow + range * 0.382;
      fibLevel_500 = swingLow + range * 0.500;
      fibLevel_618 = swingLow + range * 0.618;
      fibLevel_786 = swingLow + range * 0.786;
      fibLevel_100 = swingHigh;
   }
}

//+------------------------------------------------------------------+
//| Check for candlestick rejection at golden zone                    |
//| Returns true if bar shows rejection (pin bar, engulfing, etc.)    |
//+------------------------------------------------------------------+
bool IsCandleRejection(int bar, bool isBullish)
{
   double open  = iOpen(_Symbol, _Period, bar);
   double close = iClose(_Symbol, _Period, bar);
   double high  = iHigh(_Symbol, _Period, bar);
   double low   = iLow(_Symbol, _Period, bar);
   double body  = MathAbs(close - open);
   double range = high - low;

   if(range <= 0) return false;

   double bodyRatio = body / range;

   if(isBullish)
   {
      // Bullish rejection: lower wick >= 60% of range, or bullish engulfing
      double lowerWick = MathMin(open, close) - low;
      double upperWick = high - MathMax(open, close);

      // Pin bar: long lower wick, small body, small upper wick
      bool pinBar = (lowerWick / range >= 0.6) && (bodyRatio <= 0.35);

      // Bullish candle with strong close in upper portion
      bool strongBullish = (close > open) && (close > (high + low) / 2.0);

      // Bullish engulfing
      double prevOpen  = iOpen(_Symbol, _Period, bar + 1);
      double prevClose = iClose(_Symbol, _Period, bar + 1);
      bool engulfing = (prevClose < prevOpen) && (close > open) &&
                       (close > prevOpen) && (open < prevClose);

      // Hammer: lower wick at least 2x the body
      bool hammer = (close > open) && (lowerWick >= 2.0 * body) && (upperWick < body);

      return (pinBar || strongBullish || engulfing || hammer);
   }
   else
   {
      // Bearish rejection: upper wick >= 60% of range, or bearish engulfing
      double upperWick = high - MathMax(open, close);
      double lowerWick = MathMin(open, close) - low;

      // Pin bar: long upper wick
      bool pinBar = (upperWick / range >= 0.6) && (bodyRatio <= 0.35);

      // Bearish candle with close in lower portion
      bool strongBearish = (close < open) && (close < (high + low) / 2.0);

      // Bearish engulfing
      double prevOpen  = iOpen(_Symbol, _Period, bar + 1);
      double prevClose = iClose(_Symbol, _Period, bar + 1);
      bool engulfing = (prevClose > prevOpen) && (close < open) &&
                       (close < prevOpen) && (open > prevClose);

      // Shooting star: upper wick at least 2x the body
      bool shootingStar = (close < open) && (upperWick >= 2.0 * body) && (lowerWick < body);

      return (pinBar || strongBearish || engulfing || shootingStar);
   }
}

//+------------------------------------------------------------------+
//| RSI confirmation at the golden zone                               |
//+------------------------------------------------------------------+
bool RSIConfirmation(bool isBuy)
{
   if(!InpUseRSIFilter)
      return true;

   double rsi1 = GetIndicatorValue(hRSI, 1);
   double rsi2 = GetIndicatorValue(hRSI, 2);

   if(rsi1 <= 0) return false;

   if(isBuy)
   {
      // RSI was oversold or is turning up from below midline
      // More lenient: RSI below OB level (not overbought) is enough
      // Better: RSI was near OS and is now rising
      bool wasOversold = (rsi2 <= InpRSI_OS);
      bool isRising    = (rsi1 > rsi2);
      bool notOverbought = (rsi1 < InpRSI_OB);

      return (wasOversold || (isRising && notOverbought));
   }
   else
   {
      // RSI was overbought or is turning down from above midline
      bool wasOverbought = (rsi2 >= InpRSI_OB);
      bool isFalling     = (rsi1 < rsi2);
      bool notOversold   = (rsi1 > InpRSI_OS);

      return (wasOverbought || (isFalling && notOversold));
   }
}

//+------------------------------------------------------------------+
//| Check for trade entry                                             |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);

   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol, _Period, 2);
   double low2   = iLow(_Symbol, _Period, 2);

   double close3 = iClose(_Symbol, _Period, 3);

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atr    = GetATR(1);

   if(atr <= 0) return;

   // Tolerance for testing the 61.8 level (scaled by ATR instead of fixed)
   double fibTolerance = atr * 0.3;

   // ================================================================
   // BUY SIGNAL (Uptrend)
   // ================================================================
   if(currentTrend == TREND_UP)
   {
      // Price must have entered the golden zone
      bool candleInZone = (low1 <= fibLevel_382);

      // Price must have tested near or beyond the 61.8% level
      bool testedGoldenRatio = (low1 <= fibLevel_618 + fibTolerance) ||
                                (low2 <= fibLevel_618 + fibTolerance);

      // Price must close ABOVE the 61.8% level (rejection)
      bool closedAbove618 = (close1 > fibLevel_618);

      // Price must not have broken through the 100% level (trend intact)
      bool trendIntact = (low1 > fibLevel_100 - atr * 0.1);

      if(candleInZone && testedGoldenRatio && closedAbove618 && trendIntact)
      {
         // Candlestick rejection filter
         if(InpUseCandleFilter && !IsCandleRejection(1, true))
            return;

         // RSI confirmation
         if(!RSIConfirmation(true))
            return;

         // Multi-timeframe confirmation
         if(InpUseMTF && !MTFConfirmation(true))
            return;

         // SL: below the 100% fib level (swing low) with ATR buffer
         double sl = fibLevel_100 - atr * InpSLBufferATR;

         // TP: above the previous swing high with ATR buffer
         double tp = fibLevel_0 + atr * InpTPBufferATR;

         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(sl >= ask || tp <= ask) return;

         double slDist = ask - sl;
         double lots = CalculateLotSize(slDist);

         if(trade.Buy(lots, _Symbol, ask, sl, tp, "FGZ Buy v2"))
         {
            Print("BUY: Entry=", ask, " SL=", sl, " TP=", tp,
                  " Lots=", lots, " R:R=", DoubleToString((tp-ask)/slDist, 2));
         }
      }
   }

   // ================================================================
   // SELL SIGNAL (Downtrend)
   // ================================================================
   if(currentTrend == TREND_DOWN)
   {
      // Price must have entered the golden zone
      bool candleInZone = (high1 >= fibLevel_382);

      // Price must have tested near or beyond the 61.8% level
      bool testedGoldenRatio = (high1 >= fibLevel_618 - fibTolerance) ||
                                (high2 >= fibLevel_618 - fibTolerance);

      // Price must close BELOW the 61.8% level (rejection)
      bool closedBelow618 = (close1 < fibLevel_618);

      // Trend must be intact (price hasn't broken the 100% level)
      bool trendIntact = (high1 < fibLevel_100 + atr * 0.1);

      if(candleInZone && testedGoldenRatio && closedBelow618 && trendIntact)
      {
         // Candlestick rejection filter
         if(InpUseCandleFilter && !IsCandleRejection(1, false))
            return;

         // RSI confirmation
         if(!RSIConfirmation(false))
            return;

         // Multi-timeframe confirmation
         if(InpUseMTF && !MTFConfirmation(false))
            return;

         // SL: above the 100% fib level (swing high) with ATR buffer
         double sl = fibLevel_100 + atr * InpSLBufferATR;

         // TP: below the previous swing low with ATR buffer
         double tp = fibLevel_0 - atr * InpTPBufferATR;

         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(sl <= bid || tp >= bid) return;

         double slDist = sl - bid;
         double lots = CalculateLotSize(slDist);

         if(trade.Sell(lots, _Symbol, bid, sl, tp, "FGZ Sell v2"))
         {
            Print("SELL: Entry=", bid, " SL=", sl, " TP=", tp,
                  " Lots=", lots, " R:R=", DoubleToString((bid-tp)/slDist, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Multi-Timeframe Confirmation using EMA trend on each TF           |
//+------------------------------------------------------------------+
bool MTFConfirmation(bool isBuy)
{
   int agreeCount = 0;
   int checkedCount = 0;
   int totalTF = ArraySize(mtfTimeframes);

   for(int t = 0; t < totalTF; t++)
   {
      double emaFast = 0, emaSlow = 0;

      // Use pre-created handles for efficiency
      double valF[], valS[];
      ArraySetAsSeries(valF, true);
      ArraySetAsSeries(valS, true);

      if(CopyBuffer(mtfEMAFast[t], 0, 1, 1, valF) <= 0) continue;
      if(CopyBuffer(mtfEMASlow[t], 0, 1, 1, valS) <= 0) continue;

      emaFast = valF[0];
      emaSlow = valS[0];
      checkedCount++;

      if(isBuy)
      {
         // Bullish: EMA fast above EMA slow
         if(emaFast > emaSlow)
            agreeCount++;
      }
      else
      {
         // Bearish: EMA fast below EMA slow
         if(emaFast < emaSlow)
            agreeCount++;
      }
   }

   int required = MathMin(InpMTF_MinAgree, checkedCount);
   return (agreeCount >= required);
}

//+------------------------------------------------------------------+
//| Manage open positions: trailing stop + break-even                 |
//| Called on EVERY tick for responsive management                     |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atr = GetATR(1);
   if(atr <= 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;

         // Break-even
         if(InpUseBreakEven && currentSL < openPrice)
         {
            if(profit >= atr * InpBE_TriggerATR)
            {
               double newSL = openPrice + InpBE_LockPips * point;
               if(newSL > currentSL)
               {
                  trade.PositionModify(ticket, newSL, currentTP);
               }
            }
         }

         // Trailing stop
         if(InpUseTrailingStop && profit >= atr * InpTrailStartATR)
         {
            double trailSL = bid - atr * InpTrailStepATR;
            if(trailSL > currentSL && trailSL > openPrice)
            {
               trade.PositionModify(ticket, trailSL, currentTP);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;

         // Break-even
         if(InpUseBreakEven && currentSL > openPrice)
         {
            if(profit >= atr * InpBE_TriggerATR)
            {
               double newSL = openPrice - InpBE_LockPips * point;
               if(newSL < currentSL)
               {
                  trade.PositionModify(ticket, newSL, currentTP);
               }
            }
         }

         // Trailing stop
         if(InpUseTrailingStop && profit >= atr * InpTrailStartATR)
         {
            double trailSL = ask + atr * InpTrailStepATR;
            if(trailSL < currentSL && trailSL < openPrice)
            {
               trade.PositionModify(ticket, trailSL, currentTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Draw Fibonacci levels on the chart                                |
//+------------------------------------------------------------------+
void DrawFibonacciLevels()
{
   ObjectsDeleteAll(0, "FGZ_");

   datetime timeEnd = iTime(_Symbol, _Period, 0);

   DrawHLine("FGZ_Fib_0",     fibLevel_0,   clrGray,       STYLE_DOT,   1, "0%");
   DrawHLine("FGZ_Fib_236",   fibLevel_236, clrDarkGray,   STYLE_DOT,   1, "23.6%");
   DrawHLine("FGZ_Fib_382",   fibLevel_382, clrGold,       STYLE_SOLID, 2, "38.2%");
   DrawHLine("FGZ_Fib_500",   fibLevel_500, clrOrange,     STYLE_DASH,  1, "50%");
   DrawHLine("FGZ_Fib_618",   fibLevel_618, clrRed,        STYLE_SOLID, 2, "61.8%");
   DrawHLine("FGZ_Fib_786",   fibLevel_786, clrDarkGray,   STYLE_DOT,   1, "78.6%");
   DrawHLine("FGZ_Fib_100",   fibLevel_100, clrGray,       STYLE_DOT,   1, "100%");

   // Golden zone rectangle
   datetime rectStart = iTime(_Symbol, _Period, InpLookback / 2);
   datetime rectEnd   = timeEnd + PeriodSeconds(_Period) * 20;

   ObjectCreate(0, "FGZ_GoldenZone", OBJ_RECTANGLE, 0, rectStart, fibLevel_382, rectEnd, fibLevel_618);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_FILL, true);
   ObjectSetInteger(0, "FGZ_GoldenZone", OBJPROP_BACK, true);

   // Mark swing points
   DrawArrow("FGZ_SwingHigh", iTime(_Symbol, _Period, swingHighBar), swingHigh, 218, clrRed);
   DrawArrow("FGZ_SwingLow",  iTime(_Symbol, _Period, swingLowBar),  swingLow,  217, clrDodgerBlue);

   // Mark EMA lines
   if(InpUseEMAFilter)
   {
      double emaF = GetIndicatorValue(hEMA_Fast, 0);
      double emaS = GetIndicatorValue(hEMA_Slow, 0);
      string trendLabel = (emaF > emaS) ? "EMA: BULLISH" : (emaF < emaS) ? "EMA: BEARISH" : "EMA: FLAT";

      ObjectCreate(0, "FGZ_EMALabel", OBJ_LABEL, 0, 0, 0);
      ObjectSetString(0, "FGZ_EMALabel", OBJPROP_TEXT, trendLabel);
      ObjectSetInteger(0, "FGZ_EMALabel", OBJPROP_COLOR, (emaF > emaS) ? clrLimeGreen : clrOrangeRed);
      ObjectSetInteger(0, "FGZ_EMALabel", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, "FGZ_EMALabel", OBJPROP_XDISTANCE, 15);
      ObjectSetInteger(0, "FGZ_EMALabel", OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, "FGZ_EMALabel", OBJPROP_FONTSIZE, 10);
   }

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
//| Update chart comment                                              |
//+------------------------------------------------------------------+
void UpdateComment()
{
   string trendStr = "NONE";
   if(currentTrend == TREND_UP)   trendStr = "UPTREND";
   if(currentTrend == TREND_DOWN) trendStr = "DOWNTREND";

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetATR(1);
   double rsi = GetIndicatorValue(hRSI, 1);
   double emaF = GetIndicatorValue(hEMA_Fast, 1);
   double emaS = GetIndicatorValue(hEMA_Slow, 1);

   string zoneStatus = "Outside";
   if(currentTrend == TREND_UP)
   {
      if(bid <= fibLevel_382 && bid >= fibLevel_618) zoneStatus = "IN GOLDEN ZONE";
      else if(bid > fibLevel_382) zoneStatus = "Above Zone";
      else if(bid < fibLevel_618) zoneStatus = "Below Zone";
   }
   else if(currentTrend == TREND_DOWN)
   {
      if(bid >= fibLevel_382 && bid <= fibLevel_618) zoneStatus = "IN GOLDEN ZONE";
      else if(bid < fibLevel_382) zoneStatus = "Below Zone";
      else if(bid > fibLevel_618) zoneStatus = "Above Zone";
   }

   // MTF status
   int bullCount = 0, bearCount = 0;
   int totalTF = ArraySize(mtfTimeframes);
   for(int t = 0; t < totalTF; t++)
   {
      double valF[], valS[];
      ArraySetAsSeries(valF, true);
      ArraySetAsSeries(valS, true);
      if(CopyBuffer(mtfEMAFast[t], 0, 1, 1, valF) <= 0) continue;
      if(CopyBuffer(mtfEMASlow[t], 0, 1, 1, valS) <= 0) continue;
      if(valF[0] > valS[0]) bullCount++;
      else bearCount++;
   }

   string posInfo = "None";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double pnl = PositionGetDouble(POSITION_PROFIT);
         double openP = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         string type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         posInfo = StringFormat("%s @ %s | SL: %s | TP: %s | PnL: %.2f",
                     type, DoubleToString(openP, _Digits),
                     DoubleToString(sl, _Digits),
                     DoubleToString(tp, _Digits), pnl);
         break;
      }
   }

   Comment(StringFormat(
      "=== Fibonacci Golden Zone v2.0 ===\n"
      "Trend: %s | EMA: %s %s %s\n"
      "RSI: %.1f | ATR: %s\n"
      "---\n"
      "38.2%%: %s | 50%%: %s | 61.8%%: %s\n"
      "SL Level (100%%): %s\n"
      "Zone: %s\n"
      "MTF: %d Bull / %d Bear (need %d)\n"
      "---\n"
      "Position: %s",
      trendStr,
      DoubleToString(emaF, _Digits),
      (emaF > emaS) ? ">" : "<",
      DoubleToString(emaS, _Digits),
      rsi, DoubleToString(atr, _Digits),
      DoubleToString(fibLevel_382, _Digits),
      DoubleToString(fibLevel_500, _Digits),
      DoubleToString(fibLevel_618, _Digits),
      DoubleToString(fibLevel_100, _Digits),
      zoneStatus,
      bullCount, bearCount, InpMTF_MinAgree,
      posInfo
   ));
}
//+------------------------------------------------------------------+
