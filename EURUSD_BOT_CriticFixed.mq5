//+------------------------------------------------------------------+
//|                            Guardian_EURUSD_v2.mq5                |
//|           Capital Preservation EA — Patched & Fully Merged       |
//|  PATCH SET v2 INTEGRATED:                                        |
//|   P1: USC-safe lot sizing, strict floor() truncation, hard abort |
//|   P2: 30-period CMI regime detection (SWING vs TREND)           |
//|   P3: M1 microtrading layer (4-indicator confluence) for TREND   |
//+------------------------------------------------------------------+
#property copyright "Capital Preservation Scalper v2.0"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//=== INPUT PARAMETERS ==============================================

input group "=== BASIC SETTINGS ==="
input int    MagicNumber               = 100501;
input string TradeComment              = "CapPreserve";

input group "=== RISK MANAGEMENT ==="
input double RiskPercentPerTrade       = 1.0;
input int    MaxTradesPerDay           = 8;
input double MaxDailyLossPercent       = 2.0;
input double MaxWeeklyLossPercent      = 5.0;
input double WeeklyProfitTargetPercent = 3.0;

input group "=== EQUITY RANGE ALERT ==="
input double MinEquityRange            = 10.0;
input double MaxEquityRange            = 500.0;

input group "=== WITHDRAWAL DETECTION ==="
input double WithdrawalThresholdPercent= 25.0;

input group "=== SPREAD FILTERS ==="
input int    PreferredSpreadPoints     = 15;
input int    MaxSpreadPoints           = 25;
input int    MaxAllowedSpreadPoints    = 30;
input int    HighSpreadMinutes         = 15;
input int    SpreadPauseMinutes        = 60;

input group "=== STRATEGY SETTINGS ==="
input ENUM_TIMEFRAMES EMAPeriodTF      = PERIOD_H1;
input int    EMAPeriod                 = 100;
input int    RSIPeriod                 = 14;
input int    RSIOverbought             = 70;
input int    RSIOversold               = 30;

input group "=== POSITION SIZING ==="
input double StopLossPips              = 15.0;
input double TakeProfitPips            = 20.0;
input double MinLotSize                = 0.01;

input group "=== TRAILING STOP SETTINGS ==="
input bool   EnableTrailingStop        = true;
input int    TrailingStartPips         = 12;
input int    TrailingDistPips          = 5;
input int    TrailingStepPips          = 3;

input group "=== LOSS HANDLING ==="
input int    ConsecutiveLossLimit      = 3;
input int    PauseAfterLossMinutes     = 90;

input group "=== EXECUTION SAFETY ==="
input double MinFreeMarginPercent      = 150.0;
input int    TargetStabilityMinutes    = 5;
input int    MaxSlippagePoints         = 5;
input double MarginBufferPercent       = 200.0;
input int    MinSecondsBetweenTrades   = 120;
input bool   RequireManualResetAfterFloor = true;
input bool   EmergencyStop             = false;
input bool   EnableNewsFilter          = true;
input int    NewsPauseMinutesBefore    = 60;
input int    NewsPauseMinutesAfter     = 60;
input bool   IncludeMediumImpact       = false;

input group "=== EMERGENCY PROTECTION ==="
input double MaxEquityDrawdownPercent  = 25.0;
input int    MaxConsecutiveErrors      = 5;
input bool   SoftRearmAllowed          = true;
input int    SoftRearmCooldownMinutes  = 30;

input group "=== SMALL ACCOUNT GROWTH MODE ==="
input bool   EnableSmallAccountMode    = true;
input double SmallAccountThreshold     = 100.0;
input double SmallAccountExitThreshold = 120.0;
input double SmallAccountRiskPercent   = 1.0;
input int    SmallAccountMaxTrades     = 6;
input double SmallAccountDailyLoss     = 5.0;
input double SmallAccountWeeklyLoss    = 10.0;
input double SmallAccountMinWithdrawal = 15.0;

input group "=== TEST AND DEBUG MODE ==="
input bool   EnableTestMode            = false;
input bool   DisableTrendFilter        = false;
input bool   ShowAllConditions         = true;

//=== GLOBAL VARIABLES ==============================================

CTrade   trade;
datetime lastTradeTime         = 0;
datetime pauseUntil            = 0;
datetime weeklyResetTime       = 0;
datetime dailyResetTime        = 0;

int      consecutiveLosses     = 0;
int      tradesThisDay         = 0;
double   dailyStartBalance     = 0;
double   weeklyStartBalance    = 0;
double   lastKnownBalance      = 0;

bool     weeklyTargetReached   = false;
bool     dailyLossHit          = false;
bool     weeklyLossHit         = false;
bool     conservativeMode      = false;

double   activeRiskPercent     = 0;
int      activeMaxTradesPerDay = 0;

int      highSpreadCounter     = 0;
datetime lastSpreadCheck       = 0;

int      emaHandle             = INVALID_HANDLE;
int      rsiHandle             = INVALID_HANDLE;
int      atrHandle             = INVALID_HANDLE;

datetime lastHistoryCheck      = 0;
int      lastHistoryTotal      = 0;
datetime weeklyTargetReachedTime = 0;
datetime lastOrderAttempt      = 0;

double   conservativeModeThreshold = 0;

int      lastSpread            = 0;
datetime spreadSpikeDetectedTime = 0;
bool     accountFloorHit       = false;
datetime lastDiagnosticPrint   = 0;

int      brokerStopsLevel      = 0;
int      brokerFreezeLevel     = 0;
double   brokerMinLot          = 0;
double   brokerMaxLot          = 0;
double   brokerLotStep         = 0;
double   adaptedStopLoss       = 0;
double   adaptedTakeProfit     = 0;

bool     emergencyStopActive   = false;
double   initialEquity         = 0;
int      consecutiveErrors     = 0;
datetime lastErrorTime         = 0;

bool     softRearmActive       = false;
datetime accountFloorHitTime   = 0;
bool     ultraConservativeMode = false;

bool     smallAccountModeActive = false;
double   originalRiskPercent   = 0;
int      originalMaxTrades     = 0;
double   originalDailyLoss     = 0;
double   originalWeeklyLoss    = 0;
datetime lastSmallAccountCheck = 0;

// PATCH 2: CMI regime state
string   g_marketRegime        = "UNDEFINED";
double   g_lastCMI             = 0.0;
datetime g_lastCMILog          = 0;

// PATCH 3: M1 microtrading indicator handles
int      g_m1_ema18Handle      = INVALID_HANDLE;
int      g_m1_ema3Handle       = INVALID_HANDLE;
int      g_m1_macdHandle       = INVALID_HANDLE;
int      g_m1_rsi14Handle      = INVALID_HANDLE;

//=== UTILITY FUNCTION PROTOTYPES (forward declarations) ===========
datetime GetDayStart();
datetime GetWeekStart();
datetime GetCurrentMinute();
void     NotifyUser(string message);
double   GetEffectiveDailyLossLimit();
double   GetEffectiveWeeklyLossLimit();
double   GetEffectiveMinWithdrawal();
void     CheckAndApplySmallAccountMode();
void     CheckProtectionLimits();
void     RecordExecutionError();
void     ActivateEmergencyStop(string reason);
bool     InitializeMicrotradingIndicators();
void     DeinitMicrotradingIndicators();
double   CalculateCMI();
int      GetM1MicrotradingSignal();
void     CheckSoftRearmConditions();
void     ActivateSoftRearm();

//=== ONINIT ========================================================

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(MaxSlippagePoints);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    trade.SetAsyncMode(false);

    ENUM_TIMEFRAMES tf = _Period;
    if(tf < PERIOD_M5)
    {
        Alert("CRITICAL: Run on M5 or higher. Current: ", EnumToString(tf));
        return INIT_FAILED;
    }
    if(tf != PERIOD_M5)
        Print("NOTE: Optimised for M5. Current: ", EnumToString(tf));
    Print("EA Timeframe: ", EnumToString(tf));

    if(StringFind(_Symbol, "EURUSD") < 0)
    {
        Alert("ERROR: EURUSD only. Symbol: ", _Symbol);
        return INIT_FAILED;
    }

    Print("========== BROKER AUTO-ADAPTATION ==========");
    brokerStopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    brokerFreezeLevel= (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

    long execMode = 0;
    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE, execMode))
        execMode = SYMBOL_TRADE_EXECUTION_MARKET;

    brokerMinLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    brokerMaxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    brokerLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double pipValue = (digits == 3 || digits == 5) ? point * 10.0 : point;

    Print("Vol Min:", brokerMinLot, " Max:", brokerMaxLot, " Step:", brokerLotStep);

    double minStopPips = (brokerStopsLevel * point) / pipValue;
    adaptedStopLoss    = StopLossPips;
    adaptedTakeProfit  = TakeProfitPips;

    if(StopLossPips < minStopPips)
    {
        adaptedStopLoss = minStopPips + 2.0;
        Alert("SL adapted to ", adaptedStopLoss, " pips");
    }
    if(TakeProfitPips < minStopPips)
    {
        adaptedTakeProfit = minStopPips + 2.0;
        Alert("TP adapted to ", adaptedTakeProfit, " pips");
    }

    if(brokerMinLot <= 0 || brokerMaxLot <= 0 || brokerLotStep <= 0)
    {
        Alert("CRITICAL: Invalid volume params Min:", brokerMinLot, " Max:", brokerMaxLot);
        return INIT_FAILED;
    }
    Print("Adapted SL:", adaptedStopLoss, " TP:", adaptedTakeProfit);
    Print("============================================");

    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
    { Alert("ERROR: ", _Symbol, " trading disabled."); return INIT_FAILED; }

    if(!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
    {
        if(!SymbolSelect(_Symbol, true))
        { Alert("ERROR: Cannot select ", _Symbol); return INIT_FAILED; }
    }

    int fillMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((fillMode & SYMBOL_FILLING_IOC) == 0)
    {
        Alert("WARNING: IOC unsupported — using FOK.");
        trade.SetTypeFilling(ORDER_FILLING_FOK);
    }

    int bars = Bars(_Symbol, EMAPeriodTF);
    if(bars < EMAPeriod + 10)
    { Alert("ERROR: Insufficient history (", bars, " bars)."); return INIT_FAILED; }

    double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickVal <= 0 || tickSize <= 0)
    { Alert("ERROR: Bad tick params."); return INIT_FAILED; }

    emaHandle = iMA(_Symbol, EMAPeriodTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_H1, 14);

    if(emaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
    { Print("ERROR: Core indicator handles failed."); return INIT_FAILED; }

    dailyStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
    weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    lastKnownBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
    dailyResetTime     = GetDayStart();
    weeklyResetTime    = GetWeekStart();
    initialEquity      = AccountInfoDouble(ACCOUNT_EQUITY);

    HistorySelect(0, TimeCurrent());
    lastHistoryTotal = HistoryDealsTotal();
    lastHistoryCheck = TimeCurrent();

    activeRiskPercent     = RiskPercentPerTrade;
    activeMaxTradesPerDay = MaxTradesPerDay;

    originalRiskPercent = RiskPercentPerTrade;
    originalMaxTrades   = MaxTradesPerDay;
    originalDailyLoss   = MaxDailyLossPercent;
    originalWeeklyLoss  = MaxWeeklyLossPercent;

    if(EnableSmallAccountMode)
        CheckAndApplySmallAccountMode();
    else
    { smallAccountModeActive = false; Print("Small Account Mode: DISABLED"); }

    // PATCH 3: Init M1 microtrading layer (non-fatal if deferred)
    if(!InitializeMicrotradingIndicators())
        Print("NOTE: M1 indicator init deferred. Trend-regime M1 layer offline until data warms.");

    Print("=== Guardian EURUSD v2 Initialised ===");
    Print("Balance: $", DoubleToString(dailyStartBalance, 2));
    Print("Risk: ", DoubleToString(RiskPercentPerTrade,2), "% | CMI regime: ACTIVE | M1 layer: ACTIVE");
    return INIT_SUCCEEDED;
}

//=== ONDEINIT ======================================================

void OnDeinit(const int reason)
{
    DeinitMicrotradingIndicators();
    if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    Print("=== EA Deinitialized ===");
}

//=== ONTICK ========================================================

void OnTick()
{
    CheckAccountFloor();
    if(accountFloorHit) return;

    PrintDailyDiagnostic();
    CheckTimeResets();

    if(EnableSmallAccountMode) CheckAndApplySmallAccountMode();
    ManageConservativeMode();
    CheckClosedPosition();
    DetectSpreadSpike();

    if(!ShouldTrade())          return;
    if(!CheckSpreadConditions()) return;

    if(PositionSelect(_Symbol))
    {
        ManagePosition();
        ApplyTrailingStop();
        return;
    }

    if(!CheckExecutionCooldown()) return;
    CheckForEntry();
}

//=== ONTRADE_TRANSACTION ===========================================

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    ulong dealTicket = trans.deal;
    if(dealTicket == 0 || !HistoryDealSelect(dealTicket)) return;

    long   dealType   = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    double dealProfit = HistoryDealGetDouble (dealTicket, DEAL_PROFIT);
    double dealVolume = HistoryDealGetDouble (dealTicket, DEAL_VOLUME);
    string dealSymbol = HistoryDealGetString (dealTicket, DEAL_SYMBOL);
    long   dealMagic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);

    if(dealType == DEAL_TYPE_BALANCE)
    {
        double curBal   = AccountInfoDouble(ACCOUNT_BALANCE);
        double absAmt   = MathAbs(dealProfit);
        double minThr   = GetEffectiveMinWithdrawal();

        if(dealProfit < 0)
        {
            if(absAmt < minThr) { Print("Small withdrawal ignored ($", DoubleToString(absAmt,2), ")"); return; }
            Print("WITHDRAWAL DETECTED: $", DoubleToString(absAmt,2));
            RebalanceEAAfterBalanceChange("WITHDRAWAL", dealProfit, curBal);
        }
        else if(dealProfit > 0)
        {
            if(absAmt < minThr) { Print("Small deposit ignored ($", DoubleToString(absAmt,2), ")"); return; }
            Print("DEPOSIT DETECTED: $", DoubleToString(absAmt,2));
            RebalanceEAAfterBalanceChange("DEPOSIT", dealProfit, curBal);
        }
        return;
    }

    if(dealMagic != MagicNumber || dealSymbol != _Symbol) return;
    long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if(dealEntry != DEAL_ENTRY_OUT) return;

    if(dealProfit < 0) Print("TRADE LOSS:   $", DoubleToString(dealProfit,2));
    else               Print("TRADE PROFIT: $", DoubleToString(dealProfit,2));
}

//=== REBALANCE =====================================================

void RebalanceEAAfterBalanceChange(string opType, double amount, double newBal)
{
    Print("EA REBALANCE: ", opType, " $", DoubleToString(MathAbs(amount),2),
          " -> new balance $", DoubleToString(newBal,2));
    dailyStartBalance  = newBal; weeklyStartBalance = newBal; lastKnownBalance = newBal;
    consecutiveLosses  = 0; tradesThisDay = 0;
    dailyLossHit       = false; weeklyLossHit = false;
    weeklyTargetReached = false; weeklyTargetReachedTime = 0;
    pauseUntil         = 0;
    if(conservativeMode && newBal < MaxEquityRange)
    { conservativeMode = false; activeRiskPercent = RiskPercentPerTrade; activeMaxTradesPerDay = MaxTradesPerDay; }
    NotifyUser(opType + " ($" + DoubleToString(MathAbs(amount),2) + "). Rebalanced to $" + DoubleToString(newBal,2));
}

//=== SHOULD TRADE ==================================================

bool ShouldTrade()
{
    if(TimeCurrent() < pauseUntil)              return false;
    if(emergencyStopActive)                     return false;
    if(AccountInfoDouble(ACCOUNT_EQUITY) < MinEquityRange) return false;
    if(dailyLossHit || weeklyLossHit || weeklyTargetReached) return false;
    if(tradesThisDay >= activeMaxTradesPerDay)  return false;
    if(!IsTradingTime())                        return false;
    if(EnableNewsFilter && IsNewsEvent())       return false;
    return true;
}

//=== SAFETY CHECKS =================================================

bool CheckSlippage(ENUM_ORDER_TYPE orderType, double expectedPrice)
{
    double cp = (orderType == ORDER_TYPE_BUY) ?
                SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double slip = MathAbs(cp - expectedPrice) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(slip > MaxSlippagePoints) { Print("SAFETY: Slippage ", DoubleToString(slip,1), " pts > max ", MaxSlippagePoints); return false; }
    return true;
}

bool CheckFreeMarginBuffer(double lotSize)
{
    double freeMgn = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    double req = 0;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize, SymbolInfoDouble(_Symbol, SYMBOL_ASK), req))
    { Print("SAFETY: Margin calc failed."); return false; }
    if((freeMgn - req) < req * (MarginBufferPercent / 100.0))
    { Print("SAFETY: Margin buffer insufficient."); return false; }
    return true;
}

bool IsTradingTime()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
    if(dt.day_of_week == 1 && dt.hour < 2)          return false;
    if(dt.day_of_week == 5 && dt.hour >= 20)         return false;
    return (dt.hour >= 7 && dt.hour < 21);
}

bool CheckSpreadConditions()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double pv  = (dg == 3 || dg == 5) ? pt * 10.0 : pt;
    int    sp  = (int)((ask - bid) / pv);
    if(sp > MaxAllowedSpreadPoints) return false;
    if(sp <= MaxSpreadPoints) { highSpreadCounter = 0; return true; }
    datetime cm = GetCurrentMinute();
    if(cm != lastSpreadCheck)
    {
        highSpreadCounter++; lastSpreadCheck = cm;
        if(highSpreadCounter >= HighSpreadMinutes)
        {
            pauseUntil = MathMax(pauseUntil, TimeCurrent() + (SpreadPauseMinutes * 60));
            NotifyUser("High spread pause " + IntegerToString(SpreadPauseMinutes) + " min.");
            highSpreadCounter = 0;
        }
    }
    return false;
}

bool CheckMarginSufficiency(ENUM_ORDER_TYPE ot, double lots)
{
    double fm = AccountInfoDouble(ACCOUNT_MARGIN_FREE), req = 0;
    double pr = (ot == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(!OrderCalcMargin(ot, _Symbol, lots, pr, req)) { Print("SAFETY: Margin calc failed."); return false; }
    if(fm < req * (MinFreeMarginPercent / 100.0)) { Print("SAFETY: Insufficient margin. Free:$", DoubleToString(fm,2)); return false; }
    return true;
}

bool ValidateStopLevels(ENUM_ORDER_TYPE ot, double price, double sl, double tp)
{
    int lvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    if(lvl == 0) return true;
    double minD = lvl * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(MathAbs(price - sl) < minD) { Print("SAFETY: SL too close."); return false; }
    if(MathAbs(price - tp) < minD) { Print("SAFETY: TP too close."); return false; }
    return true;
}

//=== LEGACY TREND FILTER (kept for reference, no longer called by CheckForEntry) ===

bool IsMarketTrending()
{
    if(DisableTrendFilter) return true;
    int h50 = iMA(_Symbol, PERIOD_H1, 50,  0, MODE_EMA, PRICE_CLOSE);
    int h100= iMA(_Symbol, PERIOD_H1, 100, 0, MODE_EMA, PRICE_CLOSE);
    if(h50 == INVALID_HANDLE || h100 == INVALID_HANDLE) return true;
    double a[], b[]; ArraySetAsSeries(a, true); ArraySetAsSeries(b, true);
    if(CopyBuffer(h50,0,0,1,a)<1 || CopyBuffer(h100,0,0,1,b)<1) { IndicatorRelease(h50); IndicatorRelease(h100); return true; }
    IndicatorRelease(h50); IndicatorRelease(h100);
    double sep = MathAbs(a[0]-b[0]), avg = (a[0]+b[0])/2.0;
    return ((sep/avg)*100.0 >= 0.004);
}

//===================================================================
// PATCH 2 - CalculateCMI()
// 30-period Choppy Market Index on the current chart timeframe.
// Formula: CMI = |Close[0]-Close[29]| / (HighestHigh[30]-LowestLow[30]) * 100
// Returns [0,100]. Returns -1.0 on data error.
// CMI < 20  -> SWING (Mean Reversion)
// CMI >= 20 -> TREND (Trend Following + M1 layer)
//===================================================================

double CalculateCMI()
{
    const int P = 30;
    double cl[], hi[], lo[];
    ArraySetAsSeries(cl, true); ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true);

    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, P, cl) < P)
    {
        static datetime errLog = 0;
        if(TimeCurrent()-errLog > 60) { Print("CMI WARN: CopyClose failed. Err:", GetLastError()); errLog = TimeCurrent(); }
        return -1.0;
    }
    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, P, hi) < P || CopyLow(_Symbol, PERIOD_CURRENT, 0, P, lo) < P)
    { Print("CMI WARN: CopyHigh/CopyLow failed. Err:", GetLastError()); return -1.0; }

    double disp  = MathAbs(cl[0] - cl[P-1]);
    double range = hi[ArrayMaximum(hi,0,P)] - lo[ArrayMinimum(lo,0,P)];
    if(range <= 0.0) { Print("CMI WARN: range=0. Returning 0."); return 0.0; }

    double cmi = MathMax(0.0, MathMin(100.0, (disp/range)*100.0));

    if(TimeCurrent() - g_lastCMILog >= 60)
    {
        Print("CMI:", DoubleToString(cmi,2), " Regime:", (cmi < 20.0 ? "SWING" : "TREND"),
              " Range:", DoubleToString(range,5), " Disp:", DoubleToString(disp,5));
        g_lastCMILog = TimeCurrent();
    }
    return cmi;
}

//===================================================================
// PATCH 3a - InitializeMicrotradingIndicators()
//===================================================================

bool InitializeMicrotradingIndicators()
{
    if(Bars(_Symbol, PERIOD_M1) < 50) { Print("M1-INIT: Insufficient M1 bars. Deferring."); return false; }

    g_m1_ema18Handle = iMA(_Symbol, PERIOD_M1, 18, 0, MODE_EMA, PRICE_CLOSE);
    if(g_m1_ema18Handle == INVALID_HANDLE) { Print("M1-INIT ERROR: EMA18 failed. Err:", GetLastError()); return false; }

    g_m1_ema3Handle = iMA(_Symbol, PERIOD_M1, 3, 0, MODE_EMA, PRICE_CLOSE);
    if(g_m1_ema3Handle == INVALID_HANDLE)
    { Print("M1-INIT ERROR: EMA3 failed."); IndicatorRelease(g_m1_ema18Handle); g_m1_ema18Handle=INVALID_HANDLE; return false; }

    g_m1_macdHandle = iMACD(_Symbol, PERIOD_M1, 12, 26, 9, PRICE_CLOSE);
    if(g_m1_macdHandle == INVALID_HANDLE)
    { Print("M1-INIT ERROR: MACD failed."); IndicatorRelease(g_m1_ema18Handle); IndicatorRelease(g_m1_ema3Handle); g_m1_ema18Handle=INVALID_HANDLE; g_m1_ema3Handle=INVALID_HANDLE; return false; }

    g_m1_rsi14Handle = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);
    if(g_m1_rsi14Handle == INVALID_HANDLE)
    { Print("M1-INIT ERROR: RSI14 failed."); IndicatorRelease(g_m1_ema18Handle); IndicatorRelease(g_m1_ema3Handle); IndicatorRelease(g_m1_macdHandle); g_m1_ema18Handle=INVALID_HANDLE; g_m1_ema3Handle=INVALID_HANDLE; g_m1_macdHandle=INVALID_HANDLE; return false; }

    Print("M1-INIT OK: All 4 handles ready. EMA18=", g_m1_ema18Handle, " EMA3=", g_m1_ema3Handle, " MACD=", g_m1_macdHandle, " RSI14=", g_m1_rsi14Handle);
    return true;
}

//===================================================================
// PATCH 3b - DeinitMicrotradingIndicators()
//===================================================================

void DeinitMicrotradingIndicators()
{
    if(g_m1_ema18Handle != INVALID_HANDLE) { IndicatorRelease(g_m1_ema18Handle); g_m1_ema18Handle = INVALID_HANDLE; }
    if(g_m1_ema3Handle  != INVALID_HANDLE) { IndicatorRelease(g_m1_ema3Handle);  g_m1_ema3Handle  = INVALID_HANDLE; }
    if(g_m1_macdHandle  != INVALID_HANDLE) { IndicatorRelease(g_m1_macdHandle);  g_m1_macdHandle  = INVALID_HANDLE; }
    if(g_m1_rsi14Handle != INVALID_HANDLE) { IndicatorRelease(g_m1_rsi14Handle); g_m1_rsi14Handle = INVALID_HANDLE; }
    Print("M1-DEINIT: All M1 handles released.");
}

//===================================================================
// PATCH 3c - GetM1MicrotradingSignal()
// Four-indicator confluence on M1 timeframe.
//
// EBB midline = EMA(18) on M1  (exponential BB midline IS the EMA)
// Fast EMA    = EMA(3)  on M1
// MACD hist   = MACD(12,26,9) main-signal on M1
// RSI(14)     on M1
//
// BUY  signal: EMA3 crosses UP   through EBB18, MACD hist > 0, RSI > 50
// SELL signal: EMA3 crosses DOWN through EBB18, MACD hist < 0, RSI < 50
//
// Returns: +1=BUY  -1=SELL  0=NO SIGNAL
//===================================================================

int GetM1MicrotradingSignal()
{
    if(g_m1_ema18Handle==INVALID_HANDLE || g_m1_ema3Handle==INVALID_HANDLE ||
       g_m1_macdHandle==INVALID_HANDLE  || g_m1_rsi14Handle==INVALID_HANDLE)
    {
        Print("M1-SIG: Handles invalid — lazy re-init...");
        if(!InitializeMicrotradingIndicators()) { Print("M1-SIG: Re-init failed. NO SIGNAL."); return 0; }
    }

    double ema18[], ema3[], mMain[], mSig[], rsi[];
    ArrayResize(ema18, 2); ArrayResize(ema3, 2);
    ArrayResize(mMain, 1); ArrayResize(mSig, 1); ArrayResize(rsi, 1);
    ArraySetAsSeries(ema18, true); ArraySetAsSeries(ema3, true);
    ArraySetAsSeries(mMain, true); ArraySetAsSeries(mSig, true); ArraySetAsSeries(rsi, true);

    if(CopyBuffer(g_m1_ema18Handle, 0, 0, 2, ema18) < 2) { Print("M1-SIG WARN: EMA18 buf fail."); return 0; }
    if(CopyBuffer(g_m1_ema3Handle,  0, 0, 2, ema3)  < 2) { Print("M1-SIG WARN: EMA3  buf fail."); return 0; }
    if(CopyBuffer(g_m1_macdHandle,  0, 0, 1, mMain) < 1) { Print("M1-SIG WARN: MACD main fail."); return 0; }
    if(CopyBuffer(g_m1_macdHandle,  1, 0, 1, mSig)  < 1) { Print("M1-SIG WARN: MACD sig  fail."); return 0; }
    if(CopyBuffer(g_m1_rsi14Handle, 0, 0, 1, rsi)   < 1) { Print("M1-SIG WARN: RSI14 buf fail."); return 0; }

    // Crossover detection: [0]=current bar, [1]=previous bar
    bool aboveNow  = (ema3[0] > ema18[0]);
    bool abovePrev = (ema3[1] > ema18[1]);
    bool crossUp   = (!abovePrev &&  aboveNow);
    bool crossDown = ( abovePrev && !aboveNow);

    double hist = mMain[0] - mSig[0];
    double rsiV = rsi[0];

    bool buyS  = (crossUp   && hist > 0.0 && rsiV > 50.0);
    bool sellS = (crossDown && hist < 0.0 && rsiV < 50.0);

    if(EnableTestMode)
    {
        Print("M1-SIG: EMA3[0]=", DoubleToString(ema3[0],5), " EBB18[0]=", DoubleToString(ema18[0],5),
              " EMA3[1]=", DoubleToString(ema3[1],5), " EBB18[1]=", DoubleToString(ema18[1],5));
        Print("M1-SIG: CrossUp=", crossUp, " CrossDn=", crossDown,
              " Hist=", DoubleToString(hist,6), " RSI=", DoubleToString(rsiV,2),
              " BUY=", buyS, " SELL=", sellS);
    }

    if(buyS && sellS) { Print("M1-SIG: Conflict. NO SIGNAL."); return 0; }
    if(buyS)  return  1;
    if(sellS) return -1;
    return 0;
}

//===================================================================
// PATCH 2+3 - CheckForEntry()  [FULL REPLACEMENT]
//
// REMOVED: IsMarketTrending() static 0.03% EMA separation filter
// REMOVED: hardcoded 0.00015 EMA slope threshold (ATR-dynamic retained)
//
// ADDED:
//   CalculateCMI() for regime detection each bar
//   TREND regime (CMI>=20): H1 context + M1 four-indicator confluence
//   SWING regime (CMI<20):  Mean-reversion oversold/overbought entries
//
// COMPILE FIX: "ENUM_ORDER_TYPE = -1" was illegal MQL5 syntax.
//   Solution: use plain int sentinel (-1=none, 0=BUY, 1=SELL),
//   cast to ENUM_ORDER_TYPE ONLY at the single OpenTrade() call site.
//===================================================================

void CheckForEntry()
{
    // One-trade-per-bar guard
    static datetime lastBarTime = 0;
    datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(curBarTime != lastBarTime) lastBarTime = 0;
    if(curBarTime == lastBarTime) return;

    if(PositionSelect(_Symbol)) return;

    // STEP 1: CMI regime detection (replaces IsMarketTrending)
    double cmi = CalculateCMI();
    if(cmi < 0.0) return;
    g_lastCMI      = cmi;
    g_marketRegime = (cmi >= 20.0) ? "TREND" : "SWING";
    bool isTrend   = (cmi >= 20.0);
    bool isSwing   = !isTrend;

    // STEP 2: Gather H1 context indicators
    int hEMA = iMA(_Symbol, EMAPeriodTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(hEMA == INVALID_HANDLE) { Print("ENTRY WARN: H1 EMA handle failed."); return; }

    double emaV[], rsiV[], atrV[];
    ArrayResize(emaV, 2); ArrayResize(rsiV, 1); ArrayResize(atrV, 1);
    ArraySetAsSeries(emaV, true); ArraySetAsSeries(rsiV, true); ArraySetAsSeries(atrV, true);

    if(CopyBuffer(hEMA, 0, 0, 2, emaV) < 2) { if(EnableTestMode) Print("ENTRY WARN: EMA buf fail."); IndicatorRelease(hEMA); return; }
    if(CopyBuffer(rsiHandle, 0, 0, 1, rsiV) < 1) { if(EnableTestMode) Print("ENTRY WARN: RSI buf fail."); IndicatorRelease(hEMA); return; }

    double dynSlope = 0.00008, atrRaw = 0.0, maxDist = 0.0;
    if(CopyBuffer(atrHandle, 0, 0, 1, atrV) == 1)
    { atrRaw = atrV[0]; dynSlope = atrRaw * 0.04; maxDist = atrRaw * 1.5; }

    double curPrice  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double slope     = MathAbs(emaV[0] - emaV[1]);
    double delta     = emaV[0] - emaV[1];
    double peDist    = MathAbs(curPrice - emaV[0]);

    bool emaRising   = (delta > 0.0);
    bool emaFalling  = (delta < 0.0);
    bool aboveEMA    = (curPrice > emaV[0]);
    bool belowEMA    = (curPrice < emaV[0]);

    // STEP 3: Regime branches
    // Use int sentinel to avoid (ENUM_ORDER_TYPE)-1 compile error
    int decidedDir = -1;   // -1=no signal, 0=BUY, 1=SELL

    // ---------------------------------------------------------------
    // TREND REGIME (CMI >= 20): H1 context + M1 trigger
    // ---------------------------------------------------------------
    if(isTrend)
    {
        bool slopeOK   = (slope >= dynSlope);
        bool notChase  = (maxDist <= 0.0 || peDist <= maxDist);
        bool rsiBuy    = (rsiV[0] >= 48.0 && rsiV[0] <= 68.0);
        bool rsiSell   = (rsiV[0] >= 32.0 && rsiV[0] <= 52.0);

        bool h1Buy  = (aboveEMA && emaRising  && rsiBuy  && slopeOK && notChase);
        bool h1Sell = (belowEMA && emaFalling && rsiSell && slopeOK && notChase);

        int m1Sig = 0;
        if(h1Buy || h1Sell) m1Sig = GetM1MicrotradingSignal();

        bool tBuy  = (h1Buy  && m1Sig ==  1);
        bool tSell = (h1Sell && m1Sig == -1);

        static datetime tLog = 0;
        if(TimeCurrent()-tLog >= 60 || EnableTestMode)
        {
            if(ShowAllConditions || EnableTestMode)
            {
                Print("=== TREND CHECK (CMI=", DoubleToString(cmi,1), ") ===");
                Print("EMA=", DoubleToString(emaV[0],5), " Slope=", DoubleToString(slope,6), " Min=", DoubleToString(dynSlope,6));
                Print("RSI=", DoubleToString(rsiV[0],1), " H1Buy=", h1Buy, " H1Sell=", h1Sell);
                Print("M1=", (m1Sig==1?"BUY":m1Sig==-1?"SELL":"NONE"), " TrendBUY=", tBuy, " TrendSELL=", tSell);
            }
            tLog = TimeCurrent();
        }

        if(tBuy  && !tSell) decidedDir = 0;
        else if(tSell && !tBuy) decidedDir = 1;
        else if(tBuy && tSell) { Print("TREND: Conflict. NO TRADE."); IndicatorRelease(hEMA); return; }
    }

    // ---------------------------------------------------------------
    // SWING REGIME (CMI < 20): Mean Reversion
    // ---------------------------------------------------------------
    else if(isSwing)
    {
        bool emaFlat   = (slope < dynSlope);
        double oeThr   = (atrRaw > 0.0) ? atrRaw * 1.5 : 15.0 * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
        bool overext   = (peDist >= oeThr);
        bool oversold  = (rsiV[0] >= 25.0 && rsiV[0] <= 42.0);
        bool overbought= (rsiV[0] >= 58.0 && rsiV[0] <= 75.0);

        // BUY snap-back: price too far BELOW EMA, RSI oversold
        bool sBuy  = (belowEMA && overext && emaFlat && oversold);
        // SELL snap-back: price too far ABOVE EMA, RSI overbought
        bool sSell = (aboveEMA && overext && emaFlat && overbought);

        static datetime sLog = 0;
        if(TimeCurrent()-sLog >= 60 || EnableTestMode)
        {
            if(ShowAllConditions || EnableTestMode)
            {
                Print("=== SWING CHECK (CMI=", DoubleToString(cmi,1), ") ===");
                Print("Flat=", emaFlat, " Overext=", overext, " Dist=", DoubleToString(peDist,5), " Thr=", DoubleToString(oeThr,5));
                Print("RSI=", DoubleToString(rsiV[0],1), " Oversold=", oversold, " Overbought=", overbought);
                Print("SwingBUY=", sBuy, " SwingSELL=", sSell);
            }
            sLog = TimeCurrent();
        }

        if(sBuy  && !sSell) decidedDir = 0;
        else if(sSell && !sBuy) decidedDir = 1;
        else if(sBuy && sSell) { Print("SWING: Conflict. NO TRADE."); IndicatorRelease(hEMA); return; }
    }

    // STEP 4: No signal
    if(decidedDir == -1)
    {
        static datetime nsLog = 0;
        if(TimeCurrent()-nsLog >= 60)
        {
            if(!EnableTestMode) Print("Direction: NONE [", g_marketRegime, " CMI=", DoubleToString(cmi,1), "]");
            nsLog = TimeCurrent();
        }
        IndicatorRelease(hEMA);
        return;
    }

    // STEP 5: Signal confirmed
    // Cast to ENUM_ORDER_TYPE ONLY here (avoids compile error)
    ENUM_ORDER_TYPE dir = (decidedDir == 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

    Print("VALID SIGNAL: ", EnumToString(dir), " [", g_marketRegime, " CMI=", DoubleToString(cmi,1), "]",
          " Price=", DoubleToString(curPrice,5), " EMA=", DoubleToString(emaV[0],5), " RSI=", DoubleToString(rsiV[0],1));

    OpenTrade(dir);

    if(PositionSelect(_Symbol)) lastBarTime = curBarTime;

    IndicatorRelease(hEMA);
}

//=== OPEN TRADE ====================================================

void OpenTrade(ENUM_ORDER_TYPE ot)
{
    double price  = (ot == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    dg     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double pv     = (dg == 3 || dg == 5) ? pt * 10.0 : pt;

    double lots   = CalculateLotSize(StopLossPips);

    if(lots <= 0)
    { Print("CRITICAL: Lot=0 — ABORTED"); NotifyUser("CRITICAL: Lot=0. Trade blocked."); consecutiveErrors++; return; }
    if(lots > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX))
    { Print("CRITICAL: Lot > VOLUME_MAX — ABORTED"); NotifyUser("CRITICAL: Lot>max. Trade blocked."); consecutiveErrors++; return; }

    double sl = (ot == ORDER_TYPE_BUY) ? price - (adaptedStopLoss   * pv) : price + (adaptedStopLoss   * pv);
    double tp = (ot == ORDER_TYPE_BUY) ? price + (adaptedTakeProfit * pv) : price - (adaptedTakeProfit * pv);
    sl = NormalizeDouble(sl, dg); tp = NormalizeDouble(tp, dg);

    if((TimeCurrent() - lastTradeTime) < 10) { Print("SAFETY ABORT: 10s cooldown."); return; }
    if(!CheckSlippage(ot, price))            { Print("SAFETY ABORT: Slippage.");     return; }
    if(!CheckMarginSufficiency(ot, lots))    { Print("SAFETY ABORT: Margin.");        return; }
    if(!CheckFreeMarginBuffer(lots))         { Print("SAFETY ABORT: Margin buffer."); return; }
    if(!ValidateStopLevels(ot, price, sl, tp)) { Print("SAFETY ABORT: Stop levels."); return; }

    Print("=== OPENING ", EnumToString(ot), " Lot:", lots, " Entry:", price, " SL:", sl, " TP:", tp);

    if(trade.PositionOpen(_Symbol, ot, lots, price, sl, tp, TradeComment))
    {
        Print("Trade opened. Ticket:", trade.ResultOrder());
        lastTradeTime = TimeCurrent(); tradesThisDay++;
        Sleep(100); VerifyTradeIntegrity(ot, sl, tp);
        consecutiveErrors = 0;
    }
    else
    { Print("Trade FAILED. ", trade.ResultRetcodeDescription()); RecordExecutionError(); }
}

//===================================================================
// PATCH 1 - CalculateLotSize()  [FULL REPLACEMENT]
//
// USC/Cent-account aware. Key changes:
//  1. 0.50% hard cap enforced unconditionally inside this function.
//  2. Strict MathFloor() downward truncation — NO MathMax() fallback.
//  3. If truncatedLot < SYMBOL_VOLUME_MIN -> return 0 (hard abort).
//     OpenTrade() catches 0 and aborts. NO silent fallback to minLot.
//===================================================================

double CalculateLotSize(double stopLossPips)
{
    // Hard cap 0.50% — USC cent-account safety
    const double CAP = 0.50;
    double eRisk = MathMin(activeRiskPercent, CAP);
    if(activeRiskPercent > CAP)
        Print("P1-WARN: Risk capped ", DoubleToString(activeRiskPercent,3), "% -> ", CAP, "%");

    double effSL  = (adaptedStopLoss > 0.0) ? adaptedStopLoss : stopLossPips;
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity <= 0.0) { Print("P1-CRITICAL: equity=", equity, " ABORTED."); return 0.0; }

    double riskAmt = equity * (eRisk / 100.0);

    int    dg    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double pipSz = (dg == 3 || dg == 5) ? pt * 10.0 : pt;

    double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickVal <= 0.0 || tickSize <= 0.0) { Print("P1-CRITICAL: Bad tick params. ABORTED."); return 0.0; }

    double pipValPerLot = (tickVal / tickSize) * pipSz;
    if(pipValPerLot <= 0.0) { Print("P1-CRITICAL: pipValPerLot=", pipValPerLot, " ABORTED."); return 0.0; }

    double rawLot = riskAmt / (effSL * pipValPerLot);

    // STRICT DOWNWARD TRUNCATION — prevents broker rounding from over-leveraging
    double tLot = MathFloor(rawLot / brokerLotStep) * brokerLotStep;

    if(EnableTestMode)
        Print("P1-CALC: eq=", DoubleToString(equity,2), " risk=", DoubleToString(eRisk,3),
              "% riskAmt=", DoubleToString(riskAmt,4), " raw=", DoubleToString(rawLot,6),
              " truncated=", DoubleToString(tLot,4));

    // HARD BLOCK — no silent fallback to brokerMinLot
    double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(tLot < volMin)
    {
        double riskIfMin = (volMin * effSL * pipValPerLot / equity) * 100.0;
        Print("P1-CRITICAL: truncated(", DoubleToString(tLot,4), ") < minLot(", DoubleToString(volMin,4), ")");
        Print("  IntendedRisk:", DoubleToString(eRisk,3), "% | RiskIfMinForced:", DoubleToString(riskIfMin,2), "% — ABORTED");
        NotifyUser("CRITICAL: Lot below min. Equity:" + DoubleToString(equity,2) + ". Trade blocked.");
        return 0.0;
    }

    double finalLot = NormalizeDouble(MathMin(tLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)), 2);
    double actRisk  = (finalLot * effSL * pipValPerLot / equity) * 100.0;
    Print("P1-LOT OK:", DoubleToString(finalLot,2), " lots | ActualRisk:", DoubleToString(actRisk,3), "%");
    return finalLot;
}

//=== MANAGE POSITION ===============================================

void ManagePosition() { return; }

//=== CHECK CLOSED POSITION =========================================

void CheckClosedPosition()
{
    if(TimeCurrent() == lastHistoryCheck) return;
    lastHistoryCheck = TimeCurrent();
    if(!HistorySelect(TimeCurrent()-60, TimeCurrent())) return;
    int cur = HistoryDealsTotal();
    if(cur <= lastHistoryTotal) return;

    for(int i = lastHistoryTotal; i < cur; i++)
    {
        ulong tk = HistoryDealGetTicket(i);
        if(tk == 0) continue;
        if(HistoryDealGetInteger(tk, DEAL_MAGIC) != MagicNumber) continue;
        if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

        double profit = HistoryDealGetDouble(tk, DEAL_PROFIT);
        if(profit < 0)
        {
            consecutiveLosses++;
            if(consecutiveLosses >= ConsecutiveLossLimit)
            {
                activeRiskPercent = RiskPercentPerTrade * 0.5;
                int cm = (int)MathMin(PauseAfterLossMinutes + ((consecutiveLosses - ConsecutiveLossLimit) * 30), 180);
                pauseUntil = TimeCurrent() + (cm * 60);
                NotifyUser("LOSS PROTECT: " + IntegerToString(consecutiveLosses) + " losses. Risk->" + DoubleToString(activeRiskPercent,2) + "% Cooldown:" + IntegerToString(cm) + "min");
                consecutiveLosses = 0;
            }
        }
        else if(profit > 0)
        {
            consecutiveLosses = 0;
            if(activeRiskPercent < RiskPercentPerTrade && !conservativeMode)
            { activeRiskPercent = RiskPercentPerTrade; Print("Risk restored:", DoubleToString(activeRiskPercent,2), "%"); }
        }
    }
    lastHistoryTotal = cur;
    CheckProtectionLimits();
}

//=== CHECK PROTECTION LIMITS =======================================

void CheckProtectionLimits()
{
    double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
    double dLim  = GetEffectiveDailyLossLimit();
    double wLim  = GetEffectiveWeeklyLossLimit();

    if((bal - dailyStartBalance) <= -(dailyStartBalance * dLim / 100.0) && !dailyLossHit)
    { dailyLossHit = true; NotifyUser("Daily loss limit hit -" + DoubleToString(dLim,1) + "%."); }

    if((bal - weeklyStartBalance) <= -(weeklyStartBalance * wLim / 100.0) && !weeklyLossHit)
    { weeklyLossHit = true; NotifyUser("Weekly loss limit hit -" + DoubleToString(wLim,1) + "%."); }

    double wTarget = weeklyStartBalance * (WeeklyProfitTargetPercent / 100.0);
    if((bal - weeklyStartBalance) >= wTarget && !weeklyTargetReached)
    {
        if(!PositionSelect(_Symbol))
        {
            if(weeklyTargetReachedTime == 0) weeklyTargetReachedTime = TimeCurrent();
            if((int)((TimeCurrent()-weeklyTargetReachedTime)/60) >= TargetStabilityMinutes)
            { weeklyTargetReached = true; NotifyUser("Weekly target reached. Trading paused."); weeklyTargetReachedTime = 0; }
        }
        else weeklyTargetReachedTime = 0;
    }
    else weeklyTargetReachedTime = 0;
}

//=== DEPRECATED STUB ===============================================
void DetectWithdrawal() { return; }

//=== CONSERVATIVE MODE =============================================

void ManageConservativeMode()
{
    double eq = AccountInfoDouble(ACCOUNT_EQUITY), bal = AccountInfoDouble(ACCOUNT_BALANCE);
    if(eq > MaxEquityRange && !conservativeMode)
    {
        conservativeMode = true; conservativeModeThreshold = MaxEquityRange;
        double m = bal / MaxEquityRange;
        if(m > 2.0) activeRiskPercent = RiskPercentPerTrade * 0.25;
        else if(m > 1.5) activeRiskPercent = RiskPercentPerTrade * 0.4;
        else activeRiskPercent = RiskPercentPerTrade * 0.5;
        activeMaxTradesPerDay = (int)MathMax(MaxTradesPerDay * 0.5, 3);
        NotifyUser("Conservative mode ON. Risk:" + DoubleToString(activeRiskPercent,2) + "%");
    }
    if(conservativeMode && eq < conservativeModeThreshold * 0.70)
    {
        conservativeMode = false; activeRiskPercent = RiskPercentPerTrade;
        activeMaxTradesPerDay = MaxTradesPerDay; conservativeModeThreshold = 0;
        NotifyUser("Conservative mode OFF. Risk restored:" + DoubleToString(activeRiskPercent,2) + "%");
    }
}

//=== SMALL ACCOUNT MODE ============================================

void CheckAndApplySmallAccountMode()
{
    datetime cm = GetCurrentMinute();
    if(cm == lastSmallAccountCheck && lastSmallAccountCheck != 0) return;
    lastSmallAccountCheck = cm;
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);

    if(!smallAccountModeActive && EnableSmallAccountMode && bal < SmallAccountThreshold)
    { smallAccountModeActive = true; activeRiskPercent = SmallAccountRiskPercent; activeMaxTradesPerDay = SmallAccountMaxTrades; NotifyUser("Small Acct Mode ON. $" + DoubleToString(bal,2)); }

    if(smallAccountModeActive && bal >= SmallAccountExitThreshold)
    { smallAccountModeActive = false; activeRiskPercent = originalRiskPercent; activeMaxTradesPerDay = originalMaxTrades; NotifyUser("Small Acct Mode OFF. $" + DoubleToString(bal,2)); }

    if(!smallAccountModeActive && EnableSmallAccountMode && bal < SmallAccountThreshold && bal >= MinEquityRange)
    { smallAccountModeActive = true; activeRiskPercent = SmallAccountRiskPercent; activeMaxTradesPerDay = SmallAccountMaxTrades; NotifyUser("Small Acct Mode RE-ACTIVATED."); }
}

double GetEffectiveDailyLossLimit()  { return smallAccountModeActive ? SmallAccountDailyLoss  : MaxDailyLossPercent;  }
double GetEffectiveWeeklyLossLimit() { return smallAccountModeActive ? SmallAccountWeeklyLoss : MaxWeeklyLossPercent; }
double GetEffectiveMinWithdrawal()   { return smallAccountModeActive ? SmallAccountMinWithdrawal : AccountInfoDouble(ACCOUNT_BALANCE) * (WithdrawalThresholdPercent/100.0); }

//=== TIME UTILITIES ================================================

void CheckTimeResets()
{
    datetime ds = GetDayStart(), ws = GetWeekStart();
    if(ds > dailyResetTime)
    { dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); dailyResetTime = ds; tradesThisDay = 0; dailyLossHit = false; consecutiveLosses = 0; lastKnownBalance = dailyStartBalance; Print("Daily Reset. Bal:$", DoubleToString(dailyStartBalance,2)); }
    if(ws > weeklyResetTime)
    { weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); weeklyResetTime = ws; weeklyLossHit = false; weeklyTargetReached = false; weeklyTargetReachedTime = 0; lastKnownBalance = weeklyStartBalance; Print("Weekly Reset. Bal:$", DoubleToString(weeklyStartBalance,2)); }
}

datetime GetDayStart()
{ MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); dt.hour=0; dt.min=0; dt.sec=0; return StructToTime(dt); }

datetime GetWeekStart()
{ MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); int s=(dt.day_of_week==0)?6:dt.day_of_week-1; datetime m=TimeCurrent()-(s*86400); TimeToStruct(m,dt); dt.hour=0; dt.min=0; dt.sec=0; return StructToTime(dt); }

datetime GetCurrentMinute()
{ MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); dt.sec=0; return StructToTime(dt); }

void NotifyUser(string msg) { string f="[CapPreserve] "+msg; SendNotification(f); Print(f); }

//=== COOLDOWN & SPREAD SPIKE =======================================

bool CheckExecutionCooldown()
{
    int s = (int)(TimeCurrent() - lastTradeTime);
    if(s < MinSecondsBetweenTrades)
    { static datetime l=0; if(TimeCurrent()-l>60){ Print("COOLDOWN: Wait ", MinSecondsBetweenTrades-s, "s."); l=TimeCurrent(); } return false; }
    return true;
}

void DetectSpreadSpike()
{
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT); int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    double pv=(dg==3||dg==5)?pt*10.0:pt; int sp=(int)((ask-bid)/pv);
    if(lastSpread==0){lastSpread=sp;return;}
    if(sp>(lastSpread*2.5)&&sp>PreferredSpreadPoints&&TimeCurrent()-spreadSpikeDetectedTime>1800)
    { pauseUntil=MathMax(pauseUntil,TimeCurrent()+1800); spreadSpikeDetectedTime=TimeCurrent(); NotifyUser("SPREAD SPIKE:"+IntegerToString(sp)+" pts. 30-min pause."); }
    lastSpread=sp;
}

//=== ACCOUNT FLOOR =================================================

void CheckAccountFloor()
{
    if(accountFloorHit && !softRearmActive) return;
    if(RequireManualResetAfterFloor && !softRearmActive)
    {
        if(GlobalVariableCheck("AccountFloorHit_"+(string)((int)AccountInfoInteger(ACCOUNT_LOGIN))))
        { accountFloorHit=true; Print("FLOOR LOCK ACTIVE."); return; }
    }
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    if(eq <= MinEquityRange)
    {
        if(softRearmActive) { softRearmActive=false; ultraConservativeMode=false; if(!conservativeMode){activeRiskPercent=RiskPercentPerTrade;activeMaxTradesPerDay=MaxTradesPerDay;} }
        accountFloorHit=true; accountFloorHitTime=TimeCurrent();
        if(RequireManualResetAfterFloor) GlobalVariableSet("AccountFloorHit_"+(string)((int)AccountInfoInteger(ACCOUNT_LOGIN)),1);
        Alert("CRITICAL: ACCOUNT FLOOR HIT. Equity:$",DoubleToString(eq,2));
        NotifyUser("CRITICAL: Floor hit. Trading halted.");
        CheckSoftRearmConditions();
    }
}

//=== DIAGNOSTIC LOGGING ============================================

void PrintDailyDiagnostic()
{
    datetime today = GetDayStart();
    if(today <= lastDiagnosticPrint) return;
    lastDiagnosticPrint = today;
    double bal=AccountInfoDouble(ACCOUNT_BALANCE), eq=AccountInfoDouble(ACCOUNT_EQUITY);
    double wPnL=((bal-weeklyStartBalance)/weeklyStartBalance)*100.0;
    Print("===== DAILY DIAGNOSTIC =====");
    Print("Bal:$",DoubleToString(bal,2)," Eq:$",DoubleToString(eq,2));
    Print("Risk:",DoubleToString(activeRiskPercent,2),"% ConservMode:",conservativeMode?"ON":"OFF");
    Print("CMI Regime:",g_marketRegime," CMI=",DoubleToString(g_lastCMI,1));
    Print("WeeklyPnL:",DoubleToString(wPnL,2),"% TodayTrades:",tradesThisDay);
    Print("============================");
}

//=== EMERGENCY STOP ================================================

void CheckEmergencyDrawdown()
{
    if(emergencyStopActive) return;
    double dd=((initialEquity-AccountInfoDouble(ACCOUNT_EQUITY))/initialEquity)*100.0;
    if(dd >= MaxEquityDrawdownPercent) ActivateEmergencyStop("Drawdown "+DoubleToString(dd,2)+"% > limit "+DoubleToString(MaxEquityDrawdownPercent,1)+"%");
}

void ActivateEmergencyStop(string reason)
{
    emergencyStopActive=true;
    Alert("EMERGENCY STOP: ",reason);
    for(int i=PositionsTotal()-1;i>=0;i--)
    { ulong tk=PositionGetTicket(i); if(PositionSelectByTicket(tk)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) trade.PositionClose(tk); }
    NotifyUser("EMERGENCY STOP: "+reason+" All positions closed. Restart required.");
}

//=== TRADE INTEGRITY ===============================================

void VerifyTradeIntegrity(ENUM_ORDER_TYPE ot, double expSL, double expTP)
{
    if(!PositionSelect(_Symbol)) return;
    double posSL=PositionGetDouble(POSITION_SL), posTP=PositionGetDouble(POSITION_TP);
    ulong tk=PositionGetInteger(POSITION_TICKET); double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    if(posSL==0||posTP==0||MathAbs(posSL-expSL)/pt>10||MathAbs(posTP-expTP)/pt>10)
    { Print("INTEGRITY FAIL: ticket ",tk," SL got:",posSL," exp:",expSL," TP got:",posTP," exp:",expTP); if(trade.PositionClose(tk)){NotifyUser("CRITICAL: Position closed — integrity fail.");RecordExecutionError();} }
    else Print("Integrity OK: ticket ",tk);
}

//=== ERROR TRACKING ================================================

void RecordExecutionError()
{
    consecutiveErrors++; lastErrorTime=TimeCurrent();
    Print("Exec error #",consecutiveErrors);
    if(consecutiveErrors>=MaxConsecutiveErrors) ActivateEmergencyStop("Consecutive errors ("+IntegerToString(consecutiveErrors)+")");
    else if(consecutiveErrors>=MaxConsecutiveErrors/2) { pauseUntil=MathMax(pauseUntil,TimeCurrent()+1800); NotifyUser("WARNING: "+IntegerToString(consecutiveErrors)+" errors. 30min pause."); }
}

//=== SOFT RE-ARM ===================================================

void CheckSoftRearmConditions()
{
    if(!SoftRearmAllowed||!accountFloorHit) return;
    double eq=AccountInfoDouble(ACCOUNT_EQUITY);
    if(eq<30.0){Print("SOFT RE-ARM BLOCKED: Account too small ($",DoubleToString(eq,2),")");}
    if((int)((TimeCurrent()-accountFloorHitTime)/60)<SoftRearmCooldownMinutes) return;
    if(PositionSelect(_Symbol)) return;
    double bal=AccountInfoDouble(ACCOUNT_BALANCE);
    if(MathAbs(eq-bal)>bal*0.005) return;
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT); int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    double pv=(dg==3||dg==5)?pt*10.0:pt; int sp=(int)((ask-bid)/pv);
    if(sp>PreferredSpreadPoints||!IsTradingTime()||eq<=MinEquityRange) return;
    ActivateSoftRearm();
}

void ActivateSoftRearm()
{
    softRearmActive=true; ultraConservativeMode=true;
    activeRiskPercent=RiskPercentPerTrade*0.25; activeMaxTradesPerDay=2;
    accountFloorHit=false;
    Print("SOFT RE-ARM ACTIVATED. Risk:",DoubleToString(activeRiskPercent,3),"% MaxTrades:",activeMaxTradesPerDay);
    NotifyUser("SOFT RE-ARM: Recovery mode. Risk:"+DoubleToString(activeRiskPercent,3)+"%");
}

//=== NEWS FILTER ===================================================

bool IsNewsEvent()
{
    datetime now=TimeCurrent(), st=now-(NewsPauseMinutesAfter*60), et=now+(NewsPauseMinutesBefore*60);
    MqlCalendarValue vals[];
    if(CalendarValueHistory(vals,st,et))
    {
        for(int i=0;i<ArraySize(vals);i++)
        {
            MqlCalendarEvent ev; MqlCalendarCountry co;
            if(!CalendarEventById(vals[i].event_id,ev)||!CalendarCountryById(ev.country_id,co)) continue;
            if(co.currency!="USD"&&co.currency!="EUR") continue;
            if(ev.importance==CALENDAR_IMPORTANCE_HIGH) { Print("HIGH IMPACT NEWS: ",ev.name); return true; }
            if(IncludeMediumImpact&&ev.importance==CALENDAR_IMPORTANCE_MODERATE) { Print("MEDIUM IMPACT NEWS: ",ev.name); return true; }
        }
    }
    return false;
}

//=== TRAILING STOP =================================================

void ApplyTrailingStop()
{
    if(!EnableTrailingStop||!PositionSelect(_Symbol)) return;
    double cSL=PositionGetDouble(POSITION_SL), cTP=PositionGetDouble(POSITION_TP);
    double op=PositionGetDouble(POSITION_PRICE_OPEN), cp=PositionGetDouble(POSITION_PRICE_CURRENT);
    long   tp=(long)PositionGetInteger(POSITION_TYPE);
    double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT); int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    double ps=(dg==3||dg==5)?pt*10.0:pt;

    if(tp==POSITION_TYPE_BUY)
    {
        double pp=(cp-op)/ps;
        if(pp>TrailingStartPips)
        { double nSL=cp-(TrailingDistPips*ps); if(nSL>(cSL+(TrailingStepPips*ps))) { nSL=NormalizeDouble(nSL,dg); trade.PositionModify(PositionGetInteger(POSITION_TICKET),nSL,cTP); Print("TRAIL BUY: SL->",nSL); } }
    }
    if(tp==POSITION_TYPE_SELL)
    {
        double pp=(op-cp)/ps;
        if(pp>TrailingStartPips)
        { double nSL=cp+(TrailingDistPips*ps); if(cSL==0||nSL<(cSL-(TrailingStepPips*ps))) { nSL=NormalizeDouble(nSL,dg); trade.PositionModify(PositionGetInteger(POSITION_TICKET),nSL,cTP); Print("TRAIL SELL: SL->",nSL); } }
    }
}

//+------------------------------------------------------------------+
//  END OF FILE — Guardian_EURUSD_v2.mq5
//+------------------------------------------------------------------+