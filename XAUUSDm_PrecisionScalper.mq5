//+------------------------------------------------------------------+
//|          XAUUSDm_ForgeScalper_v2.mq5                             |
//|          QuantForge Dual-Engine EA — Version 2.0                 |
//|          Optimized for Exness Standard Account | XAUUSDm         |
//|                                                                  |
//|  ═══════════════════════════════════════════════════════════════ |
//|  CHANGELOG from v1.0 (PrecisionScalper):                        |
//|                                                                  |
//|  FIX 1 — Signal Contradiction Resolved                          |
//|           Removed MACD zero-zone requirement that made signals   |
//|           almost impossible to fire in a trending market.        |
//|                                                                  |
//|  FIX 2 — Spread Filter Corrected                                |
//|           Default tightened from 350 pts to 60 pts (6 pips),    |
//|           appropriate for XAUUSD scalping on Exness.            |
//|                                                                  |
//|  FIX 3 — Dead Code Eliminated                                   |
//|           ManagePosition() removed. ManageOpenPositions() is now |
//|           the single unified position manager for ALL trades.    |
//|                                                                  |
//|  FIX 4 — Session Filter Added                                   |
//|           Entries restricted to London/NY overlap 08:00-17:00   |
//|           GMT to avoid low-liquidity Asian session noise.        |
//|                                                                  |
//|  FIX 5 — Dynamic Lot Sizing Added                               |
//|           Lots now scale with equity using % risk model instead  |
//|           of hardcoded 0.01 for both engines.                    |
//|                                                                  |
//|  FIX 6 — Duplicate Straddle Code Removed                        |
//|           Only PlaceNetlessStraddle() (OrderSend version) kept.  |
//|           trade.BuyStop/SellStop version deleted.                |
//|                                                                  |
//|  NEW — ENGINE 2: H1 Swing Trader Module                         |
//|         Uses EMA21/50/200 trend alignment + RSI(14) pullback     |
//|         recovery + MACD H1 confirmation + ATR(14) dynamic        |
//|         SL/TP. Targets 300-600 pip moves for daily base income.  |
//|                                                                  |
//|  ARCHITECTURE:                                                   |
//|    Module 1: Capital Preservation & Harvest-Halt Protocol        |
//|    Module 2: M15 Macro-Trend Shield (Scalper gatekeeper)         |
//|    Module 3: M1 Micro-Burst Execution Spear (Scalper engine)     |
//|    Module 4: H1 Swing Trader (New income layer)                  |
//|    Module 5: Unified Dynamic Trailing Exit Matrix                |
//|    Module 6: News Integration + Netless Straddle                 |
//|    Module 7: Session Filter (GMT 08:00-17:00)                    |
//+------------------------------------------------------------------+
#property copyright "QuantForge v2.0"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

//--- Capital & Risk
input group "=== CAPITAL MANAGEMENT ==="
input double InpInitialBalance   = 110.00;  // Starting account principal ($)
input double InpHardFloorEquity  = 55.00;   // Absolute equity floor — halt & flatten below this
input double InpScalperRiskPct   = 1.0;     // Scalper risk per trade (% of equity)
input double InpSwingRiskPct     = 1.5;     // Swing risk per trade (% of equity)
input double InpMinLotSize       = 0.01;    // Minimum lot size (broker floor)
input double InpMaxLotSize       = 0.10;    // Maximum lot size (safety cap for micro accounts)

//--- Harvest Targets
input group "=== HARVEST & HALT TARGETS ==="
input double InpHarvestTarget1   = 165.00;  // Step 1: Equity target ($) — withdraw & restart
input double InpHarvestTarget2   = 210.00;  // Step 2: Equity target ($)
input double InpHarvestTarget3   = 262.50;  // Step 3: Equity target ($)

//--- Execution Guards
input group "=== SPREAD & EXECUTION GUARDS ==="
input int    InpMaxSpreadPoints  = 60;      // Max spread in points (60 = 6 pips — tight for scalping)
input int    InpMaxSlippage      = 30;      // Max slippage in points

//--- Session Filter
input group "=== SESSION FILTER (GMT) ==="
input bool   InpEnableSession    = true;    // Enable London/NY session filter
input int    InpSessionStartHour = 8;       // Session open hour (GMT) — London open
input int    InpSessionEndHour   = 17;      // Session close hour (GMT) — NY midday
input bool   InpSwingAnySession  = true;    // Allow swing trades outside session (H1 signals)

//--- ENGINE 1: M15 Macro-Trend Shield (Scalper)
input group "=== ENGINE 1: M15 MACRO-TREND SHIELD ==="
input int    InpEMA200Period     = 200;     // M15 EMA 200 (major trend)
input int    InpEMA60Period      = 60;      // M15 EMA 60  (medium trend)
input int    InpEMA30Period      = 30;      // M15 EMA 30  (fast trend)

//--- ENGINE 1: M1 Micro-Burst Spear (Scalper)
input group "=== ENGINE 1: M1 BOLLINGER BANDS ==="
input int    InpFastBBPeriod     = 20;      // Fast BB period (entry timing)
input double InpFastBBDeviation  = 2.0;     // Fast BB std deviation
input int    InpSlowBBPeriod     = 100;     // Slow BB period (volatility context)
input double InpSlowBBDeviation  = 2.0;     // Slow BB std deviation

input group "=== ENGINE 1: M1 MACD ==="
input int    InpMACDFast         = 12;      // MACD fast EMA
input int    InpMACDSlow         = 26;      // MACD slow EMA
input int    InpMACDSignal       = 9;       // MACD signal line

//--- ENGINE 1: Trailing Parameters (Scalper)
input group "=== ENGINE 1: SCALPER EXIT MATRIX ==="
input double InpBreakevenPips    = 120.0;   // Pips profit to trigger breakeven (lowered from 150)
input double InpBreakevenBuffer  = 15.0;    // Buffer above entry at breakeven (pips)
input double InpTrailStepPips    = 40.0;    // Trailing step size (pips)
input double InpMaxSLPips        = 200.0;   // Hard cap on scalper stop loss (pips)

//--- ENGINE 2: H1 Swing Trader
input group "=== ENGINE 2: H1 SWING TRADER ==="
input bool   InpEnableSwing      = true;    // Enable H1 swing engine
input int    InpH1_EMA21         = 21;      // H1 fast EMA (trend pulse)
input int    InpH1_EMA50         = 50;      // H1 medium EMA (trend spine)
input int    InpH1_EMA200        = 200;     // H1 slow EMA (macro structure)
input int    InpH1_RSIPeriod     = 14;      // H1 RSI period
input double InpH1_RSIOverbought = 60.0;    // RSI level considered overbought zone exit
input double InpH1_RSIOversold   = 40.0;    // RSI level considered oversold zone exit
input int    InpH1_MACDFast      = 12;      // H1 MACD fast
input int    InpH1_MACDSlow      = 26;      // H1 MACD slow
input int    InpH1_MACDSig       = 9;       // H1 MACD signal
input int    InpH1_ATRPeriod     = 14;      // H1 ATR period for dynamic SL/TP
input double InpH1_SL_ATR_Multi  = 1.5;     // SL = entry ± (ATR × this multiplier)
input double InpH1_TP_ATR_Multi  = 3.0;     // TP = entry ± (ATR × this multiplier)  [1:2 R:R]
input double InpSwingBreakeven   = 200.0;   // Pips profit to trigger swing breakeven
input double InpSwingTrailStep   = 80.0;    // Swing trailing step (pips)

//--- NEWS Integration
input group "=== NEWS & ECONOMIC CALENDAR ==="
input bool   InpEnableNewsFilter  = true;   // Enable high-impact USD news blackout
input int    InpNewsPreMinutes    = 15;     // Minutes to pause BEFORE news
input int    InpNewsPostMinutes   = 15;     // Minutes to resume AFTER news
input int    InpStraddleMinutes   = 2;      // Minutes before event to place straddle
input int    InpStraddleExpiry    = 5;      // Minutes after event to cancel untriggered leg
input double InpStraddlePips      = 150.0;  // Straddle distance from mid-price (pips)

//--- EA Identity
input group "=== EA IDENTITY ==="
input int    InpScalperMagic     = 202401;  // Magic number for scalper trades
input int    InpSwingMagic       = 202402;  // Magic number for swing trades

//+------------------------------------------------------------------+
//|  GLOBAL VARIABLES & HANDLES                                       |
//+------------------------------------------------------------------+

CTrade        trade;
CPositionInfo posInfo;
COrderInfo    orderInfo;

//--- ENGINE 1: M15 EMA handles
int handleEMA200_M15  = INVALID_HANDLE;
int handleEMA60_M15   = INVALID_HANDLE;
int handleEMA30_M15   = INVALID_HANDLE;

//--- ENGINE 1: M1 BB + MACD handles
int handleFastBB_M1   = INVALID_HANDLE;
int handleSlowBB_M1   = INVALID_HANDLE;
int handleMACD_M1     = INVALID_HANDLE;

//--- ENGINE 2: H1 handles
int handleH1_EMA21    = INVALID_HANDLE;
int handleH1_EMA50    = INVALID_HANDLE;
int handleH1_EMA200   = INVALID_HANDLE;
int handleH1_RSI      = INVALID_HANDLE;
int handleH1_MACD     = INVALID_HANDLE;
int handleH1_ATR      = INVALID_HANDLE;

//--- EA State Flags
bool g_EmergencyShutdown   = false;  // Hard floor breached — permanent halt
bool g_TradingLocked        = false;  // Harvest-halt triggered — new entries blocked
bool g_HarvestLevel1Hit     = false;
bool g_HarvestLevel2Hit     = false;
bool g_HarvestLevel3Hit     = false;

//--- News & Straddle State
datetime g_NewsEventTimestamp  = 0;
bool     g_StraddlePlaced       = false;
ulong    g_StraddleBuyTicket    = 0;
ulong    g_StraddleSellTicket   = 0;
datetime g_StraddlePlacedAt     = 0;

//--- Point/pip conversion (Exness 5-digit: 1 pip = 10 points)
double g_PointSize  = 0.0;
double g_PipSize    = 0.0;
int    g_MinStopsLevel = 0;

//--- Swing trade cooldown (prevent re-entry within same H1 bar)
datetime g_LastSwingBarTime = 0;

//+------------------------------------------------------------------+
//|  INITIALIZATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Set trade objects
   trade.SetExpertMagicNumber(InpScalperMagic); // Default to scalper magic
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);      // Exness requires IOC

//--- Cache pip metrics
   g_PointSize    = _Point;
   g_PipSize      = 10.0 * _Point;  // 5-digit broker: 1 pip = 10 points
   g_MinStopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   PrintFormat("[INIT] MinStopsLevel=%d pts | PipSize=%.5f", g_MinStopsLevel, g_PipSize);

//--- ENGINE 1: M15 EMA handles
   handleEMA200_M15 = iMA(_Symbol, PERIOD_M15, InpEMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA60_M15  = iMA(_Symbol, PERIOD_M15, InpEMA60Period,  0, MODE_EMA, PRICE_CLOSE);
   handleEMA30_M15  = iMA(_Symbol, PERIOD_M15, InpEMA30Period,  0, MODE_EMA, PRICE_CLOSE);
   if(handleEMA200_M15 == INVALID_HANDLE ||
      handleEMA60_M15  == INVALID_HANDLE ||
      handleEMA30_M15  == INVALID_HANDLE)
     { Print("[INIT ERROR] M15 EMA handles failed."); return INIT_FAILED; }

//--- ENGINE 1: M1 BB handles
   handleFastBB_M1 = iBands(_Symbol, PERIOD_M1, InpFastBBPeriod, 0, InpFastBBDeviation, PRICE_CLOSE);
   handleSlowBB_M1 = iBands(_Symbol, PERIOD_M1, InpSlowBBPeriod, 0, InpSlowBBDeviation, PRICE_CLOSE);
   if(handleFastBB_M1 == INVALID_HANDLE || handleSlowBB_M1 == INVALID_HANDLE)
     { Print("[INIT ERROR] M1 Bollinger Band handles failed."); return INIT_FAILED; }

//--- ENGINE 1: M1 MACD handle
   handleMACD_M1 = iMACD(_Symbol, PERIOD_M1, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   if(handleMACD_M1 == INVALID_HANDLE)
     { Print("[INIT ERROR] M1 MACD handle failed."); return INIT_FAILED; }

//--- ENGINE 2: H1 handles (only if swing enabled)
   if(InpEnableSwing)
     {
      handleH1_EMA21  = iMA  (_Symbol, PERIOD_H1, InpH1_EMA21,   0, MODE_EMA,  PRICE_CLOSE);
      handleH1_EMA50  = iMA  (_Symbol, PERIOD_H1, InpH1_EMA50,   0, MODE_EMA,  PRICE_CLOSE);
      handleH1_EMA200 = iMA  (_Symbol, PERIOD_H1, InpH1_EMA200,  0, MODE_EMA,  PRICE_CLOSE);
      handleH1_RSI    = iRSI (_Symbol, PERIOD_H1, InpH1_RSIPeriod, PRICE_CLOSE);
      handleH1_MACD   = iMACD(_Symbol, PERIOD_H1, InpH1_MACDFast, InpH1_MACDSlow, InpH1_MACDSig, PRICE_CLOSE);
      handleH1_ATR    = iATR (_Symbol, PERIOD_H1, InpH1_ATRPeriod);

      if(handleH1_EMA21  == INVALID_HANDLE || handleH1_EMA50  == INVALID_HANDLE ||
         handleH1_EMA200 == INVALID_HANDLE || handleH1_RSI    == INVALID_HANDLE ||
         handleH1_MACD   == INVALID_HANDLE || handleH1_ATR    == INVALID_HANDLE)
        { Print("[INIT ERROR] H1 Swing handles failed."); return INIT_FAILED; }
     }

   Print("[INIT] ForgeScalper v2.0 initialized. Dual-engine ready.");
   Print("[INIT] Hard Floor: $", InpHardFloorEquity,
         " | Scalper Risk: ", InpScalperRiskPct, "%",
         " | Swing: ", (InpEnableSwing ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  DEINITIALIZATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handleEMA200_M15 != INVALID_HANDLE) IndicatorRelease(handleEMA200_M15);
   if(handleEMA60_M15  != INVALID_HANDLE) IndicatorRelease(handleEMA60_M15);
   if(handleEMA30_M15  != INVALID_HANDLE) IndicatorRelease(handleEMA30_M15);
   if(handleFastBB_M1  != INVALID_HANDLE) IndicatorRelease(handleFastBB_M1);
   if(handleSlowBB_M1  != INVALID_HANDLE) IndicatorRelease(handleSlowBB_M1);
   if(handleMACD_M1    != INVALID_HANDLE) IndicatorRelease(handleMACD_M1);
   if(handleH1_EMA21   != INVALID_HANDLE) IndicatorRelease(handleH1_EMA21);
   if(handleH1_EMA50   != INVALID_HANDLE) IndicatorRelease(handleH1_EMA50);
   if(handleH1_EMA200  != INVALID_HANDLE) IndicatorRelease(handleH1_EMA200);
   if(handleH1_RSI     != INVALID_HANDLE) IndicatorRelease(handleH1_RSI);
   if(handleH1_MACD    != INVALID_HANDLE) IndicatorRelease(handleH1_MACD);
   if(handleH1_ATR     != INVALID_HANDLE) IndicatorRelease(handleH1_ATR);
   PrintFormat("[DEINIT] ForgeScalper v2.0 removed. Code=%d", reason);
  }

//+------------------------------------------------------------------+
//|  MAIN TICK HANDLER                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Permanent shutdown guard
   if(g_EmergencyShutdown)
     {
      Comment("⛔ EMERGENCY SHUTDOWN — Hard floor breached. Restart EA manually.");
      return;
     }

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

//--- Hard floor: flatten everything, halt permanently
   if(equity <= InpHardFloorEquity)
     {
      PrintFormat("[HARD FLOOR] Equity $%.2f ≤ Floor $%.2f — Emergency close + halt.",
                  equity, InpHardFloorEquity);
      SendNotification(StringFormat("⛔ HARD FLOOR HIT: Equity $%.2f. Positions closed.", equity));
      CloseAllPositions();
      CancelAllPendingOrders();
      g_EmergencyShutdown = true;
      g_TradingLocked     = true;
      return;
     }

//--- Check harvest milestones (locks new entries, sends push notification)
   CheckHarvestTargets(equity);

//--- ═══════════════════════════════════════════════════════════════
//    POSITION MANAGEMENT ALWAYS RUNS — even when entries are locked.
//    This ensures open trades are actively managed regardless of state.
//--- ═══════════════════════════════════════════════════════════════
   ManageOpenPositions(); // Unified manager handles both scalper + swing

//--- If entry is locked by harvest, skip new entry logic
   if(g_TradingLocked)
     {
      UpdateChartComment(equity, spread);
      return;
     }

//--- Spread guard (only blocks scalper-style entries; swing can absorb wider spreads)
   bool spreadOK = (spread <= InpMaxSpreadPoints);

//--- News filter: blocks entries and manages straddle lifecycle
   bool newsBlackout   = false;
   bool straddleWindow = false;
   if(InpEnableNewsFilter)
      CheckNewsCalendar(newsBlackout, straddleWindow);

//--- Manage straddle expiry regardless of new entry logic
   if(g_StraddlePlaced)
      ManageStraddleExpiry();

//--- ── ENGINE 1: M1 SCALPER ────────────────────────────────────────
//    Fires when: spread OK + no news + in session + no open scalp trade
   if(spreadOK && !newsBlackout && IsInSession() && CountPositionsByMagic(InpScalperMagic) == 0
      && !g_StraddlePlaced)
     {
      int scalperSignal = CheckScalperEntry(); // +1 buy, -1 sell, 0 no trade
      if(scalperSignal == 1)
         ExecuteScalperBuy();
      else if(scalperSignal == -1)
         ExecuteScalperSell();
     }

//--- ── ENGINE 2: H1 SWING TRADER ──────────────────────────────────
//    Fires when: swing enabled + no news + max 1 swing trade open
//    Uses InpSwingAnySession to optionally allow outside-session entries
   if(InpEnableSwing && !newsBlackout && CountPositionsByMagic(InpSwingMagic) == 0)
     {
      bool sessionOK = (!InpEnableSession || InpSwingAnySession || IsInSession());
      if(sessionOK)
        {
         // Throttle: only check once per new H1 bar to reduce signal noise
         datetime currentH1Bar = iTime(_Symbol, PERIOD_H1, 0);
         if(currentH1Bar != g_LastSwingBarTime)
           {
            int swingSignal = CheckSwingEntry(); // +1 buy, -1 sell, 0 no trade
            if(swingSignal == 1)
              { ExecuteSwingBuy();  g_LastSwingBarTime = currentH1Bar; }
            else if(swingSignal == -1)
              { ExecuteSwingSell(); g_LastSwingBarTime = currentH1Bar; }
            else
               g_LastSwingBarTime = currentH1Bar; // Still advance bar to avoid repeat checks
           }
        }
     }

//--- Place pre-news straddle if in straddle window and flat
   if(straddleWindow && !g_StraddlePlaced && CountPositionsByMagic(InpScalperMagic) == 0)
      PlaceNetlessStraddle(g_NewsEventTimestamp);

   UpdateChartComment(equity, spread);
  }

//+------------------------------------------------------------------+
//|  ══════════════════════════════════════════════════════════════   |
//|  ENGINE 1: SCALPER SIGNAL LOGIC                                  |
//|  Multi-timeframe: M15 bias gate + M1 BB squeeze + MACD cross     |
//|  Returns: +1=Buy, -1=Sell, 0=NoTrade                             |
//|  ══════════════════════════════════════════════════════════════   |
//+------------------------------------------------------------------+
int CheckScalperEntry()
  {
//── LAYER 1: M15 MACRO-TREND BIAS ────────────────────────────────
//   All three of: Price > EMA200, EMA30 > EMA60 = bullish
//   All three of: Price < EMA200, EMA30 < EMA60 = bearish
   double ema200[], ema60[], ema30[], m15Close[];
   ArraySetAsSeries(ema200,   true);
   ArraySetAsSeries(ema60,    true);
   ArraySetAsSeries(ema30,    true);
   ArraySetAsSeries(m15Close, true);

   if(CopyBuffer(handleEMA200_M15, 0, 0, 3, ema200) < 3) return 0;
   if(CopyBuffer(handleEMA60_M15,  0, 0, 3, ema60)  < 3) return 0;
   if(CopyBuffer(handleEMA30_M15,  0, 0, 3, ema30)  < 3) return 0;
   if(CopyClose(_Symbol, PERIOD_M15, 1, 1, m15Close) < 1) return 0;

   int macroBias = 0;
   // Use confirmed closed bar (index 1) to avoid repainting
   if(m15Close[0] > ema200[1] && ema30[1] > ema60[1])  macroBias =  1;
   else if(m15Close[0] < ema200[1] && ema30[1] < ema60[1]) macroBias = -1;
   else return 0; // Neutral — no trade

//── LAYER 2: M1 MICRO-BURST SPEAR ────────────────────────────────
//   BB Compression: Fast BB band crosses through Slow BB band
//   MACD Cross: Signal-line cross in direction of macro bias
//   NOTE (FIX 1): Zero-zone filter REMOVED — the old requirement for
//   MACD to be below/above zero simultaneously with M15 uptrend/downtrend
//   was contradictory. Now only the crossover direction matters.
   double fastUpper[], fastLower[];
   double slowUpper[], slowLower[];
   double macdMain[], macdSignal[];

   ArraySetAsSeries(fastUpper,  true); ArraySetAsSeries(fastLower,  true);
   ArraySetAsSeries(slowUpper,  true); ArraySetAsSeries(slowLower,  true);
   ArraySetAsSeries(macdMain,   true); ArraySetAsSeries(macdSignal, true);

   if(CopyBuffer(handleFastBB_M1, 1, 0, 3, fastUpper)  < 3) return 0;
   if(CopyBuffer(handleFastBB_M1, 2, 0, 3, fastLower)  < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 1, 0, 3, slowUpper)  < 3) return 0;
   if(CopyBuffer(handleSlowBB_M1, 2, 0, 3, slowLower)  < 3) return 0;
   if(CopyBuffer(handleMACD_M1,   0, 0, 3, macdMain)   < 3) return 0;
   if(CopyBuffer(handleMACD_M1,   1, 0, 3, macdSignal) < 3) return 0;

   // BUY conditions:
   // A) Fast BB lower band crosses BELOW slow BB lower (compression squeeze in down direction)
   // B) MACD line crosses ABOVE signal line (bullish momentum cross) — any zone
   bool bbBuySetup  = (fastLower[1] < slowLower[1]) && (fastLower[2] >= slowLower[2]);
   bool macdBullish = (macdMain[1] > macdSignal[1]) && (macdMain[2] <= macdSignal[2]);

   // SELL conditions:
   // A) Fast BB upper band crosses ABOVE slow BB upper (expansion squeeze to upside = exhaustion)
   // B) MACD line crosses BELOW signal line (bearish momentum cross) — any zone
   bool bbSellSetup  = (fastUpper[1] > slowUpper[1]) && (fastUpper[2] <= slowUpper[2]);
   bool macdBearish  = (macdMain[1] < macdSignal[1]) && (macdMain[2] >= macdSignal[2]);

   if(macroBias == 1  && bbBuySetup  && macdBullish) return  1;
   if(macroBias == -1 && bbSellSetup && macdBearish)  return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//|  ENGINE 1: EXECUTE SCALPER BUY                                   |
//|  SL at Fast BB lower band (capped at InpMaxSLPips)               |
//|  TP is 0 — managed by trailing exit matrix                       |
//+------------------------------------------------------------------+
void ExecuteScalperBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) return;

//--- Get Fast BB lower band for SL placement
   double fastLower[];
   ArraySetAsSeries(fastLower, true);
   if(CopyBuffer(handleFastBB_M1, 2, 0, 2, fastLower) < 2) return;

   double rawSL      = fastLower[1];                         // Lower BB of last closed M1 bar
   double maxSLPrice = ask - (InpMaxSLPips * g_PipSize);     // Maximum SL distance cap
   double sl         = MathMax(rawSL, maxSLPrice);            // Use whichever is tighter (closer)

//--- Enforce broker minimum stops distance
   double minDist = (g_MinStopsLevel + 5) * g_PointSize;
   if((ask - sl) < minDist) sl = ask - minDist;
   sl = NormalizeDouble(sl, _Digits);

   if(sl >= ask) { PrintFormat("[SCALPER BUY] Invalid SL %.5f >= ASK %.5f. Skip.", sl, ask); return; }

//--- Calculate dynamic lot from risk %
   double lot = CalcLotFromRisk(ask - sl, InpScalperRiskPct);

//--- Execute — no TP (trailing exit manages the trade)
   trade.SetExpertMagicNumber(InpScalperMagic);
   bool result = trade.Buy(lot, _Symbol, ask, sl, 0.0,
                           StringFormat("ForgeScalp-BUY|SL%.1f", (ask - sl) / g_PipSize));
   if(result)
      PrintFormat("[SCALPER BUY] Lot=%.2f | Ask=%.5f | SL=%.5f | Risk=%.2f pips | Ticket=%I64u",
                  lot, ask, sl, (ask - sl) / g_PipSize, trade.ResultOrder());
   else
      PrintFormat("[SCALPER BUY ERROR] %d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//|  ENGINE 1: EXECUTE SCALPER SELL                                  |
//+------------------------------------------------------------------+
void ExecuteScalperSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;

   double fastUpper[];
   ArraySetAsSeries(fastUpper, true);
   if(CopyBuffer(handleFastBB_M1, 1, 0, 2, fastUpper) < 2) return;

   double rawSL      = fastUpper[1];
   double maxSLPrice = bid + (InpMaxSLPips * g_PipSize);
   double sl         = MathMin(rawSL, maxSLPrice);

   double minDist = (g_MinStopsLevel + 5) * g_PointSize;
   if((sl - bid) < minDist) sl = bid + minDist;
   sl = NormalizeDouble(sl, _Digits);

   if(sl <= bid) { PrintFormat("[SCALPER SELL] Invalid SL %.5f <= BID %.5f. Skip.", sl, bid); return; }

   double lot = CalcLotFromRisk(sl - bid, InpScalperRiskPct);

   trade.SetExpertMagicNumber(InpScalperMagic);
   bool result = trade.Sell(lot, _Symbol, bid, sl, 0.0,
                            StringFormat("ForgeScalp-SELL|SL%.1f", (sl - bid) / g_PipSize));
   if(result)
      PrintFormat("[SCALPER SELL] Lot=%.2f | Bid=%.5f | SL=%.5f | Risk=%.2f pips | Ticket=%I64u",
                  lot, bid, sl, (sl - bid) / g_PipSize, trade.ResultOrder());
   else
      PrintFormat("[SCALPER SELL ERROR] %d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//|  ══════════════════════════════════════════════════════════════   |
//|  ENGINE 2: H1 SWING SIGNAL LOGIC                                 |
//|  Strategy (from knowledge base):                                 |
//|   - Triple EMA alignment (21/50/200) for directional bias        |
//|   - RSI(14) pullback recovery above/below 40/60 zone             |
//|   - MACD(12,26,9) H1 histogram turns positive/negative           |
//|   - ATR(14) for dynamic SL and TP placement (1:2 R:R)            |
//|  Returns: +1=Buy, -1=Sell, 0=NoTrade                             |
//|  ══════════════════════════════════════════════════════════════   |
//+------------------------------------------------------------------+
int CheckSwingEntry()
  {
   if(!InpEnableSwing) return 0;
   if(handleH1_EMA21 == INVALID_HANDLE) return 0;

//── H1 TRIPLE EMA TREND ALIGNMENT ────────────────────────────────
   double h1ema21[], h1ema50[], h1ema200[];
   ArraySetAsSeries(h1ema21,  true);
   ArraySetAsSeries(h1ema50,  true);
   ArraySetAsSeries(h1ema200, true);

   if(CopyBuffer(handleH1_EMA21,  0, 0, 3, h1ema21)  < 3) return 0;
   if(CopyBuffer(handleH1_EMA50,  0, 0, 3, h1ema50)  < 3) return 0;
   if(CopyBuffer(handleH1_EMA200, 0, 0, 3, h1ema200) < 3) return 0;

   // Use bar[1] (last confirmed closed H1 bar) for all comparisons
   double e21 = h1ema21[1], e50 = h1ema50[1], e200 = h1ema200[1];

   // Bullish stacked alignment: EMA21 > EMA50 > EMA200
   bool bullishStack = (e21 > e50 && e50 > e200);
   // Bearish stacked alignment: EMA21 < EMA50 < EMA200
   bool bearishStack = (e21 < e50 && e50 < e200);

   if(!bullishStack && !bearishStack) return 0; // No clean trend structure

//── H1 RSI PULLBACK RECOVERY ─────────────────────────────────────
//   For BUY: RSI was in oversold zone (< 40) and is now recovering above it
//   For SELL: RSI was in overbought zone (> 60) and is now dropping below it
//   This catches pullback entries in the trend direction (not tops/bottoms)
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleH1_RSI, 0, 0, 3, rsi) < 3) return 0;

   // RSI recovery from oversold (buy in uptrend pullback)
   bool rsiBullRecovery = (rsi[1] > InpH1_RSIOversold) && (rsi[2] <= InpH1_RSIOversold);
   // RSI rejection from overbought (sell in downtrend pullback)
   bool rsiBearRejection = (rsi[1] < InpH1_RSIOverbought) && (rsi[2] >= InpH1_RSIOverbought);

//── H1 MACD CONFIRMATION ─────────────────────────────────────────
//   MACD histogram crosses from negative to positive for buy (momentum aligned)
//   MACD histogram crosses from positive to negative for sell
   double h1macdMain[], h1macdSig[];
   ArraySetAsSeries(h1macdMain, true);
   ArraySetAsSeries(h1macdSig,  true);
   if(CopyBuffer(handleH1_MACD, 0, 0, 3, h1macdMain) < 3) return 0;
   if(CopyBuffer(handleH1_MACD, 1, 0, 3, h1macdSig)  < 3) return 0;

   // Bullish cross: MACD crossed above signal line
   bool macdBullCross = (h1macdMain[1] > h1macdSig[1]) && (h1macdMain[2] <= h1macdSig[2]);
   // Bearish cross: MACD crossed below signal line
   bool macdBearCross = (h1macdMain[1] < h1macdSig[1]) && (h1macdMain[2] >= h1macdSig[2]);

//── COMBINE ALL CONDITIONS ────────────────────────────────────────
   // SWING BUY: Bullish EMA stack + RSI recovering from oversold + MACD bullish cross
   if(bullishStack && rsiBullRecovery && macdBullCross) return  1;

   // SWING SELL: Bearish EMA stack + RSI rejected from overbought + MACD bearish cross
   if(bearishStack && rsiBearRejection && macdBearCross) return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//|  ENGINE 2: EXECUTE SWING BUY                                     |
//|  SL = entry - (ATR × InpH1_SL_ATR_Multi)                        |
//|  TP = entry + (ATR × InpH1_TP_ATR_Multi)   → 1:2 R:R default    |
//+------------------------------------------------------------------+
void ExecuteSwingBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) return;

//--- Get ATR for dynamic SL/TP sizing
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleH1_ATR, 0, 0, 2, atr) < 2) return;
   double atrValue = atr[1]; // Last confirmed H1 ATR
   if(atrValue <= 0.0) return;

//--- Calculate SL and TP from ATR multiples
   double sl = NormalizeDouble(ask - atrValue * InpH1_SL_ATR_Multi, _Digits);
   double tp = NormalizeDouble(ask + atrValue * InpH1_TP_ATR_Multi, _Digits);

//--- Enforce broker minimum stops
   double minDist = (g_MinStopsLevel + 5) * g_PointSize;
   if((ask - sl) < minDist) sl = NormalizeDouble(ask - minDist, _Digits);
   if((tp - ask) < minDist) tp = NormalizeDouble(ask + minDist * 2, _Digits);

   if(sl >= ask) { Print("[SWING BUY] Invalid SL. Skip."); return; }

//--- Dynamic lot from swing risk %
   double lot = CalcLotFromRisk(ask - sl, InpSwingRiskPct);

   double slPips = (ask - sl) / g_PipSize;
   double tpPips = (tp - ask) / g_PipSize;

   trade.SetExpertMagicNumber(InpSwingMagic);
   bool result = trade.Buy(lot, _Symbol, ask, sl, tp,
                           StringFormat("ForgeSwing-BUY|ATR%.1f|RR%.1f", atrValue / g_PipSize, tpPips / slPips));
   if(result)
      PrintFormat("[SWING BUY] Lot=%.2f | Ask=%.5f | SL=%.5f (%.1fpip) | TP=%.5f (%.1fpip) | R:R=1:%.1f | Ticket=%I64u",
                  lot, ask, sl, slPips, tp, tpPips, tpPips / slPips, trade.ResultOrder());
   else
      PrintFormat("[SWING BUY ERROR] %d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//|  ENGINE 2: EXECUTE SWING SELL                                    |
//+------------------------------------------------------------------+
void ExecuteSwingSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleH1_ATR, 0, 0, 2, atr) < 2) return;
   double atrValue = atr[1];
   if(atrValue <= 0.0) return;

   double sl = NormalizeDouble(bid + atrValue * InpH1_SL_ATR_Multi, _Digits);
   double tp = NormalizeDouble(bid - atrValue * InpH1_TP_ATR_Multi, _Digits);

   double minDist = (g_MinStopsLevel + 5) * g_PointSize;
   if((sl - bid) < minDist) sl = NormalizeDouble(bid + minDist, _Digits);
   if((bid - tp) < minDist) tp = NormalizeDouble(bid - minDist * 2, _Digits);

   if(sl <= bid) { Print("[SWING SELL] Invalid SL. Skip."); return; }

   double lot = CalcLotFromRisk(sl - bid, InpSwingRiskPct);

   double slPips = (sl - bid) / g_PipSize;
   double tpPips = (bid - tp) / g_PipSize;

   trade.SetExpertMagicNumber(InpSwingMagic);
   bool result = trade.Sell(lot, _Symbol, bid, sl, tp,
                            StringFormat("ForgeSwing-SELL|ATR%.1f|RR%.1f", atrValue / g_PipSize, tpPips / slPips));
   if(result)
      PrintFormat("[SWING SELL] Lot=%.2f | Bid=%.5f | SL=%.5f (%.1fpip) | TP=%.5f (%.1fpip) | R:R=1:%.1f | Ticket=%I64u",
                  lot, bid, sl, slPips, tp, tpPips, tpPips / slPips, trade.ResultOrder());
   else
      PrintFormat("[SWING SELL ERROR] %d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//|  ══════════════════════════════════════════════════════════════   |
//|  MODULE 5: UNIFIED POSITION MANAGER                              |
//|  Handles ALL open positions regardless of engine (scalper/swing) |
//|  Logic differs based on magic number:                            |
//|   Scalper: tighter breakeven/trail, MACD zero-line exit          |
//|   Swing:   wider breakeven/trail, TP already set (ATR-based)     |
//|  NOTE (FIX 3): This is now the ONLY position manager. The old    |
//|  ManagePosition() function has been completely removed.          |
//|  ══════════════════════════════════════════════════════════════   |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
//--- Pre-load M1 MACD for scalper emergency exit logic
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);
   bool macdDataOK = (CopyBuffer(handleMACD_M1, 0, 0, 3, macdMain)   >= 3 &&
                      CopyBuffer(handleMACD_M1, 1, 0, 3, macdSignal) >= 3);

   int totalPos = PositionsTotal();
   for(int i = totalPos - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol)        continue;

      int magic = (int)posInfo.Magic();
      // Only manage our own trades
      if(magic != InpScalperMagic && magic != InpSwingMagic) continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      ENUM_POSITION_TYPE posType = posInfo.PositionType();

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0) continue;

      double profitPips = (posType == POSITION_TYPE_BUY)
                         ? (bid - openPrice) / g_PipSize
                         : (openPrice - ask) / g_PipSize;

      //─── SCALPER-SPECIFIC: MACD ZERO-LINE EMERGENCY EXIT ───────────
      // Close scalper positions early if MACD crosses zero against the position
      // while still in profit. Swing trades have their own TP — skip this.
      if(magic == InpScalperMagic && macdDataOK)
        {
         bool crossedBearish = (macdMain[1] < 0.0) && (macdMain[2] >= 0.0);
         bool crossedBullish = (macdMain[1] > 0.0) && (macdMain[2] <= 0.0);
         bool againstPos = (posType == POSITION_TYPE_BUY  && crossedBearish) ||
                           (posType == POSITION_TYPE_SELL && crossedBullish);

         if(againstPos && profitPips > 0.0)
           {
            trade.SetExpertMagicNumber(InpScalperMagic);
            if(trade.PositionClose(ticket, InpMaxSlippage))
               PrintFormat("[MACD ZERO EXIT] Scalp ticket %I64u closed at %.1f pips.", ticket, profitPips);
            continue;
           }
        }

      //─── SELECT BREAKEVEN / TRAIL PARAMETERS BY ENGINE ─────────────
      double bevenPips, bevenBuffer, trailStep;
      if(magic == InpScalperMagic)
        {
         bevenPips   = InpBreakevenPips;
         bevenBuffer = InpBreakevenBuffer;
         trailStep   = InpTrailStepPips;
        }
      else // Swing uses wider parameters
        {
         bevenPips   = InpSwingBreakeven;
         bevenBuffer = InpBreakevenBuffer * 3.0; // 3× wider buffer for swing
         trailStep   = InpSwingTrailStep;
        }

      //─── BREAKEVEN ACTIVATION ─────────────────────────────────────
      if(profitPips < bevenPips) continue; // Not yet in profit threshold

      double newSL = 0.0;
      double protectedPips = bevenBuffer;

      // Calculate progressive trail pips beyond breakeven
      double extraPips = profitPips - bevenPips;
      if(extraPips > 0.0)
         protectedPips += MathFloor(extraPips / trailStep) * trailStep;

      if(posType == POSITION_TYPE_BUY)
         newSL = openPrice + protectedPips * g_PipSize;
      else
         newSL = openPrice - protectedPips * g_PipSize;

      //─── ENFORCE MINIMUM STOPS DISTANCE ───────────────────────────
      double minDist = (g_MinStopsLevel + 5) * g_PointSize;
      if(posType == POSITION_TYPE_BUY  && (bid - newSL) < minDist) newSL = bid - minDist;
      if(posType == POSITION_TYPE_SELL && (newSL - ask) < minDist) newSL = ask + minDist;
      newSL = NormalizeDouble(newSL, _Digits);

      //─── ONLY MODIFY IF THE NEW SL IS ACTUALLY BETTER ─────────────
      bool shouldModify = false;
      if(posType == POSITION_TYPE_BUY)
         shouldModify = (currentSL < newSL - g_PointSize);  // New SL is higher (better for buy)
      else
         shouldModify = (currentSL == 0.0 || currentSL > newSL + g_PointSize); // New SL is lower

      if(shouldModify)
        {
         trade.SetExpertMagicNumber(magic);
         if(trade.PositionModify(ticket, newSL, currentTP))
            PrintFormat("[TRAIL] Ticket %I64u [%s] SL→%.5f | Profit=%.1f pips | Protected=%.1f pips",
                        ticket, (magic == InpScalperMagic ? "SCALP" : "SWING"),
                        newSL, profitPips, protectedPips);
        }
     }
  }

//+------------------------------------------------------------------+
//|  MODULE 6: NEWS CALENDAR SCAN                                    |
//|  Outputs: newsBlackout and straddleWindow flags                  |
//+------------------------------------------------------------------+
void CheckNewsCalendar(bool &newsBlackout, bool &straddleWindow)
  {
   newsBlackout   = false;
   straddleWindow = false;

   datetime now       = TimeCurrent();
   datetime scanStart = now - (InpNewsPostMinutes + 1) * 60;
   datetime scanEnd   = now + (InpNewsPreMinutes  + 1) * 60;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, scanStart, scanEnd, "USD");
   if(count <= 0) return;

   for(int i = 0; i < count; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)  continue;

      datetime eventTime  = values[i].time;
      long secToEvent    = (long)(eventTime - now);
      long secAfterEvent = (long)(now - eventTime);

      // Pre-news blackout
      if(secToEvent > 0 && secToEvent <= InpNewsPreMinutes * 60)
        { newsBlackout = true; g_NewsEventTimestamp = eventTime; }

      // Post-news blackout
      if(secAfterEvent >= 0 && secAfterEvent <= InpNewsPostMinutes * 60)
         newsBlackout = true;

      // Straddle window (2 minutes before event)
      if(secToEvent > 0 && secToEvent <= InpStraddleMinutes * 60)
        { straddleWindow = true; g_NewsEventTimestamp = eventTime; }
     }
  }

//+------------------------------------------------------------------+
//|  MODULE 6: NETLESS STRADDLE PLACEMENT (OrderSend version)        |
//|  Atomic: if either leg fails, the other is immediately cancelled |
//+------------------------------------------------------------------+
void PlaceNetlessStraddle(datetime eventTime)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   double mid  = (ask + bid) / 2.0;
   double dist = InpStraddlePips * g_PipSize;

   double buyStopPrice  = NormalizeDouble(mid + dist, _Digits);
   double sellStopPrice = NormalizeDouble(mid - dist, _Digits);

   double minDist = (g_MinStopsLevel + 10) * g_PointSize;
   if(buyStopPrice  - ask < minDist) buyStopPrice  = NormalizeDouble(ask + minDist, _Digits);
   if(bid - sellStopPrice < minDist) sellStopPrice = NormalizeDouble(bid - minDist, _Digits);

   datetime expiry = eventTime + InpStraddleExpiry * 60;
   double lot      = CalcLotFromRisk(InpMaxSLPips * g_PipSize, InpScalperRiskPct);

   MqlTradeRequest reqB, reqS;
   MqlTradeResult  resB, resS;
   ZeroMemory(reqB); ZeroMemory(reqS); ZeroMemory(resB); ZeroMemory(resS);

   // BUY STOP leg
   reqB.action       = TRADE_ACTION_PENDING;
   reqB.symbol       = _Symbol;
   reqB.magic        = InpScalperMagic;
   reqB.volume       = lot;
   reqB.type         = ORDER_TYPE_BUY_STOP;
   reqB.price        = buyStopPrice;
   reqB.sl           = NormalizeDouble(buyStopPrice - InpMaxSLPips * g_PipSize, _Digits);
   reqB.tp           = 0.0;
   reqB.deviation    = InpMaxSlippage;
   reqB.type_filling = ORDER_FILLING_RETURN;
   reqB.type_time    = ORDER_TIME_SPECIFIED;
   reqB.expiration   = expiry;
   reqB.comment      = "Straddle-BUY";

   // SELL STOP leg
   reqS.action       = TRADE_ACTION_PENDING;
   reqS.symbol       = _Symbol;
   reqS.magic        = InpScalperMagic;
   reqS.volume       = lot;
   reqS.type         = ORDER_TYPE_SELL_STOP;
   reqS.price        = sellStopPrice;
   reqS.sl           = NormalizeDouble(sellStopPrice + InpMaxSLPips * g_PipSize, _Digits);
   reqS.tp           = 0.0;
   reqS.deviation    = InpMaxSlippage;
   reqS.type_filling = ORDER_FILLING_RETURN;
   reqS.type_time    = ORDER_TIME_SPECIFIED;
   reqS.expiration   = expiry;
   reqS.comment      = "Straddle-SELL";

   bool bPlaced = OrderSend(reqB, resB) &&
                  (resB.retcode == TRADE_RETCODE_DONE || resB.retcode == TRADE_RETCODE_PLACED);
   bool sPlaced = OrderSend(reqS, resS) &&
                  (resS.retcode == TRADE_RETCODE_DONE || resS.retcode == TRADE_RETCODE_PLACED);

//--- Netless rule: if either leg failed, cancel both
   if(!(bPlaced && sPlaced))
     {
      if(resB.order > 0) CancelPendingByTicket(resB.order);
      if(resS.order > 0) CancelPendingByTicket(resS.order);
      PrintFormat("[STRADDLE ERROR] Netless rollback. Buy ret=%d | Sell ret=%d",
                  resB.retcode, resS.retcode);
      return;
     }

   g_StraddleBuyTicket  = resB.order;
   g_StraddleSellTicket = resS.order;
   g_StraddlePlaced     = true;
   g_StraddlePlacedAt   = TimeCurrent();
   g_NewsEventTimestamp = eventTime;

   PrintFormat("[STRADDLE] Buy=%I64u @ %.5f | Sell=%I64u @ %.5f | Event=%s",
               g_StraddleBuyTicket, buyStopPrice,
               g_StraddleSellTicket, sellStopPrice,
               TimeToString(eventTime));
  }

//+------------------------------------------------------------------+
//|  MODULE 6: STRADDLE EXPIRY MANAGER                               |
//+------------------------------------------------------------------+
void ManageStraddleExpiry()
  {
   if(!g_StraddlePlaced || g_NewsEventTimestamp == 0) return;

   long secAfterNews = (long)(TimeCurrent() - g_NewsEventTimestamp);
   if(secAfterNews < InpStraddleExpiry * 60) return;

   PrintFormat("[STRADDLE EXPIRY] %d min elapsed. Cancelling untriggered leg(s).", InpStraddleExpiry);

   if(g_StraddleBuyTicket > 0 && OrderSelect(g_StraddleBuyTicket))
     {
      CancelPendingByTicket(g_StraddleBuyTicket);
      g_StraddleBuyTicket = 0;
     }
   if(g_StraddleSellTicket > 0 && OrderSelect(g_StraddleSellTicket))
     {
      CancelPendingByTicket(g_StraddleSellTicket);
      g_StraddleSellTicket = 0;
     }

   g_StraddlePlaced     = false;
   g_StraddlePlacedAt   = 0;
   g_NewsEventTimestamp = 0;
  }

//+------------------------------------------------------------------+
//|  MODULE 1: HARVEST TARGET CHECKER                                |
//|  At each milestone: notify, lock new entries, instruct user      |
//+------------------------------------------------------------------+
void CheckHarvestTargets(double equity)
  {
   if(!g_HarvestLevel1Hit && equity >= InpHarvestTarget1)
     {
      g_HarvestLevel1Hit = true;
      g_TradingLocked    = true;
      string msg = StringFormat("TARGET 1 HIT: Equity $%.2f | Withdraw $25 → Leave $140 → Restart EA", equity);
      Print("[HARVEST-1] " + msg);
      SendNotification("💰 " + msg);
     }
   if(!g_HarvestLevel2Hit && equity >= InpHarvestTarget2)
     {
      g_HarvestLevel2Hit = true;
      g_TradingLocked    = true;
      string msg = StringFormat("TARGET 2 HIT: Equity $%.2f | Withdraw $35 → Leave $175 → Restart EA", equity);
      Print("[HARVEST-2] " + msg);
      SendNotification("💰 " + msg);
     }
   if(!g_HarvestLevel3Hit && equity >= InpHarvestTarget3)
     {
      g_HarvestLevel3Hit = true;
      g_TradingLocked    = true;
      string msg = StringFormat("TARGET 3 HIT: Equity $%.2f | Withdraw $45 → Leave $217 → Restart EA", equity);
      Print("[HARVEST-3] " + msg);
      SendNotification("💰 " + msg);
     }
  }

//+------------------------------------------------------------------+
//|  MODULE 7: SESSION FILTER (FIX 4)                                |
//|  Returns true if current GMT time is within trading session      |
//|  Default: 08:00–17:00 GMT (London open through NY midday)        |
//|  This eliminates low-liquidity Asian session noise on M1.        |
//+------------------------------------------------------------------+
bool IsInSession()
  {
   if(!InpEnableSession) return true; // Filter disabled — always trade

   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt); // Use GMT time for consistency across brokers
   int hour = dt.hour;

   // Allow trading within session window
   if(hour >= InpSessionStartHour && hour < InpSessionEndHour)
      return true;

   return false;
  }

//+------------------------------------------------------------------+
//|  DYNAMIC LOT SIZE CALCULATOR (FIX 5)                             |
//|  Calculates lot size based on % equity risk and SL distance      |
//|  Formula: Lots = (Equity × RiskPct%) / (SL_price × TickValue)   |
//+------------------------------------------------------------------+
double CalcLotFromRisk(double slPriceDistance, double riskPct)
  {
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPct / 100.0);  // Dollar risk amount

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || slPriceDistance <= 0.0)
      return InpMinLotSize;

   // Convert SL distance to ticks, then to dollar loss per lot
   double ticksInSL   = slPriceDistance / tickSize;
   double dollarPerLot = ticksInSL * tickValue;
   if(dollarPerLot <= 0.0) return InpMinLotSize;

   double rawLots = riskAmount / dollarPerLot;

   // Normalize to broker's lot step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0) rawLots = MathFloor(rawLots / lotStep) * lotStep;

   // Clamp within [Min, Max] bounds
   rawLots = MathMax(rawLots, InpMinLotSize);
   rawLots = MathMin(rawLots, InpMaxLotSize);

   return NormalizeDouble(rawLots, 2);
  }

//+------------------------------------------------------------------+
//|  UTILITY: COUNT OPEN POSITIONS BY MAGIC NUMBER                   |
//+------------------------------------------------------------------+
int CountPositionsByMagic(int magicNumber)
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol)        continue;
      if((int)posInfo.Magic() != magicNumber) continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//|  UTILITY: CLOSE ALL POSITIONS (Emergency Use)                    |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   Print("[EMERGENCY CLOSE] Flattening all positions...");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      ulong ticket = posInfo.Ticket();
      trade.PositionClose(ticket, InpMaxSlippage);
     }
  }

//+------------------------------------------------------------------+
//|  UTILITY: CANCEL ALL PENDING ORDERS FOR THIS EA                  |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol) continue;
      if(orderInfo.Magic() != InpScalperMagic && orderInfo.Magic() != InpSwingMagic) continue;
      CancelPendingByTicket(orderInfo.Ticket());
     }
  }

//+------------------------------------------------------------------+
//|  UTILITY: CANCEL A SINGLE PENDING ORDER BY TICKET                |
//+------------------------------------------------------------------+
bool CancelPendingByTicket(ulong orderTicket)
  {
   if(orderTicket == 0) return false;
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_REMOVE;
   req.order  = orderTicket;
   req.symbol = _Symbol;
   if(!OrderSend(req, res)) return false;
   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
//|  UTILITY: CHART STATUS COMMENT                                   |
//+------------------------------------------------------------------+
void UpdateChartComment(double equity, long spread)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double margin  = AccountInfoDouble(ACCOUNT_MARGIN);
   int    scalps  = CountPositionsByMagic(InpScalperMagic);
   int    swings  = CountPositionsByMagic(InpSwingMagic);

   string status = g_EmergencyShutdown ? "⛔ EMERGENCY HALT" :
                   g_TradingLocked     ? "🔒 HARVEST LOCKED" :
                   !IsInSession()      ? "🌙 OUTSIDE SESSION" :
                                         "✅ DUAL-ENGINE ACTIVE";

   string commentText = StringFormat(
     "═══ ForgeScalper v2.0 ═══════════════\n"
     "Status   : %s\n"
     "Equity   : $%.2f  |  Balance: $%.2f\n"
     "Spread   : %d pts  |  Margin : $%.2f\n"
     "───────────────────────────────────\n"
     "Engine 1 [M1 Scalper] : %d position(s)\n"
     "Engine 2 [H1 Swing]   : %d position(s)\n"
     "Straddle Active       : %s\n"
     "───────────────────────────────────\n"
     "Hard Floor : $%.2f\n"
     "Harvest 1  : $%.2f  [%s]\n"
     "Harvest 2  : $%.2f  [%s]\n"
     "Harvest 3  : $%.2f  [%s]\n"
     "News Guard : %s\n"
     "═══════════════════════════════════",
     status,
     equity, balance,
     spread, margin,
     scalps,
     swings,
     g_StraddlePlaced ? "YES — Legs active" : "None",
     InpHardFloorEquity,
     InpHarvestTarget1, g_HarvestLevel1Hit ? "✓ HIT" : "Pending",
     InpHarvestTarget2, g_HarvestLevel2Hit ? "✓ HIT" : "Pending",
     InpHarvestTarget3, g_HarvestLevel3Hit ? "✓ HIT" : "Pending",
     InpEnableNewsFilter ? "ON" : "OFF"
   );
   Comment(commentText);
  }

//+------------------------------------------------------------------+
//|  END OF EXPERT ADVISOR — ForgeScalper v2.0                       |
//+------------------------------------------------------------------+