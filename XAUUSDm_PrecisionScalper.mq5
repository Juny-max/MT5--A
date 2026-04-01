//+------------------------------------------------------------------+
//|                   XAUUSDm_PrecisionScalper.mq5                   |
//|          Elite Quantitative Precision Scalping EA for Gold        |
//|          Optimized for Exness Standard Account | $110 Principal   |
//|                                                                    |
//|  ARCHITECTURE MODULES:                                             |
//|    1. Capital Preservation & Harvest-Halt Protocol                 |
//|    2. Macro-Trend Shield         (M15 Timeframe)                   |
//|    3. Micro-Burst Execution Spear(M1  Timeframe)                   |
//|    4. Dynamic Trailing Exit Matrix                                 |
//|    5. Smart News Integration     (MT5 Economic Calendar API)       |
//+------------------------------------------------------------------+
#property copyright "Precision Scalper v1.0"
#property version   "1.00"
#property strict

//--- Standard MQL5 libraries
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

//--- Capital & Risk Management
input group "=== CAPITAL MANAGEMENT ==="
input double   InpLotSize          = 0.01;    // Fixed lot size (min 0.01 for micro balance)
input double   InpHardFloorEquity  = 55.00;   // Absolute equity floor ($) — NEVER trade below
input double   InpInitialBalance   = 110.00;  // Initial account principal ($)

//--- Harvest Targets (Fractional Step-Up)
input group "=== HARVEST & HALT TARGETS ==="
input double   InpHarvestTarget1   = 165.00;  // Harvest Step 1: Equity target ($)
input double   InpHarvestTarget2   = 210.00;  // Harvest Step 2: Equity target ($)
input double   InpHarvestTarget3   = 262.50;  // Harvest Step 3: Equity target ($)

//--- Spread & Slippage Guards
input group "=== SPREAD & EXECUTION GUARDS ==="
input int      InpMaxSpreadPoints  = 350;     // Max spread in points (350 = 35 pips on 5-digit)
input int      InpMaxSlippage      = 30;      // Max slippage in points

//--- M15 Macro-Trend Shield EMAs
input group "=== M15 MACRO-TREND SHIELD ==="
input int      InpEMA200Period     = 200;     // EMA 200 period
input int      InpEMA60Period      = 60;      // EMA 60 period
input int      InpEMA30Period      = 30;      // EMA 30 period

//--- M1 Bollinger Band Settings
input group "=== M1 BOLLINGER BANDS ==="
input int      InpFastBBPeriod     = 20;      // Fast BB period
input double   InpFastBBDeviation  = 2.0;     // Fast BB standard deviation
input int      InpSlowBBPeriod     = 100;     // Slow BB period
input double   InpSlowBBDeviation  = 2.0;     // Slow BB standard deviation

//--- M1 MACD Settings
input group "=== M1 MACD ==="
input int      InpMACDFast         = 12;      // MACD fast EMA period
input int      InpMACDSlow         = 26;      // MACD slow EMA period
input int      InpMACDSignal       = 9;       // MACD signal period

//--- Trailing Exit Matrix
input group "=== DYNAMIC TRAILING EXIT MATRIX ==="
input double   InpBreakevenPips    = 150.0;   // Pips profit to trigger breakeven move
input double   InpBreakevenBuffer  = 15.0;    // Pips buffer above entry at breakeven
input double   InpTrailStepPips    = 50.0;    // Trailing step size in pips
input double   InpMaxSLPips        = 240.0;   // Hard cap on maximum initial stop loss (pips)

//--- News Integration
input group "=== NEWS & ECONOMIC CALENDAR ==="
input bool     InpEnableNewsFilter = true;    // Enable news blackout filter
input int      InpNewsPreMinutes   = 15;      // Minutes to pause BEFORE news
input int      InpNewsPostMinutes  = 15;      // Minutes to resume AFTER news
input int      InpStraddleMinutes  = 2;       // Minutes before news for straddle placement
input int      InpStraddleExpiry   = 5;       // Minutes after news to cancel untriggered straddle
input double   InpStraddlePips     = 150.0;   // Straddle distance from current price in pips

//--- Trade Identification
input group "=== EA IDENTITY ==="
input int      InpMagicNumber      = 202401;  // Unique Magic Number

//+------------------------------------------------------------------+
//|  GLOBAL VARIABLES & HANDLES                                        |
//+------------------------------------------------------------------+

//--- Trade execution objects
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

//--- M15 EMA Indicator Handles
int handleEMA200_M15 = INVALID_HANDLE;
int handleEMA60_M15  = INVALID_HANDLE;
int handleEMA30_M15  = INVALID_HANDLE;

//--- M1 Bollinger Band Handles
int handleFastBB_M1  = INVALID_HANDLE;
int handleSlowBB_M1  = INVALID_HANDLE;

//--- M1 MACD Handle
int handleMACD_M1    = INVALID_HANDLE;

//--- EA State Flags
bool g_TradingLocked      = false;   // Set true by Harvest-Halt or Hard Floor trigger
bool g_EmergencyShutdown  = false;   // Set true by Hard Floor — permanent halt
bool g_HarvestLevel1Hit   = false;   // Prevents re-triggering Harvest Step 1
bool g_HarvestLevel2Hit   = false;   // Prevents re-triggering Harvest Step 2
bool g_HarvestLevel3Hit   = false;   // Prevents re-triggering Harvest Step 3

//--- News & Straddle State
datetime g_LastNewsEventTime    = 0; // Timestamp of the nearest upcoming/recent news event
bool     g_StraddlePlaced       = false; // True if straddle pending orders are live
ulong    g_StraddleBuyTicket    = 0;    // Ticket for straddle BUY STOP order
ulong    g_StraddleSellTicket   = 0;    // Ticket for straddle SELL STOP order
datetime g_StraddlePlacedAt     = 0;    // When straddle was placed (for expiry logic)
datetime g_NewsEventTimestamp   = 0;    // Exact timestamp of upcoming high-impact event

//--- Point & Pip conversion factor
//    XAUUSDm on Exness: 5-digit pricing → 1 pip = 10 points
double g_PointSize  = 0.0;  // Populated in OnInit()
double g_PipSize    = 0.0;  // = 10 * _Point (1 pip in price)

//--- Minimum stops level (dynamic, from broker)
int    g_MinStopsLevel = 0; // Populated in OnInit() from SYMBOL_TRADE_STOPS_LEVEL

//+------------------------------------------------------------------+
//|  INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Set EA identity on trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippage);

//--- CRITICAL: Set Exness IOC filling mode (avoids "invalid fill" rejections)
   trade.SetTypeFilling(ORDER_FILLING_IOC);

//--- Cache point/pip sizes
   g_PointSize = _Point;
   g_PipSize   = 10.0 * _Point;  // 1 pip = 10 points on a 5-digit broker

//--- Read broker's minimum stops distance (dynamic — changes with volatility)
   g_MinStopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   PrintFormat("[INIT] MinStopsLevel = %d points | PipSize = %.5f", g_MinStopsLevel, g_PipSize);

//--- ── M15 EMA Handles ──────────────────────────────────────────────
   handleEMA200_M15 = iMA(_Symbol, PERIOD_M15, InpEMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA60_M15  = iMA(_Symbol, PERIOD_M15, InpEMA60Period,  0, MODE_EMA, PRICE_CLOSE);
   handleEMA30_M15  = iMA(_Symbol, PERIOD_M15, InpEMA30Period,  0, MODE_EMA, PRICE_CLOSE);

   if(handleEMA200_M15 == INVALID_HANDLE ||
      handleEMA60_M15  == INVALID_HANDLE ||
      handleEMA30_M15  == INVALID_HANDLE)
     {
      Print("[INIT ERROR] Failed to create M15 EMA handles. EA aborted.");
      return INIT_FAILED;
     }

//--- ── M1 Bollinger Band Handles ───────────────────────────────────
   handleFastBB_M1 = iBands(_Symbol, PERIOD_M1, InpFastBBPeriod, 0, InpFastBBDeviation, PRICE_CLOSE);
   handleSlowBB_M1 = iBands(_Symbol, PERIOD_M1, InpSlowBBPeriod, 0, InpSlowBBDeviation, PRICE_CLOSE);

   if(handleFastBB_M1 == INVALID_HANDLE || handleSlowBB_M1 == INVALID_HANDLE)
     {
      Print("[INIT ERROR] Failed to create M1 Bollinger Band handles. EA aborted.");
      return INIT_FAILED;
     }

//--- ── M1 MACD Handle ──────────────────────────────────────────────
   handleMACD_M1 = iMACD(_Symbol, PERIOD_M1, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);

   if(handleMACD_M1 == INVALID_HANDLE)
     {
      Print("[INIT ERROR] Failed to create M1 MACD handle. EA aborted.");
      return INIT_FAILED;
     }

   Print("[INIT] XAUUSDm Precision Scalper initialized successfully.");
   Print("[INIT] Hard Floor: $", InpHardFloorEquity, " | Lot Size: ", InpLotSize);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Release all indicator handles to free memory
   if(handleEMA200_M15 != INVALID_HANDLE) IndicatorRelease(handleEMA200_M15);
   if(handleEMA60_M15  != INVALID_HANDLE) IndicatorRelease(handleEMA60_M15);
   if(handleEMA30_M15  != INVALID_HANDLE) IndicatorRelease(handleEMA30_M15);
   if(handleFastBB_M1  != INVALID_HANDLE) IndicatorRelease(handleFastBB_M1);
   if(handleSlowBB_M1  != INVALID_HANDLE) IndicatorRelease(handleSlowBB_M1);
   if(handleMACD_M1    != INVALID_HANDLE) IndicatorRelease(handleMACD_M1);
   PrintFormat("[DEINIT] EA removed. Reason code: %d", reason);
  }

//+------------------------------------------------------------------+
//|  MAIN TICK HANDLER                                                 |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_EmergencyShutdown)
     {
      Comment("EMERGENCY SHUTDOWN ACTIVE. Hard floor breached; restart manually.");
      return;
     }

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   long   currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   //--- Absolute hard floor: close all exposure and permanently halt this session.
   if(currentEquity <= InpHardFloorEquity)
     {
      PrintFormat("[HARD FLOOR] Equity %.2f <= Floor %.2f. Emergency flatten + halt.",
                  currentEquity, InpHardFloorEquity);
      SendNotification(StringFormat("HARD FLOOR HIT: Equity $%.2f. Positions closed, EA halted.", currentEquity));
      CloseAllPositions();
      CancelAllPendingOrders();
      g_EmergencyShutdown = true;
      g_TradingLocked     = true;
      Comment("EMERGENCY SHUTDOWN: Hard floor breached.");
      return;
     }

   //--- Fractional harvest ladder: lock new entries at each milestone.
   CheckHarvestTargets(currentEquity);

   //--- Always manage open trades even if entries are blocked.
   ManagePosition();

   if(g_TradingLocked)
     {
      Comment(StringFormat("TRADING LOCKED (Harvest). Equity: $%.2f", currentEquity));
      UpdateChartComment(currentEquity, currentSpread);
      return;
     }

   if(currentSpread > InpMaxSpreadPoints)
     {
      Comment(StringFormat("SPREAD TOO HIGH: %d pts (max %d)", currentSpread, InpMaxSpreadPoints));
      UpdateChartComment(currentEquity, currentSpread);
      return;
     }

   //--- Pause entries around high-impact USD news and manage pre-news straddle.
   if(IsNewsEvent())
     {
      Comment(StringFormat("NEWS BLACKOUT ACTIVE | Equity: $%.2f | Spread: %d pts",
                           currentEquity, currentSpread));
      UpdateChartComment(currentEquity, currentSpread);
      return;
     }

   //--- Entry logic only when fully flat and no pending straddle basket.
   if(CountOpenPositions() == 0 && !g_StraddlePlaced)
     {
      int entrySignal = CheckForEntry(); // +1 buy, -1 sell, 0 no trade
      if(entrySignal == 1)
         ExecuteBuy();
      else if(entrySignal == -1)
         ExecuteSell();
     }

   UpdateChartComment(currentEquity, currentSpread);
  }

//+------------------------------------------------------------------+
//|  MISSING EXECUTION LOGIC: CHECKFORENTRY                           |
//|  Returns +1 Buy, -1 Sell, 0 No Signal                             |
//+------------------------------------------------------------------+
int CheckForEntry()
  {
//--- Macro-trend shield (M15): dynamic arrays only
   double ema200[];
   double ema60[];
   double ema30[];
   double m15Close[];

   ArraySetAsSeries(ema200,   true);
   ArraySetAsSeries(ema60,    true);
   ArraySetAsSeries(ema30,    true);
   ArraySetAsSeries(m15Close, true);

   if(CopyBuffer(handleEMA200_M15, 0, 0, 3, ema200) < 3) return 0;
   if(CopyBuffer(handleEMA60_M15,  0, 0, 3, ema60)  < 3) return 0;
   if(CopyBuffer(handleEMA30_M15,  0, 0, 3, ema30)  < 3) return 0;
   if(CopyClose(_Symbol, PERIOD_M15, 1, 1, m15Close) < 1) return 0;

   int macroBias = 0;
   if(m15Close[0] > ema200[1] && ema30[1] > ema60[1])
      macroBias = 1;
   else if(m15Close[0] < ema200[1] && ema30[1] < ema60[1])
      macroBias = -1;
   else
      return 0;

//--- Micro-burst spear (M1): FastBB vs SlowBB + MACD cross in regime
   double fastUpper[];
   double fastLower[];
   double slowUpper[];
   double slowLower[];
   double macdMain[];
   double macdSignal[];

   ArraySetAsSeries(fastUpper,  true);
   ArraySetAsSeries(fastLower,  true);
   ArraySetAsSeries(slowUpper,  true);
   ArraySetAsSeries(slowLower,  true);
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);

   if(CopyBuffer(handleFastBB_M1, 1, 0, 3, fastUpper)  < 3) return 0;
   if(CopyBuffer(handleFastBB_M1, 2, 0, 3, fastLower)  < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 1, 0, 3, slowUpper)  < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 2, 0, 3, slowLower)  < 3) return 0;
   if(CopyBuffer(handleMACD_M1,   0, 0, 3, macdMain)   < 3) return 0;
   if(CopyBuffer(handleMACD_M1,   1, 0, 3, macdSignal) < 3) return 0;

   bool fastBelowSlow = (fastLower[1] < slowLower[1]) && (fastLower[2] >= slowLower[2]);
   bool fastAboveSlow = (fastUpper[1] > slowUpper[1]) && (fastUpper[2] <= slowUpper[2]);

   bool macdBullCrossOversold = (macdMain[1] > macdSignal[1]) &&
                                (macdMain[2] <= macdSignal[2]) &&
                                (macdMain[1] < 0.0) &&
                                (macdSignal[1] < 0.0);

   bool macdBearCrossOverbought = (macdMain[1] < macdSignal[1]) &&
                                  (macdMain[2] >= macdSignal[2]) &&
                                  (macdMain[1] > 0.0) &&
                                  (macdSignal[1] > 0.0);

   if(macroBias == 1 && fastBelowSlow && macdBullCrossOversold)
      return 1;

   if(macroBias == -1 && fastAboveSlow && macdBearCrossOverbought)
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//|  ORDERSEND HELPER: MODIFY POSITION SL/TP                          |
//+------------------------------------------------------------------+
bool ModifyPositionSLByOrderSend(ulong ticket, double newSL, double currentTP)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.magic    = InpMagicNumber;
   req.position = ticket;
   req.sl       = NormalizeDouble(newSL, _Digits);
   req.tp       = currentTP;

   if(!OrderSend(req, res))
     {
      PrintFormat("[SL MODIFY ERROR] Ticket %I64u send failed. LastError=%d", ticket, GetLastError());
      return false;
     }

   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      PrintFormat("[SL MODIFY ERROR] Ticket %I64u retcode=%d | %s",
                  ticket, res.retcode, res.comment);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//|  ORDERSEND HELPER: CLOSE POSITION BY MARKET DEAL                  |
//+------------------------------------------------------------------+
bool ClosePositionByOrderSend(ulong ticket, ENUM_POSITION_TYPE posType, double volume)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = InpMagicNumber;
   req.position     = ticket;
   req.volume       = volume;
   req.deviation    = InpMaxSlippage;
   req.type_filling = ORDER_FILLING_IOC;

   if(posType == POSITION_TYPE_BUY)
     {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
     }
   else
     {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
     }

   if(!OrderSend(req, res))
     {
      PrintFormat("[CLOSE ERROR] Ticket %I64u send failed. LastError=%d", ticket, GetLastError());
      return false;
     }

   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      PrintFormat("[CLOSE ERROR] Ticket %I64u retcode=%d | %s",
                  ticket, res.retcode, res.comment);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//|  ORDERSEND HELPER: CANCEL PENDING ORDER                           |
//+------------------------------------------------------------------+
bool CancelPendingByTicket(ulong orderTicket)
  {
   if(orderTicket == 0)
      return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_REMOVE;
   req.order  = orderTicket;
   req.symbol = _Symbol;
   req.magic  = InpMagicNumber;

   if(!OrderSend(req, res))
      return false;

   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
//|  NEWS STRADDLE: NETLESS TWO-LEG PLACEMENT                         |
//+------------------------------------------------------------------+
void PlaceNetlessStraddle(datetime eventTime)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   double midPrice     = (ask + bid) / 2.0;
   double straddleDist = InpStraddlePips * g_PipSize;

   double buyStopPrice  = NormalizeDouble(midPrice + straddleDist, _Digits);
   double sellStopPrice = NormalizeDouble(midPrice - straddleDist, _Digits);

   double minDist = (g_MinStopsLevel + 10) * g_PointSize;
   if((buyStopPrice - ask) < minDist)
      buyStopPrice = NormalizeDouble(ask + minDist, _Digits);
   if((bid - sellStopPrice) < minDist)
      sellStopPrice = NormalizeDouble(bid - minDist, _Digits);

   datetime expiry = eventTime + InpStraddleExpiry * 60;
   double lot      = CalculateLotSize();

   MqlTradeRequest reqBuy;
   MqlTradeRequest reqSell;
   MqlTradeResult  resBuy;
   MqlTradeResult  resSell;
   ZeroMemory(reqBuy);
   ZeroMemory(reqSell);
   ZeroMemory(resBuy);
   ZeroMemory(resSell);

   reqBuy.action       = TRADE_ACTION_PENDING;
   reqBuy.symbol       = _Symbol;
   reqBuy.magic        = InpMagicNumber;
   reqBuy.volume       = lot;
   reqBuy.type         = ORDER_TYPE_BUY_STOP;
   reqBuy.price        = buyStopPrice;
   reqBuy.sl           = NormalizeDouble(buyStopPrice - InpMaxSLPips * g_PipSize, _Digits);
   reqBuy.tp           = 0.0;
   reqBuy.deviation    = InpMaxSlippage;
   reqBuy.type_filling = ORDER_FILLING_RETURN;
   reqBuy.type_time    = ORDER_TIME_SPECIFIED;
   reqBuy.expiration   = expiry;
   reqBuy.comment      = "NewsStraddleBuy";

   reqSell.action       = TRADE_ACTION_PENDING;
   reqSell.symbol       = _Symbol;
   reqSell.magic        = InpMagicNumber;
   reqSell.volume       = lot;
   reqSell.type         = ORDER_TYPE_SELL_STOP;
   reqSell.price        = sellStopPrice;
   reqSell.sl           = NormalizeDouble(sellStopPrice + InpMaxSLPips * g_PipSize, _Digits);
   reqSell.tp           = 0.0;
   reqSell.deviation    = InpMaxSlippage;
   reqSell.type_filling = ORDER_FILLING_RETURN;
   reqSell.type_time    = ORDER_TIME_SPECIFIED;
   reqSell.expiration   = expiry;
   reqSell.comment      = "NewsStraddleSell";

   bool buyPlaced  = OrderSend(reqBuy,  resBuy)  &&
                     (resBuy.retcode == TRADE_RETCODE_DONE || resBuy.retcode == TRADE_RETCODE_PLACED);
   bool sellPlaced = OrderSend(reqSell, resSell) &&
                     (resSell.retcode == TRADE_RETCODE_DONE || resSell.retcode == TRADE_RETCODE_PLACED);

   ulong buyTicket  = buyPlaced  ? resBuy.order  : 0;
   ulong sellTicket = sellPlaced ? resSell.order : 0;

//--- Netless requirement: if both legs are not live, cancel any partial leg immediately.
   if(!(buyPlaced && sellPlaced))
     {
      if(buyTicket  > 0) CancelPendingByTicket(buyTicket);
      if(sellTicket > 0) CancelPendingByTicket(sellTicket);

      g_StraddleBuyTicket  = 0;
      g_StraddleSellTicket = 0;
      g_StraddlePlaced     = false;

      PrintFormat("[STRADDLE ERROR] Netless rule rollback. Buy ret=%d | Sell ret=%d",
                  resBuy.retcode, resSell.retcode);
      return;
     }

   g_StraddleBuyTicket   = buyTicket;
   g_StraddleSellTicket  = sellTicket;
   g_StraddlePlaced      = true;
   g_StraddlePlacedAt    = TimeCurrent();
   g_NewsEventTimestamp  = eventTime;

   PrintFormat("[STRADDLE] Netless pair placed. Buy=%I64u | Sell=%I64u | Event=%s",
               g_StraddleBuyTicket, g_StraddleSellTicket, TimeToString(eventTime));
  }

//+------------------------------------------------------------------+
//|  MISSING EXECUTION LOGIC: MANAGEPOSITION                          |
//|  Breakeven + step trailing + MACD adverse zero-line exit          |
//+------------------------------------------------------------------+
void ManagePosition()
  {
//--- Dynamic MACD buffers (required to avoid static-array warnings)
   double macdMain[];
   double macdSignal[];
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);

   bool macdDataOK = (CopyBuffer(handleMACD_M1, 0, 0, 3, macdMain)   >= 3 &&
                      CopyBuffer(handleMACD_M1, 1, 0, 3, macdSignal) >= 3);

   int totalPositions = PositionsTotal();
   for(int i = totalPositions - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0)
         continue;

      double profitPips = 0.0;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (bid - openPrice) / g_PipSize;
      else
         profitPips = (openPrice - ask) / g_PipSize;

//--- Emergency exit when MACD fully crosses zero against the open direction.
      if(macdDataOK)
        {
         bool crossedBelowZero = (macdMain[1] < 0.0) && (macdMain[2] >= 0.0);
         bool crossedAboveZero = (macdMain[1] > 0.0) && (macdMain[2] <= 0.0);

         bool againstPosition = false;
         if(posType == POSITION_TYPE_BUY  && crossedBelowZero) againstPosition = true;
         if(posType == POSITION_TYPE_SELL && crossedAboveZero) againstPosition = true;

         if(againstPosition && profitPips > 0.0)
           {
            if(ClosePositionByOrderSend(ticket, posType, volume))
               PrintFormat("[MACD ZERO EXIT] Ticket %I64u closed at %.1f pips.", ticket, profitPips);
            continue;
           }
        }

//--- Breakeven trigger at 150 pips, then trail in 50-pip increments.
      if(profitPips < InpBreakevenPips)
         continue;

      double protectedPips = InpBreakevenBuffer;
      double extraPips = profitPips - InpBreakevenPips;
      if(extraPips > 0.0)
        {
         int steps = (int)MathFloor(extraPips / InpTrailStepPips);
         protectedPips += steps * InpTrailStepPips;
        }

      double newSL = 0.0;
      if(posType == POSITION_TYPE_BUY)
         newSL = openPrice + protectedPips * g_PipSize;
      else
         newSL = openPrice - protectedPips * g_PipSize;

      double minDist = (g_MinStopsLevel + 5) * g_PointSize;
      if(posType == POSITION_TYPE_BUY && (bid - newSL) < minDist)
         newSL = bid - minDist;
      if(posType == POSITION_TYPE_SELL && (newSL - ask) < minDist)
         newSL = ask + minDist;

      newSL = NormalizeDouble(newSL, _Digits);

      bool shouldModify = false;
      if(posType == POSITION_TYPE_BUY)
         shouldModify = (currentSL == 0.0 || newSL > currentSL + g_PointSize);
      else
         shouldModify = (currentSL == 0.0 || newSL < currentSL - g_PointSize);

      if(shouldModify)
        {
         if(ModifyPositionSLByOrderSend(ticket, newSL, currentTP))
            PrintFormat("[TRAIL] Ticket %I64u | SL -> %.5f | Profit=%.1f pips", ticket, newSL, profitPips);
        }
     }
  }

//+------------------------------------------------------------------+
//|  MISSING EXECUTION LOGIC: ISNEWSEVENT                             |
//|  High-impact USD filter with pre-news netless straddle            |
//+------------------------------------------------------------------+
bool IsNewsEvent()
  {
   if(!InpEnableNewsFilter)
      return false;

   datetime now       = TimeCurrent();
   datetime scanStart = now - (InpNewsPostMinutes + 1) * 60;
   datetime scanEnd   = now + (InpNewsPreMinutes  + 1) * 60;

   bool     newsBlackout       = false;
   datetime nearestEventForStr = 0;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, scanStart, scanEnd, "USD");
   if(count > 0)
     {
      for(int i = 0; i < count; i++)
        {
         MqlCalendarEvent eventInfo;
         if(!CalendarEventById(values[i].event_id, eventInfo))
            continue;
         if(eventInfo.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;

         datetime eventTime = values[i].time;
         long secToEvent    = (long)(eventTime - now);
         long secAfterNews  = (long)(now - eventTime);

         if((secToEvent > 0 && secToEvent <= InpNewsPreMinutes * 60) ||
            (secAfterNews >= 0 && secAfterNews <= InpNewsPostMinutes * 60))
           {
            newsBlackout = true;
            g_LastNewsEventTime = eventTime;
           }

         if(secToEvent > 0 && secToEvent <= InpStraddleMinutes * 60)
           {
            if(nearestEventForStr == 0 || secToEvent < (long)(nearestEventForStr - now))
               nearestEventForStr = eventTime;
           }
        }
     }

//--- Keep straddle lifecycle active even when no new event is found in scan.
   if(g_StraddlePlaced)
      ManageStraddleExpiry();

//--- Netless pre-news straddle only when account is flat.
   if(nearestEventForStr > 0 && !g_StraddlePlaced && CountOpenPositions() == 0)
      PlaceNetlessStraddle(nearestEventForStr);

   return newsBlackout;
  }

//+------------------------------------------------------------------+
//|  MISSING EXECUTION LOGIC: CALCULATELOTSIZE                        |
//|  Hardcoded lot control to protect the $110 principal              |
//+------------------------------------------------------------------+
double CalculateLotSize()
  {
   return 0.01;
  }

//+------------------------------------------------------------------+
//|  MODULE 1B: CHECK HARVEST TARGETS                                  |
//|  Sends push notification and locks trading at each equity step     |
//+------------------------------------------------------------------+
void CheckHarvestTargets(double equity)
  {
//--- Step 1: $165 target
   if(!g_HarvestLevel1Hit && equity >= InpHarvestTarget1)
     {
      g_HarvestLevel1Hit = true;
      g_TradingLocked    = true;
      string msg = StringFormat(
                     "💰 TARGET 1 REACHED: Equity $%.2f. Withdraw $25. Leave $140. Restart Bot.",
                     equity);
      Print("[HARVEST-1] " + msg);
      SendNotification("TARGET 1 REACHED: Equity $165. Withdraw $25. Leave $140. Restart Bot.");
     }

//--- Step 2: $210 target
   if(!g_HarvestLevel2Hit && equity >= InpHarvestTarget2)
     {
      g_HarvestLevel2Hit = true;
      g_TradingLocked    = true;
      string msg = StringFormat(
                     "💰 TARGET 2 REACHED: Equity $%.2f. Withdraw $35. Leave $175. Restart Bot.",
                     equity);
      Print("[HARVEST-2] " + msg);
      SendNotification("TARGET 2 REACHED: Equity $210. Withdraw $35. Leave $175. Restart Bot.");
     }

//--- Step 3: $262.50 target
   if(!g_HarvestLevel3Hit && equity >= InpHarvestTarget3)
     {
      g_HarvestLevel3Hit = true;
      g_TradingLocked    = true;
      string msg = StringFormat(
                     "💰 TARGET 3 REACHED: Equity $%.2f. Withdraw $45. Leave $217. Restart Bot.",
                     equity);
      Print("[HARVEST-3] " + msg);
      SendNotification("TARGET 3 REACHED: Equity $262. Withdraw $45. Leave $217. Restart Bot.");
     }
  }

//+------------------------------------------------------------------+
//|  MODULE 2: MACRO-TREND SHIELD — M15 EMA Analysis                  |
//|  Returns: +1 = Bullish bias, -1 = Bearish bias, 0 = Neutral       |
//+------------------------------------------------------------------+
int GetMacroTrendBias()
  {
//--- Buffer arrays for EMA values (index 0 = most recent closed bar)
   double ema200[], ema60[], ema30[];
   ArraySetAsSeries(ema200, true);
   ArraySetAsSeries(ema60,  true);
   ArraySetAsSeries(ema30,  true);

//--- Copy 3 values for each EMA (bar 0 = current, bar 1 = previous closed)
   if(CopyBuffer(handleEMA200_M15, 0, 0, 3, ema200) < 3) return 0;
   if(CopyBuffer(handleEMA60_M15,  0, 0, 3, ema60)  < 3) return 0;
   if(CopyBuffer(handleEMA30_M15,  0, 0, 3, ema30)  < 3) return 0;

//--- Use the last CLOSED bar (index 1) for stability — avoids repainting on live bar
   double price200 = ema200[1];
   double price60  = ema60[1];
   double price30  = ema30[1];

//--- Read current M15 close price (last closed bar)
   double m15Close[];
   ArraySetAsSeries(m15Close, true);
   if(CopyClose(_Symbol, PERIOD_M15, 1, 1, m15Close) < 1) return 0;
   double closePrice = m15Close[0];

//--- BULLISH: Price > EMA200 AND EMA30 > EMA60 (fast above slow = uptrend)
   if(closePrice > price200 && price30 > price60)
      return 1;

//--- BEARISH: Price < EMA200 AND EMA30 < EMA60 (fast below slow = downtrend)
   if(closePrice < price200 && price30 < price60)
      return -1;

//--- NEUTRAL: Mixed signals — no trade authorization
   return 0;
  }

//+------------------------------------------------------------------+
//|  MODULE 3: MICRO-BURST EXECUTION SPEAR — M1 BB + MACD             |
//|  Returns: +1 = Buy signal, -1 = Sell signal, 0 = No signal        |
//+------------------------------------------------------------------+
int GetMicroBurstSignal()
  {
//--- ── Bollinger Band Buffers ───────────────────────────────────────
//    iBands buffer index: 0=middle, 1=upper, 2=lower
   double fastUpper[], fastLower[], fastMiddle[];
   double slowUpper[], slowLower[], slowMiddle[];

   ArraySetAsSeries(fastUpper,  true); ArraySetAsSeries(fastLower,  true);
   ArraySetAsSeries(fastMiddle, true); ArraySetAsSeries(slowUpper,  true);
   ArraySetAsSeries(slowLower,  true); ArraySetAsSeries(slowMiddle, true);

//--- Require 3 bars of history for signal confirmation
   if(CopyBuffer(handleFastBB_M1, 1, 0, 3, fastUpper)  < 3) return 0;
   if(CopyBuffer(handleFastBB_M1, 2, 0, 3, fastLower)  < 3) return 0;
   if(CopyBuffer(handleFastBB_M1, 0, 0, 3, fastMiddle) < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 1, 0, 3, slowUpper)  < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 2, 0, 3, slowLower)  < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 0, 0, 3, slowMiddle) < 3) return 0;

//--- ── MACD Buffers ─────────────────────────────────────────────────
//    iMACD buffer index: 0=MACD main line, 1=Signal line
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);

   if(CopyBuffer(handleMACD_M1, 0, 0, 3, macdMain)   < 3) return 0;
   if(CopyBuffer(handleMACD_M1, 1, 0, 3, macdSignal) < 3) return 0;

//--- Use last CLOSED bar (index 1) for entry confirmation to avoid false signals
//    Also read the bar before that (index 2) to detect the actual cross
   double fastUpp_1 = fastUpper[1],  fastUpp_2 = fastUpper[2];
   double fastLow_1 = fastLower[1],  fastLow_2 = fastLower[2];
   double slowUpp_1 = slowUpper[1],  slowUpp_2 = slowUpper[2];
   double slowLow_1 = slowLower[1],  slowLow_2 = slowLower[2];

   double macdMain_1   = macdMain[1],   macdMain_2   = macdMain[2];
   double macdSignal_1 = macdSignal[1], macdSignal_2 = macdSignal[2];

//--- ── BUY SIGNAL LOGIC ─────────────────────────────────────────────
//    Condition A: Fast BB LOWER band moved BELOW Slow BB LOWER band
//                 (fast band contracted below the slow band — squeeze/compression)
   bool fastBBBelowSlow = (fastLow_1 < slowLow_1) && (fastLow_2 >= slowLow_2);

//    Condition B: MACD crossed its Signal line UPWARD (bullish cross)
//                 AND both MACD and Signal are in the OVERSOLD zone (below zero)
   bool macdBullCross = (macdMain_1 > macdSignal_1) &&
                        (macdMain_2 <= macdSignal_2) &&
                        (macdMain_1 < 0.0) &&
                        (macdSignal_1 < 0.0);

   if(fastBBBelowSlow && macdBullCross)
      return 1; // BUY signal confirmed

//--- ── SELL SIGNAL LOGIC ────────────────────────────────────────────
//    Condition A: Fast BB UPPER band moved ABOVE Slow BB UPPER band
//                 (fast band expanded above slow band — overbought expansion)
   bool fastBBAboveSlow = (fastUpp_1 > slowUpp_1) && (fastUpp_2 <= slowUpp_2);

//    Condition B: MACD crossed its Signal line DOWNWARD (bearish cross)
//                 AND both MACD and Signal are in the OVERBOUGHT zone (above zero)
   bool macdBearCross = (macdMain_1 < macdSignal_1) &&
                        (macdMain_2 >= macdSignal_2) &&
                        (macdMain_1 > 0.0) &&
                        (macdSignal_1 > 0.0);

   if(fastBBAboveSlow && macdBearCross)
      return -1; // SELL signal confirmed

   return 0; // No signal
  }

//+------------------------------------------------------------------+
//|  EXECUTE BUY ORDER                                                 |
//|  SL = Fast BB lower band, capped at InpMaxSLPips                   |
//+------------------------------------------------------------------+
void ExecuteBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;
   double lot = CalculateLotSize();

//--- Get current Fast BB lower band value for stop loss placement
   double fastLower[];
   ArraySetAsSeries(fastLower, true);
   if(CopyBuffer(handleFastBB_M1, 2, 0, 2, fastLower) < 2) return;

   double rawSL = fastLower[1]; // Lower BB of last closed M1 bar

//--- Cap the SL distance at InpMaxSLPips to protect micro-balance
   double maxSLPrice = ask - (InpMaxSLPips * g_PipSize);
   double sl = MathMax(rawSL, maxSLPrice); // Use whichever is higher (closer to price)

//--- Enforce broker's minimum stops level
   double minSLDistance = (g_MinStopsLevel + 5) * g_PointSize; // +5 point buffer for safety
   if((ask - sl) < minSLDistance)
      sl = ask - minSLDistance;

//--- Normalize prices to broker tick size
   sl = NormalizeDouble(sl, _Digits);

//--- No predefined take profit — exit managed dynamically by trailing logic
   double tp = 0.0;

//--- Validate the order before sending
   if(sl >= ask)
     {
      PrintFormat("[BUY] Invalid SL %.5f >= ASK %.5f. Skipping.", sl, ask);
      return;
     }

   bool result = trade.Buy(lot, _Symbol, ask, sl, tp,
                           StringFormat("ScalperBuy | SL@%.5f", sl));
   if(result)
      PrintFormat("[BUY ENTRY] Lot=%.2f | Ask=%.5f | SL=%.5f | Ticket=%I64u",
                  lot, ask, sl, trade.ResultOrder());
   else
      PrintFormat("[BUY ERROR] Code=%d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//|  EXECUTE SELL ORDER                                                |
//|  SL = Fast BB upper band, capped at InpMaxSLPips                   |
//+------------------------------------------------------------------+
void ExecuteSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;
   double lot = CalculateLotSize();

//--- Get current Fast BB upper band value for stop loss placement
   double fastUpper[];
   ArraySetAsSeries(fastUpper, true);
   if(CopyBuffer(handleFastBB_M1, 1, 0, 2, fastUpper) < 2) return;

   double rawSL = fastUpper[1]; // Upper BB of last closed M1 bar

//--- Cap the SL distance at InpMaxSLPips
   double maxSLPrice = bid + (InpMaxSLPips * g_PipSize);
   double sl = MathMin(rawSL, maxSLPrice); // Use whichever is lower (closer to price)

//--- Enforce broker's minimum stops level
   double minSLDistance = (g_MinStopsLevel + 5) * g_PointSize;
   if((sl - bid) < minSLDistance)
      sl = bid + minSLDistance;

//--- Normalize prices
   sl = NormalizeDouble(sl, _Digits);

   double tp = 0.0;

//--- Validate
   if(sl <= bid)
     {
      PrintFormat("[SELL] Invalid SL %.5f <= BID %.5f. Skipping.", sl, bid);
      return;
     }

   bool result = trade.Sell(lot, _Symbol, bid, sl, tp,
                            StringFormat("ScalperSell | SL@%.5f", sl));
   if(result)
      PrintFormat("[SELL ENTRY] Lot=%.2f | Bid=%.5f | SL=%.5f | Ticket=%I64u",
                  lot, bid, sl, trade.ResultOrder());
   else
      PrintFormat("[SELL ERROR] Code=%d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//|  MODULE 4: DYNAMIC TRAILING EXIT MATRIX                            |
//|  Manages ALL open positions: Breakeven, Trailing, MACD Exit        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
//--- Read current MACD for emergency exit logic
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);
   bool macdDataOK = (CopyBuffer(handleMACD_M1, 0, 0, 3, macdMain)   >= 3 &&
                      CopyBuffer(handleMACD_M1, 1, 0, 3, macdSignal) >= 3);

   int totalPositions = PositionsTotal();

   for(int i = totalPositions - 1; i >= 0; i--)
     {
      //--- Select position by index and filter by our magic number + symbol
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;
      if(posInfo.Symbol() != _Symbol)        continue;

      ulong  ticket     = posInfo.Ticket();
      double openPrice  = posInfo.PriceOpen();
      double currentSL  = posInfo.StopLoss();
      double posType    = posInfo.PositionType(); // POSITION_TYPE_BUY or POSITION_TYPE_SELL
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Calculate floating profit in PIPS
      double profitPips = 0.0;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (currentBid - openPrice) / g_PipSize;
      else
         profitPips = (openPrice - currentAsk) / g_PipSize;

      //═══════════════════════════════════════════════════════════════
      //  4A: MACD ZERO-LINE CROSS EMERGENCY EXIT
      //  If MACD crosses the zero line AGAINST the position → close now
      //═══════════════════════════════════════════════════════════════
      if(macdDataOK)
        {
         bool macdCrossedZeroBearish = (macdMain[1] < 0.0) && (macdMain[2] >= 0.0);
         bool macdCrossedZeroBullish = (macdMain[1] > 0.0) && (macdMain[2] <= 0.0);

         bool emergencyExit = false;
         if(posType == POSITION_TYPE_BUY  && macdCrossedZeroBearish) emergencyExit = true;
         if(posType == POSITION_TYPE_SELL && macdCrossedZeroBullish) emergencyExit = true;

         if(emergencyExit && profitPips > 0) // Only close if we're in profit (protect floating gain)
           {
            PrintFormat("[MACD ZERO EXIT] Ticket %I64u | Type=%s | ProfitPips=%.1f",
                        ticket, (posType == POSITION_TYPE_BUY ? "BUY" : "SELL"), profitPips);
            trade.PositionClose(ticket, InpMaxSlippage);
            continue; // Move to next position
           }
        }

      //═══════════════════════════════════════════════════════════════
      //  4B: BREAKEVEN ACTIVATION (at InpBreakevenPips profit)
      //═══════════════════════════════════════════════════════════════
      double breakEvenSL    = 0.0;
      double breakEvenPips  = InpBreakevenPips;
      double bufferPips     = InpBreakevenBuffer;

      if(profitPips >= breakEvenPips)
        {
         //--- Calculate breakeven SL with buffer
         if(posType == POSITION_TYPE_BUY)
            breakEvenSL = NormalizeDouble(openPrice + bufferPips * g_PipSize, _Digits);
         else
            breakEvenSL = NormalizeDouble(openPrice - bufferPips * g_PipSize, _Digits);

         //--- Only modify if the new SL is better (further from entry in profit direction)
         bool needsBreakeven = false;
         if(posType == POSITION_TYPE_BUY  && breakEvenSL > currentSL + g_PointSize)
            needsBreakeven = true;
         if(posType == POSITION_TYPE_SELL && (currentSL == 0.0 || breakEvenSL < currentSL - g_PointSize))
            needsBreakeven = true;

         if(needsBreakeven)
           {
            //--- Enforce minimum stop distance from current price
            double minDist = (g_MinStopsLevel + 5) * g_PointSize;
            if(posType == POSITION_TYPE_BUY && (currentBid - breakEvenSL) < minDist)
               breakEvenSL = NormalizeDouble(currentBid - minDist, _Digits);
            if(posType == POSITION_TYPE_SELL && (breakEvenSL - currentAsk) < minDist)
               breakEvenSL = NormalizeDouble(currentAsk + minDist, _Digits);

            if(trade.PositionModify(ticket, breakEvenSL, posInfo.TakeProfit()))
               PrintFormat("[BREAKEVEN] Ticket %I64u | SL moved to %.5f (+%.1f pip buffer)",
                           ticket, breakEvenSL, bufferPips);
            continue;
           }

         //═══════════════════════════════════════════════════════════
         //  4C: STEP TRAILING STOP (activates after breakeven is set)
         //  Moves SL in InpTrailStepPips increments as profit grows
         //═══════════════════════════════════════════════════════════
         double trailStep = InpTrailStepPips * g_PipSize;
         double newTrailSL = 0.0;

         if(posType == POSITION_TYPE_BUY)
           {
            //--- Trail SL = current price minus one trail step
            //    Only advance if new SL is more than one step ahead of current SL
            double candidateSL = NormalizeDouble(currentBid - trailStep, _Digits);
            if(candidateSL > currentSL + trailStep)
               newTrailSL = candidateSL;
           }
         else // SELL
           {
            double candidateSL = NormalizeDouble(currentAsk + trailStep, _Digits);
            if(currentSL == 0.0 || candidateSL < currentSL - trailStep)
               newTrailSL = candidateSL;
           }

         if(newTrailSL > 0.0)
           {
            //--- Enforce minimum stop distance
            double minDist = (g_MinStopsLevel + 5) * g_PointSize;
            if(posType == POSITION_TYPE_BUY && (currentBid - newTrailSL) < minDist)
               newTrailSL = NormalizeDouble(currentBid - minDist, _Digits);
            if(posType == POSITION_TYPE_SELL && (newTrailSL - currentAsk) < minDist)
               newTrailSL = NormalizeDouble(currentAsk + minDist, _Digits);

            if(trade.PositionModify(ticket, newTrailSL, posInfo.TakeProfit()))
               PrintFormat("[TRAIL] Ticket %I64u | SL advanced to %.5f | Profit: %.1f pips",
                           ticket, newTrailSL, profitPips);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//|  MODULE 5: SMART NEWS — CHECK ECONOMIC CALENDAR                    |
//|  Scans for HIGH IMPACT USD events                                  |
//|  Sets newsBlackout and straddleWindow flags                        |
//+------------------------------------------------------------------+
void CheckNewsCalendar(bool &newsBlackout, bool &straddleWindow)
  {
   newsBlackout   = false;
   straddleWindow = false;

   datetime now        = TimeCurrent();
   datetime scanStart  = now - (InpNewsPostMinutes  + 1) * 60; // Look back post-window
   datetime scanEnd    = now + (InpNewsPreMinutes    + 1) * 60; // Look forward pre-window

//--- Fetch calendar events in the scan window
   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, scanStart, scanEnd, "USD");
   if(count <= 0) return; // No USD events in range

   for(int i = 0; i < count; i++)
     {
      //--- Only process HIGH impact events
      MqlCalendarEvent eventInfo;
      if(!CalendarEventById(values[i].event_id, eventInfo)) continue;
      if(eventInfo.importance != CALENDAR_IMPORTANCE_HIGH)   continue;

      datetime eventTime = values[i].time; // Actual scheduled event time

      //--- Time differences in seconds
      long secToEvent   = (long)(eventTime - now); // Positive = future, Negative = past
      long secAfterNews = (long)(now - eventTime); // How long since news fired

      //--- PRE-NEWS BLACKOUT: 15 minutes before event
      if(secToEvent > 0 && secToEvent <= InpNewsPreMinutes * 60)
        {
         newsBlackout = true;
         g_NewsEventTimestamp = eventTime;
        }

      //--- POST-NEWS BLACKOUT: 15 minutes after event
      if(secAfterNews >= 0 && secAfterNews <= InpNewsPostMinutes * 60)
        {
         newsBlackout = true;
        }

      //--- STRADDLE WINDOW: exactly 2 minutes before event (and blackout active)
      if(secToEvent > 0 && secToEvent <= InpStraddleMinutes * 60)
        {
         straddleWindow = true;
         g_NewsEventTimestamp = eventTime;
        }
     }
  }

//+------------------------------------------------------------------+
//|  MODULE 5: PLACE NEWS STRADDLE                                     |
//|  Buy Stop 150 pips above + Sell Stop 150 pips below current price  |
//+------------------------------------------------------------------+
void PlaceNewsStraddle()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   double midPrice    = (ask + bid) / 2.0;
   double straddleDist = InpStraddlePips * g_PipSize;

   double buyStopPrice  = NormalizeDouble(midPrice + straddleDist, _Digits);
   double sellStopPrice = NormalizeDouble(midPrice - straddleDist, _Digits);

//--- Enforce minimum stop distance from current price
   double minDist = (g_MinStopsLevel + 10) * g_PointSize;
   if(buyStopPrice  - ask < minDist) buyStopPrice  = NormalizeDouble(ask  + minDist, _Digits);
   if(bid - sellStopPrice < minDist) sellStopPrice = NormalizeDouble(bid  - minDist, _Digits);

//--- Expiry: 10 minutes from now (gives time for both legs to be placed)
   datetime expiry = TimeCurrent() + 600;

//--- Place Buy Stop with basic SL/TP (managed dynamically post-trigger)
   double bsSlPrice = NormalizeDouble(buyStopPrice  - InpMaxSLPips * g_PipSize, _Digits);
   double ssSlPrice = NormalizeDouble(sellStopPrice + InpMaxSLPips * g_PipSize, _Digits);

   if(trade.BuyStop(InpLotSize, buyStopPrice, _Symbol, bsSlPrice, 0.0,
                    ORDER_TIME_SPECIFIED, expiry, "NewsStraddleBuy"))
     {
      g_StraddleBuyTicket = trade.ResultOrder();
      PrintFormat("[STRADDLE] Buy Stop placed @ %.5f | SL @ %.5f | Ticket %I64u",
                  buyStopPrice, bsSlPrice, g_StraddleBuyTicket);
     }
   else
      PrintFormat("[STRADDLE ERROR] BuyStop failed: %d | %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());

   if(trade.SellStop(InpLotSize, sellStopPrice, _Symbol, ssSlPrice, 0.0,
                     ORDER_TIME_SPECIFIED, expiry, "NewsStraddleSell"))
     {
      g_StraddleSellTicket = trade.ResultOrder();
      PrintFormat("[STRADDLE] Sell Stop placed @ %.5f | SL @ %.5f | Ticket %I64u",
                  sellStopPrice, ssSlPrice, g_StraddleSellTicket);
     }
   else
      PrintFormat("[STRADDLE ERROR] SellStop failed: %d | %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());

//--- Mark straddle as active
   g_StraddlePlaced    = true;
   g_StraddlePlacedAt  = TimeCurrent();
   PrintFormat("[STRADDLE] Active | NewsEvent @ %s | BuyStop=%I64u | SellStop=%I64u",
               TimeToString(g_NewsEventTimestamp), g_StraddleBuyTicket, g_StraddleSellTicket);
  }

//+------------------------------------------------------------------+
//|  MODULE 5: MANAGE STRADDLE EXPIRY                                  |
//|  Cancel the untriggered leg 5 minutes after the news release       |
//+------------------------------------------------------------------+
void ManageStraddleExpiry()
  {
   if(!g_StraddlePlaced) return;
   if(g_NewsEventTimestamp == 0) return;

   datetime now = TimeCurrent();
   long secAfterNews = (long)(now - g_NewsEventTimestamp);

//--- Check if 5 minutes have elapsed since the news release
   if(secAfterNews >= InpStraddleExpiry * 60)
     {
      PrintFormat("[STRADDLE EXPIRY] %d minutes elapsed since news. Cancelling untriggered leg(s).", InpStraddleExpiry);

      //--- Cancel Buy Stop if still pending (not triggered)
      if(g_StraddleBuyTicket > 0 && OrderSelect(g_StraddleBuyTicket))
        {
         if(trade.OrderDelete(g_StraddleBuyTicket))
            PrintFormat("[STRADDLE] Buy Stop %I64u cancelled (expired).", g_StraddleBuyTicket);
         g_StraddleBuyTicket = 0;
        }

      //--- Cancel Sell Stop if still pending
      if(g_StraddleSellTicket > 0 && OrderSelect(g_StraddleSellTicket))
        {
         if(trade.OrderDelete(g_StraddleSellTicket))
            PrintFormat("[STRADDLE] Sell Stop %I64u cancelled (expired).", g_StraddleSellTicket);
         g_StraddleSellTicket = 0;
        }

      //--- Reset straddle state
      g_StraddlePlaced      = false;
      g_StraddlePlacedAt    = 0;
      g_NewsEventTimestamp  = 0;
     }
  }

//+------------------------------------------------------------------+
//|  UTILITY: CLOSE ALL OPEN POSITIONS (Emergency Use)                 |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   Print("[EMERGENCY CLOSE] Closing ALL positions for symbol: ", _Symbol);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      ulong ticket = posInfo.Ticket();
      if(trade.PositionClose(ticket, InpMaxSlippage))
         PrintFormat("[EMERGENCY CLOSE] Ticket %I64u closed.", ticket);
      else
         PrintFormat("[EMERGENCY CLOSE ERROR] Ticket %I64u failed: %d | %s",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//|  UTILITY: CANCEL ALL PENDING ORDERS                                |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
  {
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol) continue;
      if(orderInfo.Magic()  != InpMagicNumber) continue;
      ulong ticket = orderInfo.Ticket();
      if(trade.OrderDelete(ticket))
         PrintFormat("[CANCEL ORDER] Pending order %I64u deleted.", ticket);
     }
  }

//+------------------------------------------------------------------+
//|  UTILITY: COUNT OPEN POSITIONS FOR THIS EA                         |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;
      if(posInfo.Symbol() != _Symbol)        continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//|  UTILITY: LIVE CHART STATUS COMMENT                                |
//+------------------------------------------------------------------+
void UpdateChartComment(double equity, long spread)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double margin  = AccountInfoDouble(ACCOUNT_MARGIN);

   string status = g_EmergencyShutdown ? "⛔ EMERGENCY HALT" :
                   g_TradingLocked     ? "🔒 TRADING LOCKED (Harvest)" :
                   "✅ TRADING ACTIVE";

   string commentText = StringFormat(
                          "═══ XAUUSDm Precision Scalper ═══\n"
                          "Status   : %s\n"
                          "Equity   : $%.2f  |  Balance: $%.2f\n"
                          "Spread   : %d pts  |  Margin: $%.2f\n"
                          "Hard Floor: $%.2f  |  Positions: %d\n"
                          "Harvest 1: $%.2f [%s]\n"
                          "Harvest 2: $%.2f [%s]\n"
                          "Harvest 3: $%.2f [%s]\n"
                          "News Guard: %s  |  Straddle: %s\n"
                          "═══════════════════════════════════",
                          status,
                          equity, balance,
                          spread, margin,
                          InpHardFloorEquity, CountOpenPositions(),
                          InpHarvestTarget1, g_HarvestLevel1Hit ? "HIT ✓" : "Pending",
                          InpHarvestTarget2, g_HarvestLevel2Hit ? "HIT ✓" : "Pending",
                          InpHarvestTarget3, g_HarvestLevel3Hit ? "HIT ✓" : "Pending",
                          InpEnableNewsFilter ? "ON" : "OFF",
                          g_StraddlePlaced    ? "ACTIVE" : "None"
                        );
   Comment(commentText);
  }

//+------------------------------------------------------------------+
//|  END OF EXPERT ADVISOR                                             |
//+------------------------------------------------------------------+
