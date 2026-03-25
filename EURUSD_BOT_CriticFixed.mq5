//+------------------------------------------------------------------+
//|  EURUSD_CapitalPreservation.mq5  —  PATCH SET v2.0             |
//|  Target Platform: Exness Standard Cent Account (USC)            |
//|                                                                  |
//|  *** SURGICAL PATCH FILE — DROP-IN REPLACEMENTS ***             |
//|  Each section below is a self-contained replacement.           |
//|  Search for the original function name and swap it out.        |
//+------------------------------------------------------------------+
//
//  PATCH SUMMARY
//  =============
//  PATCH 1 : CalculateLotSize()
//             — USC-aware risk math (no hard USD references)
//             — Strict MathFloor() downward truncation
//             — Hard abort if lot < SYMBOL_VOLUME_MIN (no silent fallback)
//             — 0.50% hard cap enforced INSIDE the function
//
//  PATCH 2 : CalculateCMI()          [NEW FUNCTION]
//             — 30-period Choppy Market Index on current chart TF
//             — Returns double in range [0, 100]
//
//  PATCH 3 : CheckForEntry()
//             — Deprecates static 0.03% EMA separation filter
//             — Deprecates hard-coded 0.00015 EMA slope threshold
//             — Integrates CMI regime switching (Swing vs Trend)
//             — For TREND regime: chains M1 microtrading layer
//
//  PATCH 4 : GetM1MicrotradingSignal()  [NEW FUNCTION]
//             — Four-indicator confluence on M1 for precise entries
//             — EBB midline (EMA-18 M1), EMA-3 M1, MACD hist, RSI(14)
//             — Returns  1 = BUY,  -1 = SELL,  0 = NO SIGNAL
//
//  PATCH 5 : InitializeMicrotradingIndicators()  [NEW FUNCTION]
//             — Creates all four M1 indicator handles
//             — Call this at the END of OnInit() before return
//
//  PATCH 6 : DeinitMicrotradingIndicators()  [NEW FUNCTION]
//             — Releases M1 handles cleanly
//             — Call this at the START of OnDeinit()
//
// =================================================================
// HOW TO APPLY
// =================================================================
//  1. Open EURUSD_CapitalPreservation.mq5 in MetaEditor.
//  2. Add the NEW GLOBAL VARIABLES block (Section A) to your
//     global variables section, near the existing indicator handles.
//  3. Find each original function listed below and replace it
//     entirely with the patched version from this file.
//  4. Add the two OnInit / OnDeinit call sites as noted.
//  5. Compile — zero new warnings expected.
// =================================================================


// =================================================================
// SECTION A — NEW GLOBAL VARIABLES
// (Add these near the existing indicator handles, e.g. after line 486)
// =================================================================

/*
//--- CMI Regime State (Patch 2)
string g_marketRegime    = "UNDEFINED"; // "SWING" | "TREND" | "UNDEFINED"
double g_lastCMI         = 0.0;        // Last computed CMI value (for diagnostics)
datetime g_lastCMILog    = 0;          // Rate-limiter for CMI log spam

//--- M1 Microtrading Indicator Handles (Patch 3 / 4)
int g_m1_ema18Handle  = INVALID_HANDLE; // EBB midline: EMA(18) on M1 — exponential BB midline
int g_m1_ema3Handle   = INVALID_HANDLE; // Fast signal: EMA(3)  on M1
int g_m1_macdHandle   = INVALID_HANDLE; // MACD (12, 26, 9)     on M1
int g_m1_rsi14Handle  = INVALID_HANDLE; // RSI (14)             on M1
*/


// =================================================================
// SECTION B — OnInit() ADDITION
// (Add this block just before "return INIT_SUCCEEDED;" in OnInit)
// =================================================================

/*
    //--- PATCH 3: Initialize M1 microtrading indicator layer
    if(!InitializeMicrotradingIndicators())
    {
        // Non-fatal if M1 data is not yet warmed up; EA will fall back
        // to Swing-regime logic only until handles become valid.
        Print("⚠️ PATCH3: M1 indicator init deferred (data not ready). "
              "Trend entries temporarily disabled.");
    }
*/


// =================================================================
// SECTION C — OnDeinit() ADDITION
// (Add as the very first line inside OnDeinit, before existing releases)
// =================================================================

/*
    DeinitMicrotradingIndicators(); // PATCH 3: release M1 handles
*/


// =================================================================
// PATCH 5 — InitializeMicrotradingIndicators()
//            NEW FUNCTION — insert anywhere before CheckForEntry()
// =================================================================

//+------------------------------------------------------------------+
//| Create and validate all four M1 microtrading indicator handles   |
//| Returns: true  = all handles valid                               |
//|          false = one or more handles failed (non-fatal)          |
//+------------------------------------------------------------------+
bool InitializeMicrotradingIndicators()
{
    //--- Minimum M1 bars needed: max lookback of the slowest indicator
    //    MACD slow EMA = 26 bars, signal = 9 bars → need >= 35 M1 bars
    int m1Bars = Bars(_Symbol, PERIOD_M1);
    if(m1Bars < 50)
    {
        Print("⚠️ PATCH3-INIT: Only ", m1Bars, " M1 bars available. Need 50. Deferring.");
        return false;
    }

    //--- EBB Midline: EMA(18) on M1
    //    The "Exponential Bollinger Band midline" IS the EMA itself.
    //    Upper/Lower bands are not required for the crossover signal.
    g_m1_ema18Handle = iMA(_Symbol, PERIOD_M1, 18, 0, MODE_EMA, PRICE_CLOSE);
    if(g_m1_ema18Handle == INVALID_HANDLE)
    {
        Print("❌ PATCH3-INIT: Failed to create EMA-18 M1 handle. Error: ", GetLastError());
        return false;
    }

    //--- Fast Signal EMA: EMA(3) on M1
    g_m1_ema3Handle = iMA(_Symbol, PERIOD_M1, 3, 0, MODE_EMA, PRICE_CLOSE);
    if(g_m1_ema3Handle == INVALID_HANDLE)
    {
        Print("❌ PATCH3-INIT: Failed to create EMA-3 M1 handle. Error: ", GetLastError());
        IndicatorRelease(g_m1_ema18Handle);
        g_m1_ema18Handle = INVALID_HANDLE;
        return false;
    }

    //--- MACD (12, 26, 9) on M1
    //    Buffer 0 = MACD main line, Buffer 1 = Signal line
    //    Histogram is computed as: macd[0] - signal[0]
    g_m1_macdHandle = iMACD(_Symbol, PERIOD_M1, 12, 26, 9, PRICE_CLOSE);
    if(g_m1_macdHandle == INVALID_HANDLE)
    {
        Print("❌ PATCH3-INIT: Failed to create MACD M1 handle. Error: ", GetLastError());
        IndicatorRelease(g_m1_ema18Handle);
        IndicatorRelease(g_m1_ema3Handle);
        g_m1_ema18Handle = INVALID_HANDLE;
        g_m1_ema3Handle  = INVALID_HANDLE;
        return false;
    }

    //--- RSI(14) on M1
    g_m1_rsi14Handle = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);
    if(g_m1_rsi14Handle == INVALID_HANDLE)
    {
        Print("❌ PATCH3-INIT: Failed to create RSI-14 M1 handle. Error: ", GetLastError());
        IndicatorRelease(g_m1_ema18Handle);
        IndicatorRelease(g_m1_ema3Handle);
        IndicatorRelease(g_m1_macdHandle);
        g_m1_ema18Handle = INVALID_HANDLE;
        g_m1_ema3Handle  = INVALID_HANDLE;
        g_m1_macdHandle  = INVALID_HANDLE;
        return false;
    }

    Print("✅ PATCH3-INIT: All four M1 microtrading handles initialized successfully.");
    Print("   EMA-18 M1 (EBB midline) : handle=", g_m1_ema18Handle);
    Print("   EMA-3  M1 (fast signal) : handle=", g_m1_ema3Handle);
    Print("   MACD(12,26,9) M1        : handle=", g_m1_macdHandle);
    Print("   RSI(14) M1              : handle=", g_m1_rsi14Handle);
    return true;
}


// =================================================================
// PATCH 6 — DeinitMicrotradingIndicators()
//            NEW FUNCTION — insert near OnDeinit()
// =================================================================

//+------------------------------------------------------------------+
//| Release all M1 microtrading indicator handles gracefully         |
//+------------------------------------------------------------------+
void DeinitMicrotradingIndicators()
{
    if(g_m1_ema18Handle != INVALID_HANDLE)
    {
        IndicatorRelease(g_m1_ema18Handle);
        g_m1_ema18Handle = INVALID_HANDLE;
    }
    if(g_m1_ema3Handle != INVALID_HANDLE)
    {
        IndicatorRelease(g_m1_ema3Handle);
        g_m1_ema3Handle = INVALID_HANDLE;
    }
    if(g_m1_macdHandle != INVALID_HANDLE)
    {
        IndicatorRelease(g_m1_macdHandle);
        g_m1_macdHandle = INVALID_HANDLE;
    }
    if(g_m1_rsi14Handle != INVALID_HANDLE)
    {
        IndicatorRelease(g_m1_rsi14Handle);
        g_m1_rsi14Handle = INVALID_HANDLE;
    }
    Print("PATCH3-DEINIT: M1 indicator handles released.");
}


// =================================================================
// PATCH 1 — CalculateLotSize()
//            FULL REPLACEMENT of the original function
//
// KEY CHANGES vs. original:
//  1. 0.50% hard cap enforced unconditionally (Small Account Mode).
//  2. Strict MathFloor() truncation — identical to original line 1737
//     BUT the MathMax() fallback that followed it is GONE.
//  3. If truncated lot < SYMBOL_VOLUME_MIN → CRITICAL error + return 0
//     (The existing OpenTrade() guard will catch the 0 and abort.)
//  4. All monetary math uses the raw ACCOUNT_EQUITY value which
//     MetaTrader reports in account currency. On an Exness Standard
//     Cent account that is USC (e.g. 5 000 USC for a $50 deposit).
//     SYMBOL_TRADE_TICK_VALUE is also denominated in USC, so the
//     formula is dimensionally consistent without any conversion.
// =================================================================

//+------------------------------------------------------------------+
//| Calculate lot size — USC cent-account aware, strictly truncated   |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossPips)
{
    // ------------------------------------------------------------------
    // STEP 0: Hard-cap the active risk at 0.50% (Small Account Growth
    //         Mode mandate).  We do this INSIDE the function so that
    //         even if activeRiskPercent was raised elsewhere (e.g. by a
    //         conservative-mode deactivation race), this function can
    //         never over-leverage the account.
    // ------------------------------------------------------------------
    const double USC_HARD_CAP_RISK_PCT = 0.50; // ← never exceed on USC acct
    double effectiveRisk = MathMin(activeRiskPercent, USC_HARD_CAP_RISK_PCT);

    if(activeRiskPercent > USC_HARD_CAP_RISK_PCT)
    {
        Print("⚠️ PATCH1-RISK: activeRiskPercent (", DoubleToString(activeRiskPercent, 3),
              "%) capped to ", USC_HARD_CAP_RISK_PCT, "% (USC cent-account safety)");
    }

    // ------------------------------------------------------------------
    // STEP 1: Determine the effective stop-loss (pips).
    //         Use broker-adapted value when available (set in OnInit).
    // ------------------------------------------------------------------
    double effectiveStopLoss = (adaptedStopLoss > 0.0) ? adaptedStopLoss : stopLossPips;

    // ------------------------------------------------------------------
    // STEP 2: Calculate the monetary risk amount in account currency.
    //         On Exness Standard Cent, ACCOUNT_EQUITY is in USC.
    //         Example: equity = 5 000 USC, risk 0.50% → riskAmount = 25 USC
    // ------------------------------------------------------------------
    double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount  = equity * (effectiveRisk / 100.0);

    if(equity <= 0.0)
    {
        Print("❌ PATCH1-CRITICAL: ACCOUNT_EQUITY returned ", equity,
              " — Cannot calculate lot size. Trade ABORTED.");
        return 0.0;
    }

    // ------------------------------------------------------------------
    // STEP 3: Convert the stop-loss from pips to a price distance.
    //         Handles both 3/5-digit (ECN) and 2/4-digit brokers.
    // ------------------------------------------------------------------
    int    digits      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double pipSize     = (digits == 3 || digits == 5) ? point * 10.0 : point;
    double slPrice     = effectiveStopLoss * pipSize; // price distance for the SL

    // ------------------------------------------------------------------
    // STEP 4: Fetch tick parameters.
    //         tickValue = monetary value of one tick per 1 full lot, in USC.
    //         tickSize  = price distance of one tick.
    //         pipValuePerLot = USC value of a 1-pip move per 1 lot.
    // ------------------------------------------------------------------
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tickValue <= 0.0 || tickSize <= 0.0)
    {
        Print("❌ PATCH1-CRITICAL: Invalid tick params — tickValue=", tickValue,
              " tickSize=", tickSize, ". Trade ABORTED.");
        return 0.0;
    }

    // Monetary value of moving 1 pip with a 1-lot position (in USC)
    double pipValuePerLot = (tickValue / tickSize) * pipSize;

    if(pipValuePerLot <= 0.0)
    {
        Print("❌ PATCH1-CRITICAL: pipValuePerLot computed as ", pipValuePerLot,
              " — likely bad tick data. Trade ABORTED.");
        return 0.0;
    }

    // ------------------------------------------------------------------
    // STEP 5: Raw (unrounded) lot size.
    //         Formula: lots = riskAmount / (stopLoss_pips × pipValuePerLot)
    // ------------------------------------------------------------------
    double rawLotSize = riskAmount / (effectiveStopLoss * pipValuePerLot);

    // ------------------------------------------------------------------
    // STEP 6: STRICT DOWNWARD TRUNCATION.
    //         We floor to the nearest broker lot step.
    //         This is intentionally conservative: we NEVER round up
    //         because even a partial step up can materially over-leverage
    //         a micro-sized USC account.
    //
    //         Example on Exness Cent:
    //           brokerLotStep = 0.01
    //           rawLotSize    = 0.0137
    //           truncated     = floor(0.0137 / 0.01) * 0.01 = 0.01  ✓
    //           (standard round would give 0.01, same result here, but
    //            for rawLotSize = 0.0187 round gives 0.02, floor gives 0.01)
    // ------------------------------------------------------------------
    double truncatedLot = MathFloor(rawLotSize / brokerLotStep) * brokerLotStep;

    // Diagnostic: show the truncation delta
    if(EnableTestMode)
    {
        Print("PATCH1-LOTCALC: equity=", DoubleToString(equity, 2),
              " USC | risk=", DoubleToString(effectiveRisk, 3), "%",
              " | riskAmt=", DoubleToString(riskAmount, 4), " USC");
        Print("PATCH1-LOTCALC: SL=", effectiveStopLoss, " pips",
              " | pipVal/lot=", DoubleToString(pipValuePerLot, 6), " USC",
              " | rawLot=", DoubleToString(rawLotSize, 6),
              " | truncated=", DoubleToString(truncatedLot, 4));
    }

    // ------------------------------------------------------------------
    // STEP 7: HARD BLOCK — if truncated lot < SYMBOL_VOLUME_MIN,
    //         the account balance is simply too small to support even
    //         the minimum broker position at the requested risk level.
    //         ABORT with a critical log.  OpenTrade() will catch the
    //         0.0 return and block execution.
    //
    //         DO NOT silently fall back to brokerMinLot here — doing so
    //         would open a trade with ACTUAL risk >> intended risk, which
    //         is the exact lot-sizing paradox we are eliminating.
    // ------------------------------------------------------------------
    double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    if(truncatedLot < volMin)
    {
        double actualRiskIfMin = (volMin * effectiveStopLoss * pipValuePerLot / equity) * 100.0;

        Print("╔══════════════════════════════════════════════════════════════╗");
        Print("║  PATCH1-CRITICAL: LOT SIZE BELOW BROKER MINIMUM — ABORTED  ║");
        Print("╠══════════════════════════════════════════════════════════════╣");
        Print("║  Calculated lot (truncated) : ", DoubleToString(truncatedLot, 4));
        Print("║  Broker SYMBOL_VOLUME_MIN   : ", DoubleToString(volMin, 4));
        Print("║  Intended risk              : ", DoubleToString(effectiveRisk, 3), "%");
        Print("║  Risk if min lot forced     : ", DoubleToString(actualRiskIfMin, 2),
              "% (EXCEEDS CAP — silent fallback refused)");
        Print("║  Account equity             : ", DoubleToString(equity, 2), " USC");
        Print("║  Action: Trade ABORTED. Grow account before next attempt.  ║");
        Print("╚══════════════════════════════════════════════════════════════╝");

        NotifyUser("CRITICAL: Lot size below broker minimum. Trade blocked. "
                   "Equity: " + DoubleToString(equity, 2) + " USC. "
                   "Min lot: " + DoubleToString(volMin, 4) + ".");
        return 0.0; // ← OpenTrade() catches this and hard-aborts
    }

    // ------------------------------------------------------------------
    // STEP 8: Apply broker MAXIMUM lot cap.
    //         This is the only MathMin() / MathMax() allowed — capping
    //         above the broker maximum is a hard broker-API requirement,
    //         not a risk escalation.
    // ------------------------------------------------------------------
    double volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double finalLot  = MathMin(truncatedLot, volMax);

    if(finalLot < truncatedLot)
    {
        Print("⚠️ PATCH1: truncatedLot (", DoubleToString(truncatedLot, 4),
              ") clipped to SYMBOL_VOLUME_MAX (", DoubleToString(volMax, 4), ")");
    }

    // ------------------------------------------------------------------
    // STEP 9: Final normalisation (MQL5 requirement: 2 decimal places
    //         is standard for most brokers).
    // ------------------------------------------------------------------
    finalLot = NormalizeDouble(finalLot, 2);

    // Actual risk verification log (always shown, not just in test mode)
    double actualRiskAmt  = finalLot * effectiveStopLoss * pipValuePerLot;
    double actualRiskPct  = (actualRiskAmt / equity) * 100.0;
    Print("✅ PATCH1-LOT: ", DoubleToString(finalLot, 2), " lots",
          " | Actual risk: ", DoubleToString(actualRiskPct, 3),
          "% (", DoubleToString(actualRiskAmt, 4), " USC)");

    return finalLot;
}


// =================================================================
// PATCH 2 — CalculateCMI()
//            NEW FUNCTION — insert before CheckForEntry()
//
// The Choppy Market Index measures how directionally the market
// moved over the look-back period relative to its total range.
//
//   CMI = |Close[0] - Close[n-1]| / (HighestHigh[n] - LowestLow[n]) × 100
//
// Interpretation used here (per spec):
//   CMI < 20  → choppy / sideways → SWING regime (Mean Reversion)
//   CMI ≥ 20  → directional      → TREND regime (Trend Following + M1 layer)
//
// Note: The CMI is calculated on the CURRENT chart timeframe (M5 or
//       higher, enforced by OnInit). Using the execution chart TF
//       gives the regime relevant to the position-entry decision.
// =================================================================

//+------------------------------------------------------------------+
//| Calculate 30-period Choppy Market Index on the current timeframe |
//| Returns value in [0, 100].  Returns -1.0 on data error.         |
//+------------------------------------------------------------------+
double CalculateCMI()
{
    const int CMI_PERIOD = 30; // canonical look-back window

    // ------------------------------------------------------------------
    // Fetch the last CMI_PERIOD closes, highs, and lows.
    // ArraySetAsSeries(true) means index 0 = most recent bar.
    // ------------------------------------------------------------------
    double closeArr[], highArr[], lowArr[];
    ArraySetAsSeries(closeArr, true);
    ArraySetAsSeries(highArr,  true);
    ArraySetAsSeries(lowArr,   true);

    //--- We need CMI_PERIOD bars so the oldest close is at index CMI_PERIOD-1
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, CMI_PERIOD, closeArr) < CMI_PERIOD)
    {
        static datetime lastCMIErr = 0;
        if(TimeCurrent() - lastCMIErr > 60)
        {
            Print("⚠️ PATCH2-CMI: CopyClose failed (", CMI_PERIOD, " bars). Error: ", GetLastError());
            lastCMIErr = TimeCurrent();
        }
        return -1.0; // caller must treat as invalid
    }

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, CMI_PERIOD, highArr) < CMI_PERIOD ||
       CopyLow (_Symbol, PERIOD_CURRENT, 0, CMI_PERIOD, lowArr)  < CMI_PERIOD)
    {
        Print("⚠️ PATCH2-CMI: CopyHigh/CopyLow failed. Error: ", GetLastError());
        return -1.0;
    }

    // ------------------------------------------------------------------
    // Numerator: absolute net price displacement over the window.
    //   closeArr[0]           = Close of the current (most recent) bar
    //   closeArr[CMI_PERIOD-1] = Close of the bar 29 periods ago
    // ------------------------------------------------------------------
    double netDisplacement = MathAbs(closeArr[0] - closeArr[CMI_PERIOD - 1]);

    // ------------------------------------------------------------------
    // Denominator: total high-low range over the same window.
    //   ArrayMaximum / ArrayMinimum search the FULL array.
    // ------------------------------------------------------------------
    int    maxIdx  = ArrayMaximum(highArr, 0, CMI_PERIOD);
    int    minIdx  = ArrayMinimum(lowArr,  0, CMI_PERIOD);
    double highest = highArr[maxIdx];
    double lowest  = lowArr [minIdx];
    double totalRange = highest - lowest;

    // Guard against a zero-range condition (e.g. on a newly created symbol
    // or during a pre-market freeze).
    if(totalRange <= 0.0)
    {
        Print("⚠️ PATCH2-CMI: totalRange is zero — market data anomaly. Returning 0.");
        return 0.0;
    }

    // ------------------------------------------------------------------
    // CMI formula (as specified)
    // ------------------------------------------------------------------
    double cmi = (netDisplacement / totalRange) * 100.0;

    // Clamp to [0, 100] to protect against floating-point edge cases
    cmi = MathMax(0.0, MathMin(100.0, cmi));

    // Rate-limited diagnostic log (once per minute unless test mode)
    if(TimeCurrent() - g_lastCMILog >= 60 || EnableTestMode)
    {
        string regimeStr = (cmi < 20.0) ? "SWING (Mean Reversion)" : "TREND (Trend-Following)";
        Print("PATCH2-CMI: CMI=", DoubleToString(cmi, 2),
              " | Regime: ", regimeStr,
              " | NetDisp=", DoubleToString(netDisplacement, 5),
              " | Range=", DoubleToString(totalRange, 5));
        g_lastCMILog = TimeCurrent();
    }

    return cmi;
}


// =================================================================
// PATCH 4 — GetM1MicrotradingSignal()
//            NEW FUNCTION — insert before CheckForEntry()
//
// Evaluates four-indicator confluence on the M1 chart.
// Only called when CMI ≥ 20 (TREND regime).
//
// INDICATORS
//   1. EBB midline  = EMA(18) on M1  [g_m1_ema18Handle]
//   2. Fast EMA     = EMA(3)  on M1  [g_m1_ema3Handle ]
//   3. MACD hist    = MACD(12,26,9) M1 main - signal [g_m1_macdHandle]
//   4. RSI(14)      on M1            [g_m1_rsi14Handle]
//
// SIGNAL RULES
//   BUY  : EMA-3 crosses UP through EBB midline (EMA-18)
//          AND MACD histogram > 0
//          AND RSI > 50
//
//   SELL : EMA-3 crosses DOWN through EBB midline (EMA-18)
//          AND MACD histogram < 0
//          AND RSI < 50
//
//   NOTE: "Crosses" is defined as:
//         Bar[1] (previous M1 close): EMA-3 was on one side
//         Bar[0] (current  M1 close): EMA-3 is on the other side
//
// RETURNS
//   +1 = BUY signal
//   -1 = SELL signal
//    0 = No signal / error
// =================================================================

//+------------------------------------------------------------------+
//| Evaluate M1 microtrading signal (Trend regime only)             |
//| Returns: +1 = BUY | -1 = SELL | 0 = NO SIGNAL                  |
//+------------------------------------------------------------------+
int GetM1MicrotradingSignal()
{
    // ------------------------------------------------------------------
    // Guard: handles must be valid.  If init was deferred, attempt lazy
    // re-initialisation so the system is self-healing.
    // ------------------------------------------------------------------
    if(g_m1_ema18Handle == INVALID_HANDLE ||
       g_m1_ema3Handle  == INVALID_HANDLE ||
       g_m1_macdHandle  == INVALID_HANDLE ||
       g_m1_rsi14Handle == INVALID_HANDLE)
    {
        Print("⚠️ PATCH4-M1: One or more M1 handles invalid. Attempting lazy re-init...");
        if(!InitializeMicrotradingIndicators())
        {
            Print("⚠️ PATCH4-M1: Re-init failed. Returning NO SIGNAL.");
            return 0;
        }
    }

    // ------------------------------------------------------------------
    // Read indicator buffers — we need 2 bars (current + previous) for
    // the crossover detection, 1 bar for MACD and RSI confirmations.
    //
    // Buffer layout for iMACD:
    //   Buffer 0 = MACD main line  (fast EMA - slow EMA)
    //   Buffer 1 = MACD signal line
    //   Histogram = Buffer0 - Buffer1  (computed manually)
    // ------------------------------------------------------------------
    double ema18[2], ema3[2], macdMain[1], macdSignal[1], rsi[1];

    ArraySetAsSeries(ema18,      true);
    ArraySetAsSeries(ema3,       true);
    ArraySetAsSeries(macdMain,   true);
    ArraySetAsSeries(macdSignal, true);
    ArraySetAsSeries(rsi,        true);

    //--- EBB midline EMA-18 (2 bars for crossover)
    if(CopyBuffer(g_m1_ema18Handle, 0, 0, 2, ema18) < 2)
    {
        Print("⚠️ PATCH4-M1: Failed to copy EMA-18 buffer. Error: ", GetLastError());
        return 0;
    }

    //--- Fast EMA-3 (2 bars for crossover)
    if(CopyBuffer(g_m1_ema3Handle, 0, 0, 2, ema3) < 2)
    {
        Print("⚠️ PATCH4-M1: Failed to copy EMA-3 buffer. Error: ", GetLastError());
        return 0;
    }

    //--- MACD main line and signal line (1 bar each)
    if(CopyBuffer(g_m1_macdHandle, 0, 0, 1, macdMain)   < 1 ||
       CopyBuffer(g_m1_macdHandle, 1, 0, 1, macdSignal) < 1)
    {
        Print("⚠️ PATCH4-M1: Failed to copy MACD buffer. Error: ", GetLastError());
        return 0;
    }

    //--- RSI (1 bar)
    if(CopyBuffer(g_m1_rsi14Handle, 0, 0, 1, rsi) < 1)
    {
        Print("⚠️ PATCH4-M1: Failed to copy RSI buffer. Error: ", GetLastError());
        return 0;
    }

    // ------------------------------------------------------------------
    // Derived values
    // ------------------------------------------------------------------
    // Crossover states — index[0] = current bar, index[1] = previous bar
    bool ema3AboveEBBNow  = (ema3[0] > ema18[0]); // current bar
    bool ema3AboveEBBPrev = (ema3[1] > ema18[1]); // previous bar

    bool crossedUp   = (!ema3AboveEBBPrev && ema3AboveEBBNow);   // was below, now above
    bool crossedDown = ( ema3AboveEBBPrev && !ema3AboveEBBNow);  // was above, now below

    // MACD histogram
    double macdHistogram = macdMain[0] - macdSignal[0];

    // RSI value
    double rsiValue = rsi[0];

    // ------------------------------------------------------------------
    // Confluence evaluation
    // ------------------------------------------------------------------
    bool buySignal  = (crossedUp   && macdHistogram > 0.0 && rsiValue > 50.0);
    bool sellSignal = (crossedDown && macdHistogram < 0.0 && rsiValue < 50.0);

    // ------------------------------------------------------------------
    // Verbose diagnostic (test mode or once-per-minute)
    // ------------------------------------------------------------------
    if(EnableTestMode)
    {
        Print("═══════════ M1 MICROTRADING SIGNAL CHECK ═══════════");
        Print("EMA-3[0]=",  DoubleToString(ema3[0],  5),
              " vs EBB18[0]=", DoubleToString(ema18[0], 5));
        Print("EMA-3[1]=",  DoubleToString(ema3[1],  5),
              " vs EBB18[1]=", DoubleToString(ema18[1], 5));
        Print("CrossedUP: ",   crossedUp   ? "YES" : "NO",
              " | CrossedDOWN: ", crossedDown ? "YES" : "NO");
        Print("MACD Hist: ", DoubleToString(macdHistogram, 6),
              " (main=", DoubleToString(macdMain[0], 6),
              " sig=",   DoubleToString(macdSignal[0], 6), ")");
        Print("RSI(14) M1: ", DoubleToString(rsiValue, 2));
        Print("BUY signal:  ", buySignal  ? "✅ YES" : "✗ NO");
        Print("SELL signal: ", sellSignal ? "✅ YES" : "✗ NO");
        Print("════════════════════════════════════════════════════");
    }

    // Conflict guard — both signals simultaneously should not happen,
    // but if the data is ambiguous, stand down.
    if(buySignal && sellSignal)
    {
        Print("⚠️ PATCH4-M1: BUY and SELL both true — conflict, returning NO SIGNAL.");
        return 0;
    }

    if(buySignal)  return  1;
    if(sellSignal) return -1;
    return 0;
}


// =================================================================
// PATCH 3 — CheckForEntry()
//            FULL REPLACEMENT of the original function
//
// ARCHITECTURE CHANGES
//  ┌──────────────────────────────────────────────────────────────┐
//  │  DEPRECATED (removed)                                        │
//  │  ─ IsMarketTrending() call (static 0.03% EMA separation)   │
//  │  ─ hardcoded 0.00015 EMA slope threshold                    │
//  │    (ATR-based dynamic slope is retained for SWING regime)   │
//  │                                                              │
//  │  ADDED                                                       │
//  │  ─ CalculateCMI()  determines current market regime         │
//  │  ─ SWING (CMI < 20):  Mean-Reversion branch                │
//  │  ─ TREND (CMI ≥ 20):  Trend-Following branch               │
//  │       ↳ GetM1MicrotradingSignal() for precise M1 entry      │
//  └──────────────────────────────────────────────────────────────┘
//
// REGIME LOGIC SUMMARY
//
//  TREND REGIME (CMI ≥ 20)
//    H1 context : EMA direction + price side + ATR slope (unchanged)
//    M1 trigger : EMA-3 × EBB18 crossover + MACD hist sign + RSI side
//    Both layers MUST agree for a trade to be opened.
//
//  SWING REGIME (CMI < 20)
//    Mean-reversion entries: price overextended FROM EMA,
//    RSI in extreme zone, and EMA slope is FLAT (weak momentum)
//    — anticipating a snap-back.
//    Uses ATR to define "overextended" (price > 2×ATR from EMA).
// =================================================================

//+------------------------------------------------------------------+
//| Check for entry signals — CMI-gated dual-regime execution         |
//+------------------------------------------------------------------+
void CheckForEntry()
{
    // ------------------------------------------------------------------
    // One-trade-per-bar guard (unchanged from original)
    // ------------------------------------------------------------------
    static datetime lastSignalBarTime = 0;
    static ENUM_ORDER_TYPE committedDirection = (ENUM_ORDER_TYPE)-1;

    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

    if(currentBarTime != lastSignalBarTime)
    {
        committedDirection = (ENUM_ORDER_TYPE)-1; // reset on new bar
        lastSignalBarTime  = 0;
    }
    if(currentBarTime == lastSignalBarTime) return; // already traded this bar

    // One position at a time
    if(PositionSelect(_Symbol)) return;

    // ------------------------------------------------------------------
    // STEP 1 — CMI REGIME DETECTION (Patch 2)
    //          Replaces the deprecated IsMarketTrending() call.
    // ------------------------------------------------------------------
    double cmi = CalculateCMI();

    if(cmi < 0.0)
    {
        // CalculateCMI() already logged the error; wait for valid data
        return;
    }

    // Update global regime state (used elsewhere for diagnostics)
    g_lastCMI = cmi;

    bool isTrendRegime = (cmi >= 20.0);
    bool isSwingRegime = (cmi <  20.0);
    g_marketRegime = isTrendRegime ? "TREND" : "SWING";

    // ------------------------------------------------------------------
    // STEP 2 — Build the H1 context indicators
    //          (EMA, RSI, ATR — same as original, just re-purposed)
    // ------------------------------------------------------------------

    // Local H1 EMA handle — same multi-TF pattern as original
    int signalEmaHandle = iMA(_Symbol, EMAPeriodTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(signalEmaHandle == INVALID_HANDLE)
    {
        Print("⚠️ PATCH3-ENTRY: Failed to create H1 EMA handle. Skipping.");
        return;
    }

    double emaValue[], rsiValue[], atrValue[];
    ArraySetAsSeries(emaValue, true);
    ArraySetAsSeries(rsiValue, true);
    ArraySetAsSeries(atrValue, true);

    if(CopyBuffer(signalEmaHandle, 0, 0, 2, emaValue) < 2)
    {
        if(EnableTestMode) Print("⚠️ PATCH3-ENTRY: EMA buffer copy failed.");
        IndicatorRelease(signalEmaHandle);
        return;
    }
    if(CopyBuffer(rsiHandle, 0, 0, 1, rsiValue) < 1)
    {
        if(EnableTestMode) Print("⚠️ PATCH3-ENTRY: RSI buffer copy failed.");
        IndicatorRelease(signalEmaHandle);
        return;
    }

    double dynamicMinSlope = 0.00008; // ATR-based fallback
    double atrVal          = 0.0;
    double maxEntryDistance = 0.0;

    if(CopyBuffer(atrHandle, 0, 0, 1, atrValue) == 1)
    {
        atrVal           = atrValue[0];
        dynamicMinSlope  = atrVal * 0.04; // same tuning as original
        maxEntryDistance = atrVal * 1.5;
    }

    double currentPrice    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double emaSlope        = MathAbs(emaValue[0] - emaValue[1]);
    double emaDelta        = emaValue[0] - emaValue[1];   // signed
    double priceEmaDistance = MathAbs(currentPrice - emaValue[0]);

    bool emaRising  = (emaDelta > 0.0);
    bool emaFalling = (emaDelta < 0.0);
    bool priceAboveEMA = (currentPrice > emaValue[0]);
    bool priceBelowEMA = (currentPrice < emaValue[0]);

    // ------------------------------------------------------------------
    // STEP 3 — REGIME BRANCH
    // ------------------------------------------------------------------

    ENUM_ORDER_TYPE decidedDirection = (ENUM_ORDER_TYPE)-1;

    // ==================================================================
    //  BRANCH A — TREND REGIME (CMI ≥ 20)
    //  Strategy: Trend-Following with M1 precision entry
    // ==================================================================
    if(isTrendRegime)
    {
        // ── H1 Context Filter ──────────────────────────────────────────
        // The EMA slope must be meaningful (ATR-based dynamic threshold).
        // Prevents trading on a visually "trending" CMI during news spikes
        // where the close moved far but the EMA is still flat.
        bool h1SlopeOK        = (emaSlope >= dynamicMinSlope);
        bool priceNotChasing  = (maxEntryDistance <= 0.0 || priceEmaDistance <= maxEntryDistance);

        // RSI zones — symmetric, no overlap (identical to Patch 11B original)
        bool rsiInBuyZone     = (rsiValue[0] >= 48.0 && rsiValue[0] <= 68.0);
        bool rsiInSellZone    = (rsiValue[0] >= 32.0 && rsiValue[0] <= 52.0);

        // H1 BUY context: price above EMA, EMA rising, RSI in buy zone
        bool h1BuyContext  = (priceAboveEMA && emaRising  && rsiInBuyZone  && h1SlopeOK && priceNotChasing);
        // H1 SELL context: price below EMA, EMA falling, RSI in sell zone
        bool h1SellContext = (priceBelowEMA && emaFalling && rsiInSellZone && h1SlopeOK && priceNotChasing);

        // ── M1 Microtrading Signal (Patch 4) ──────────────────────────
        // Only query the M1 layer when the H1 context is already aligned.
        // This avoids burning CPU on M1 reads when the higher TF says NO.
        int m1Signal = 0;

        if(h1BuyContext || h1SellContext)
        {
            m1Signal = GetM1MicrotradingSignal();
        }

        // ── Confluence Gate ────────────────────────────────────────────
        // BOTH H1 context AND M1 trigger must agree.
        bool trendBuy  = (h1BuyContext  && m1Signal ==  1);
        bool trendSell = (h1SellContext && m1Signal == -1);

        // Diagnostic log (rate-limited)
        datetime currentMinute = GetCurrentMinute();
        static datetime lastTrendLog = 0;
        if(currentMinute != lastTrendLog || EnableTestMode)
        {
            if(ShowAllConditions || EnableTestMode)
            {
                Print("\n═══════════════ TREND REGIME SIGNAL CHECK (CMI=",
                      DoubleToString(cmi, 1), ") ═══════════════");
                Print("H1 EMA: ", DoubleToString(emaValue[0], 5),
                      " | Slope: ", DoubleToString(emaSlope, 6),
                      " | MinSlope: ", DoubleToString(dynamicMinSlope, 6));
                Print("Price: ", DoubleToString(currentPrice, 5),
                      " | RSI: ", DoubleToString(rsiValue[0], 1));
                Print("H1 BUY context:  ", h1BuyContext  ? "✓" : "✗");
                Print("H1 SELL context: ", h1SellContext ? "✓" : "✗");
                Print("M1 Signal: ", (m1Signal ==  1 ? "BUY" :
                                     (m1Signal == -1 ? "SELL" : "NONE")));
                Print("Trend BUY confluence:  ", trendBuy  ? "✅ FIRE" : "✗");
                Print("Trend SELL confluence: ", trendSell ? "✅ FIRE" : "✗");
                Print("════════════════════════════════════════════════════════\n");
            }
            lastTrendLog = currentMinute;
        }

        // ── Direction Decision ─────────────────────────────────────────
        if(trendBuy && !trendSell)
        {
            decidedDirection = ORDER_TYPE_BUY;
        }
        else if(trendSell && !trendBuy)
        {
            decidedDirection = ORDER_TYPE_SELL;
        }
        else if(trendBuy && trendSell)
        {
            Print("⚠️ TREND: Direction conflict — both signals active. NO TRADE.");
            IndicatorRelease(signalEmaHandle);
            return;
        }
        // else: no signal — fall through to release and return below
    }

    // ==================================================================
    //  BRANCH B — SWING REGIME (CMI < 20)
    //  Strategy: Mean Reversion
    //
    //  Logic: We expect price to snap back toward the H1 EMA.
    //  Entry conditions (deliberately tighter than trend entries to
    //  reduce false signals in inherently noisy choppy conditions):
    //
    //  BUY (oversold snap-back):
    //    price is BELOW EMA (diverged)
    //    AND price is overextended downward (>= 1.5×ATR from EMA)
    //    AND EMA slope is FLAT (momentum absent — reversion likely)
    //    AND RSI is in oversold zone (25–42)
    //
    //  SELL (overbought snap-back):
    //    price is ABOVE EMA (diverged)
    //    AND price is overextended upward (>= 1.5×ATR from EMA)
    //    AND EMA slope is FLAT (momentum absent)
    //    AND RSI is in overbought zone (58–75)
    //
    //  NOTE: In a true Mean-Reversion system the EMA should be FLAT,
    //  so we invert the slope gate: slope must be BELOW the dynamic
    //  threshold (i.e., the EMA is not strongly trending).
    // ==================================================================
    else if(isSwingRegime)
    {
        // Flat EMA = slope below the dynamic threshold
        bool emaIsFlat        = (emaSlope < dynamicMinSlope);

        // Overextended: price has moved at least 1.5×ATR from EMA
        // (If ATR is unavailable use a fixed fallback of 15 pips)
        double overextendThreshold = (atrVal > 0.0) ? (atrVal * 1.5)
                                                     : (15.0 * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0);
        bool priceOverextended = (priceEmaDistance >= overextendThreshold);

        // RSI zones for mean reversion — narrower extreme zones
        bool rsiOversold    = (rsiValue[0] >= 25.0 && rsiValue[0] <= 42.0);
        bool rsiOverbought  = (rsiValue[0] >= 58.0 && rsiValue[0] <= 75.0);

        // BUY snap-back: price too far below EMA, expect recovery upward
        bool swingBuy  = (priceBelowEMA && priceOverextended && emaIsFlat && rsiOversold);
        // SELL snap-back: price too far above EMA, expect compression downward
        bool swingSell = (priceAboveEMA && priceOverextended && emaIsFlat && rsiOverbought);

        // Diagnostic log
        datetime currentMinute = GetCurrentMinute();
        static datetime lastSwingLog = 0;
        if(currentMinute != lastSwingLog || EnableTestMode)
        {
            if(ShowAllConditions || EnableTestMode)
            {
                Print("\n═══════════════ SWING REGIME SIGNAL CHECK (CMI=",
                      DoubleToString(cmi, 1), ") ═══════════════");
                Print("H1 EMA: ", DoubleToString(emaValue[0], 5),
                      " | Slope: ", DoubleToString(emaSlope, 6),
                      " | Flat threshold: ", DoubleToString(dynamicMinSlope, 6));
                Print("Price dist from EMA: ", DoubleToString(priceEmaDistance, 5),
                      " | Overext threshold: ", DoubleToString(overextendThreshold, 5));
                Print("RSI: ", DoubleToString(rsiValue[0], 1));
                Print("EMA flat: ",       emaIsFlat       ? "✓" : "✗");
                Print("Overextended: ",   priceOverextended ? "✓" : "✗");
                Print("Swing BUY:  RSI oversold  (25-42): ", rsiOversold   ? "✓" : "✗",
                      " | priceBelowEMA: ", priceBelowEMA ? "✓" : "✗");
                Print("Swing SELL: RSI overbought(58-75): ", rsiOverbought ? "✓" : "✗",
                      " | priceAboveEMA: ", priceAboveEMA ? "✓" : "✗");
                Print("SWING BUY RESULT:  ", swingBuy  ? "✅ FIRE" : "✗");
                Print("SWING SELL RESULT: ", swingSell ? "✅ FIRE" : "✗");
                Print("════════════════════════════════════════════════════════\n");
            }
            lastSwingLog = currentMinute;
        }

        // Direction decision
        if(swingBuy && !swingSell)
        {
            decidedDirection = ORDER_TYPE_BUY;
        }
        else if(swingSell && !swingBuy)
        {
            decidedDirection = ORDER_TYPE_SELL;
        }
        else if(swingBuy && swingSell)
        {
            Print("⚠️ SWING: Direction conflict. NO TRADE.");
            IndicatorRelease(signalEmaHandle);
            return;
        }
    }

    // ------------------------------------------------------------------
    // STEP 4 — Handle no-signal case
    // ------------------------------------------------------------------
    if(decidedDirection == (ENUM_ORDER_TYPE)-1)
    {
        // No signal in either regime — log once per minute in normal mode
        static datetime lastNoSigLog = 0;
        datetime currentMinute = GetCurrentMinute();
        if(currentMinute != lastNoSigLog)
        {
            if(!EnableTestMode)
                Print("Direction: NONE [", g_marketRegime, " regime | CMI=",
                      DoubleToString(cmi, 1), "]");
            lastNoSigLog = currentMinute;
        }
        IndicatorRelease(signalEmaHandle);
        return;
    }

    // ------------------------------------------------------------------
    // STEP 5 — Valid signal — log it and execute
    // ------------------------------------------------------------------
    Print("\n╔══════════════════════════════════════════════════════════╗");
    Print("║ VALID SIGNAL: ", EnumToString(decidedDirection),
          " [", g_marketRegime, " | CMI=", DoubleToString(cmi, 1), "]   ║");
    Print("╠══════════════════════════════════════════════════════════╣");
    if(decidedDirection == ORDER_TYPE_BUY)
    {
        Print("║ BUY  | Price: ", DoubleToString(currentPrice, 5),
              " > EMA: ", DoubleToString(emaValue[0], 5), "          ║");
        Print("║ EMA delta: +", DoubleToString(emaDelta, 6),
              " | RSI: ", DoubleToString(rsiValue[0], 1), "              ║");
    }
    else
    {
        Print("║ SELL | Price: ", DoubleToString(currentPrice, 5),
              " < EMA: ", DoubleToString(emaValue[0], 5), "          ║");
        Print("║ EMA delta: ", DoubleToString(emaDelta, 6),
              " | RSI: ", DoubleToString(rsiValue[0], 1), "              ║");
    }
    Print("╚══════════════════════════════════════════════════════════╝\n");

    // Execute via existing OpenTrade() (unchanged — keeps all safety checks)
    OpenTrade(decidedDirection);

    // Commit direction if position was actually opened
    if(PositionSelect(_Symbol))
    {
        committedDirection = decidedDirection;
    }

    // Mark bar as processed
    lastSignalBarTime = currentBarTime;

    // ------------------------------------------------------------------
    // CRITICAL: Release the local H1 EMA handle to prevent memory leaks
    // ------------------------------------------------------------------
    IndicatorRelease(signalEmaHandle);
}

//+------------------------------------------------------------------+
//  END OF PATCH FILE
//+------------------------------------------------------------------+
//
//  POST-INTEGRATION CHECKLIST
//  ──────────────────────────
//  [ ] Global variables block (Section A) added near existing handles
//  [ ] InitializeMicrotradingIndicators() called at end of OnInit()
//  [ ] DeinitMicrotradingIndicators()    called at start of OnDeinit()
//  [ ] Old CalculateLotSize()  fully removed, replaced with Patch 1
//  [ ] Old CheckForEntry()     fully removed, replaced with Patch 3
//  [ ] CalculateCMI()          inserted as new function (Patch 2)
//  [ ] GetM1MicrotradingSignal() inserted as new function (Patch 4)
//  [ ] IsMarketTrending() call removed from CheckForEntry (deprecated)
//  [ ] Compile: zero errors expected
//  [ ] Backtest on M5/H1 chart against cent-account data
//  [ ] Verify "PATCH1-LOT: 0.01 lots" appears in journal (not 0.00)
//  [ ] Verify CMI log appears every 60s confirming SWING/TREND
//  [ ] Verify M1 signal log appears in TREND regime
//
//+------------------------------------------------------------------+