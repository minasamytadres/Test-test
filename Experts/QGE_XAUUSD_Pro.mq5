//+------------------------------------------------------------------+
//|                                               QGE_XAUUSD_Pro.mq5 |
//|   Quantitative Gold Edge (QGE) -- statistical microstructure EA   |
//|                    XAUUSD / Gold, hedging accounts               |
//+------------------------------------------------------------------+
#property copyright   "Quantitative Gold Edge (QGE) -- built on Arena.ai Agent Mode"
#property link        "https://arena.ai"
#property version     "1.00"
#property description "Indicator-free statistical EA for XAUUSD. The signal is a weighted probabilistic fusion of four"
#property description "independent pillars: (1) Yang-Zhang / Garman-Klass realized-volatility regime plus variance-ratio"
#property description "persistence, (2) rolling OLS slope with R^2 and Student-t significance, (3) OLS-residual z-score"
#property description "mean reversion, (4) order-flow microstructure: path efficiency, high-low range expansion and"
#property description "momentum acceleration. ATR is used ONLY as a volatility scalar (stops, sizing, spacing) and never"
#property description "as a signal. Includes ATR-normalized geometric-decay pyramiding with fractional-Kelly caps, and a"
#property description "full-lifecycle intelligent hedge: open, manage, ladder/partial unwind, orphan cleanup, time stop."
#property description "Defaults are biased toward action: the signal is pre-computed in OnInit and the first tick trades."

//==================================================================
//  EXPLICIT ASSUMPTIONS (stated up-front, as required)
//==================================================================
//  A1. Instrument : XAUUSD (spot gold vs USD). Contract size 100 oz/lot,
//                   tick size 0.01, 2-3 digit quotes. All price math is
//                   done in log space, so it is scale free and also valid
//                   for XAUUSD variants (GOLD, XAUUSD.a, GOLDM...).
//  A2. Account    : RETAIL HEDGING margin mode (opposite positions on the
//                   same symbol can coexist). If the account is NETTING,
//                   the HedgeManager automatically degrades to
//                   "delta-reduction mode" (partial close of the book)
//                   instead of failing - it never silently mis-hedges.
//  A3. Currency   : Lot sizing is derived from broker-reported
//                   SYMBOL_TRADE_TICK_VALUE with an OrderCalcProfit()
//                   cross-check, so it is correct for USD, EUR or any
//                   other account currency (no hard-coded $100/lot).
//  A4. Leverage   : Any. Margin feasibility is verified with
//                   OrderCalcMargin() before every send.
//  A5. Execution  : Market execution or instant execution both supported;
//                   filling policy resolved per symbol via
//                   CTrade::SetTypeFillingBySymbol(). Slippage in points.
//  A6. Timeframe  : Signal timeframe defaults to H1 (~6000 bars/year for
//                   gold: 23h x 5d x 52w). InpBarsPerYear must match the
//                   chosen timeframe when annualized vol is inspected.
//  A7. Data       : Signals read CLOSED bars only (shift >= 1). No
//                   repainting, no look-ahead. Bar change is confirmed
//                   with an iTime(bar 0) guard.
//  A8. Costs      : Swap is read live from the position. Commission/fees
//                   are read from history deals (DEAL_COMMISSION+DEAL_FEE)
//                   and cached; InpEstRoundTurnCommPerLot is only a
//                   pre-trade estimate used for break-even math.
//==================================================================

#include <Trade/Trade.mqh>

//==================================================================
//  0. INPUT PARAMETERS  (defaults are biased toward ACTION)
//==================================================================

input group "0 -- Identity, activation & diagnostics"
input long             InpMagicNumber            = 905173;   // Magic number (isolates this EA's book)
input ENUM_TIMEFRAMES  InpSignalTF               = PERIOD_H1;// Signal timeframe (all statistics)
input bool             InpTradeOnFirstTick       = true;     // Evaluate + trade on the FIRST tick after attach
input int              InpForceEntryAfterIdleBars= 3;        // Force an entry after N idle closed bars (0 = never)
input bool             InpUseTimer               = true;     // Enable OnTimer for guard/hedge housekeeping
input int              InpTimerSeconds           = 5;        // Timer period (seconds)
input bool             InpRequireGoldSymbol      = false;    // Hard-fail init if symbol is not gold (false = warn only)
input bool             InpVerboseLog             = true;     // Verbose logging of every pillar and decision
input bool             InpShowDashboard          = true;     // On-chart status dashboard (Comment)

input group "1 -- Volatility regime: Yang-Zhang / Garman-Klass / persistence"
input int              InpYZFastWindow           = 20;       // YZ fast window (bars)
input int              InpYZSlowWindow           = 100;      // YZ slow window (bars)
input int              InpBarsPerYear            = 6000;     // Bars per year (annualization scalar)
input int              InpVRWindow               = 120;      // Variance-ratio window (bars)
input int              InpVRLag                  = 5;        // Variance-ratio aggregation lag q
input double           InpVRRef                  = 0.40;     // ln(VR) normalizer (ln(1.5) ~ 0.405)
input int              InpHurstRSWindow          = 128;      // R/S Hurst window (bars)
input double           InpTrendHurst             = 0.55;     // Hurst above this => trending regime
input double           InpMeanRevHurst           = 0.45;     // Hurst below this => mean-reverting regime
input double           InpVolExpansionRatio      = 1.15;     // YZ(fast)/YZ(slow) above this => expanding vol

input group "2 -- Trend pillar: rolling OLS slope, R^2, t-statistic"
input int              InpOLSWindow              = 48;       // OLS window (bars)
input double           InpTStatRef               = 2.00;     // t-stat normalizer (t/TStatRef -> tanh)
input double           InpR2Min                  = 0.00;     // Minimum R^2 to trust the slope (0 = permissive)
input int              InpZWindow                = 48;       // Residual z-score window (bars)
input double           InpZRef                   = 1.50;     // z-score normalizer

input group "3 -- Microstructure pillar: order-flow proxy"
input int              InpEffWindow              = 12;       // Path-efficiency window (bars)
input int              InpMomFast                = 3;        // Fast momentum window (bars)
input int              InpMomSlow                = 12;       // Slow momentum window (bars)
input int              InpRangeWindow            = 6;        // Range-expansion half-window (bars)
input double           InpAccelRef               = 1.00;     // Acceleration normalizer (std devs)
input double           InpExpansionRef           = 0.25;     // Range-expansion normalizer
input double           InpMicroWEff              = 0.55;     // Weight: path efficiency
input double           InpMicroWAccel            = 0.30;     // Weight: momentum acceleration
input double           InpMicroWExp              = 0.15;     // Weight: range expansion

input group "4 -- Probabilistic fusion & confidence gate"
input double           InpConfidenceThreshold    = 0.52;     // Minimum score [0..1] to enter (LOW = trades fast)
input double           InpSigmoidGain            = 4.00;     // Logistic gain on |composite evidence|
input double           InpMinEvidence            = 0.02;     // Minimum |E| for a non-degenerate direction
input double           InpWVol                   = 0.15;     // Pillar weight: volatility/persistence
input double           InpWTrend                 = 0.35;     // Pillar weight: OLS trend
input double           InpWMeanRev               = 0.20;     // Pillar weight: residual z-score
input double           InpWMicro                 = 0.30;     // Pillar weight: microstructure
input bool             InpRegimeAdaptiveWeights  = true;     // Re-weight pillars by Hurst persistence
input double           InpRegimeTilt             = 0.50;     // Regime tilt strength (0 = static weights)
input bool             InpAllowLong              = true;     // Permit long entries
input bool             InpAllowShort             = true;     // Permit short entries
input int              InpMaxTradesPerDay        = 20;       // Daily entry cap (permissive)

input group "5 -- Stops & targets (ATR = volatility SCALAR only)"
input int              InpATRPeriod              = 14;       // ATR period (scalar)
input double           InpSL_ATR_Mult            = 2.00;     // Stop-loss distance = mult x ATR
input double           InpTP_RR                  = 2.00;     // Take-profit = R:R multiple of SL distance
input int              InpStopLevelBufferPts     = 2;        // Extra buffer beyond broker stops level (points)
input bool             InpUseBreakEven           = true;     // Move book SL to break-even
input double           InpBreakEvenAtR           = 0.80;     // Break-even trigger (R of favorable excursion)
input double           InpBreakEvenLockR         = 0.10;     // Break-even lock-in (R beyond weighted avg entry)
input bool             InpUseTrailing            = true;     // ATR trailing stop on the aggregate book
input double           InpTrailStartR            = 1.00;     // Trailing starts after this many R in profit
input double           InpTrailATR               = 1.50;     // Trailing distance (x ATR)

input group "6 -- Risk & money management (account aware)"
input double           InpRiskPctOfEquity        = 1.00;     // Risk per base entry (% of EQUITY)
input double           InpMaxTotalRiskPct        = 4.00;     // Max aggregate open risk (% of equity)
input double           InpMaxTotalLots           = 5.00;     // Hard cap on total open lots (book+hedge)
input int              InpMaxSpreadPoints        = 120;      // Max spread (points) -- generous for gold
input double           InpMaxSpreadPctOfATR      = 0.35;     // Max spread as fraction of ATR
input double           InpDailyLossLimitPct      = 8.00;     // Daily loss limit (% of day-start equity)
input double           InpEquityFloorDDPct       = 30.00;    // Equity-floor kill switch (% DD from peak)
input bool             InpKillSwitchCloseAll     = false;    // Kill switch also flattens the book
input double           InpMarginCushion          = 3.00;     // Required free margin / needed margin
input int              InpSlippagePoints         = 30;       // Max deviation (points)
input int              InpOrderRetries           = 3;        // Retries on requote/price-changed/timeout
input int              InpRetryDelayMs           = 250;      // Delay between retries (live only)
input double           InpEstRoundTurnCommPerLot = 7.00;     // Estimated round-turn commission per lot (USD)

input group "7 -- Dynamic pyramiding (geometric decay + fractional Kelly)"
input bool             InpEnablePyramiding       = true;     // Allow scale-ins
input int              InpMaxScaleIns            = 3;        // Max add-ons per directional book
input double           InpSizeDecay              = 0.60;     // Geometric decay of add-on risk
input double           InpAddOnRiskScalePct      = 60.00;    // First add-on risk as % of base risk
input double           InpSpacingATR             = 1.00;     // Min spacing between entries (x ATR)
input double           InpAddOnMinScore          = 0.55;     // Min score for an add-on
input bool             InpAddOnRequireProfit     = true;     // Add-ons only while the book is in profit
input double           InpKellyFraction          = 0.25;     // Fractional Kelly cap (0.25 = quarter Kelly)

input group "8 -- Intelligent hedge (full lifecycle)"
input bool             InpEnableHedging          = true;     // Enable hedge manager
input double           InpHedgeDDTriggerPct      = 3.00;     // Drawdown trigger (% - peak DD or open-book loss)
input double           InpHedgeBaseRatio         = 0.35;     // Severity scaling at the trigger (x required hedge)
input double           InpHedgeMaxRatio          = 1.00;     // Severity scaling at 2x trigger (1.0 = delta neutral)
input double           InpHedgeMaxLots           = 3.00;     // Absolute cap on hedge lots
input double           InpHedgeTargetRecoveryR   = 0.00;     // Recovery target on unwind (R; 0 = break-even)
input double           InpHedgeUnwindATR         = 1.50;     // Expected unwind excursion (x ATR)
input double           InpHedgeFlipMinScore      = 0.90;     // Score needed for a regime-flip hedge trigger
input int              InpHedgeFlipConfirmBars   = 1;        // Consecutive flip bars required (1 = immediate)
input double           InpHedgeReleaseDDFraction = 0.35;     // Full unwind once DD falls to this fraction of trigger
input double           InpHedgeTakeProfitR       = 1.00;     // Bank hedge profit at this multiple of R
input double           InpHedgePartialClosePct   = 50.00;    // % of remaining hedge closed per TP level
input int              InpHedgeUnwindLadderSteps = 3;        // Ladder tranches for graduated unwind
input int              InpHedgeMaxAgeHours       = 72;       // Anti-lock time stop on the hedge (hours)

input group "9 -- Session filter (OFF by default so nothing blocks entry)"
input bool             InpUseSessionFilter       = false;    // Restrict entries to a session window
input int              InpSessionStartHour       = 7;        // Session start (server hour, inclusive)
input int              InpSessionEndHour         = 20;       // Session end (server hour, exclusive)
input bool             InpSkipLateFriday         = false;    // No new entries late Friday

input group "10 -- Position tags"
input string           InpTagBook                = "QGE-B";  // Comment tag: base entry
input string           InpTagPyramid             = "QGE-P";  // Comment tag: scale-in
input string           InpTagHedge               = "QGE-H";  // Comment tag: hedge leg

//==================================================================
//  1. SHARED STRUCTURES
//==================================================================

//--- one full evaluation of the statistical signal engine
struct SSignal
  {
   datetime          bar_time;        // open time of the CLOSED bar the signal describes
   bool              valid;           // all estimators produced finite output
   int               direction;       // +1 long, -1 short, 0 undecided
   double            score;           // probabilistic confidence in [0,1]
   double            evidence;        // signed composite evidence E in [-1,1]
   //--- pillar evidences, each in [-1,+1]
   double            e_vol;
   double            e_trend;
   double            e_meanrev;
   double            e_micro;
   //--- effective (regime adapted, normalized) weights, sum = 1
   double            w_vol;
   double            w_trend;
   double            w_meanrev;
   double            w_micro;
   //--- diagnostics
   double            sigma_yz;        // per-bar YZ volatility (log units)
   double            sigma_yz_ann;    // annualized
   double            sigma_gk_ann;    // annualized Garman-Klass (cross-check)
   double            vol_ratio;       // YZ(fast)/YZ(slow)
   double            hurst_vr;        // Hurst from variance ratio
   double            hurst_rs;        // Hurst from rescaled range
   double            hurst;           // average
   double            vr;              // variance ratio VR(q)
   double            slope;           // OLS slope on log price (per bar)
   double            drift_ann;       // annualized log drift
   double            r2;              // coefficient of determination
   double            tstat;           // Student-t of the slope
   double            zresid;          // z-score of newest OLS residual
   double            efficiency;      // path efficiency [0,1]
   double            range_exp;       // range expansion ratio - 1
   double            accel;           // momentum acceleration (std devs)
   double            atr;             // ATR at shift 1 (SCALAR only)
   double            spread_price;    // Ask-Bid at evaluation time
   int               regime;          // +1 trending, -1 mean-reverting, 0 neutral (Hurst bands)
   bool              vol_expanding;   // YZ(fast)/YZ(slow) >= InpVolExpansionRatio
   void              Reset()
     {
      bar_time=0; valid=false; direction=0; score=0.0; evidence=0.0;
      e_vol=0.0; e_trend=0.0; e_meanrev=0.0; e_micro=0.0;
      w_vol=0.0; w_trend=0.0; w_meanrev=0.0; w_micro=0.0;
      sigma_yz=0.0; sigma_yz_ann=0.0; sigma_gk_ann=0.0; vol_ratio=0.0;
      hurst_vr=0.5; hurst_rs=0.5; hurst=0.5; vr=1.0;
      slope=0.0; drift_ann=0.0; r2=0.0; tstat=0.0; zresid=0.0;
      efficiency=0.0; range_exp=0.0; accel=0.0; atr=0.0; spread_price=0.0;
      regime=0; vol_expanding=false;
     }
  };

//--- aggregate state of this EA's book on this symbol
struct SBookStats
  {
   int               total_positions;   // all positions with our magic
   int               book_positions;    // directional legs (base + pyramids)
   int               hedge_positions;   // hedge legs
   double            book_long_lots;
   double            book_short_lots;
   double            book_net_lots;     // signed: long - short (directional book)
   double            book_wavg;         // volume-weighted average entry of the book
   double            book_profit;       // floating price P&L of the book
   double            book_swap;
   double            book_comm;         // commission+fees already charged (cached)
   double            book_pnl;          // profit + swap + comm  (all-in)
   double            book_last_entry;   // price of the most recent book entry
   datetime          book_last_time;    // open time of the most recent book entry
   datetime          book_first_time;   // open time of the oldest book entry
   int               scale_ins;         // number of pyramid legs currently open
   double            hedge_lots;        // absolute hedge volume
   double            hedge_signed;      // signed hedge volume
   double            hedge_wavg;        // volume-weighted hedge entry
   double            hedge_profit;
   double            hedge_swap;
   double            hedge_comm;
   double            hedge_pnl;
   datetime          hedge_first_time;
   double            total_lots;        // book + hedge absolute volume
   double            net_signed_lots;   // book_net_lots + hedge_signed (true delta)
   double            total_pnl;         // all-in floating P&L of every leg
   double            margin_used;       // margin locked by our positions
   ulong             key;               // cheap checksum for change detection
   void              Reset()
     {
      total_positions=0; book_positions=0; hedge_positions=0;
      book_long_lots=0.0; book_short_lots=0.0; book_net_lots=0.0; book_wavg=0.0;
      book_profit=0.0; book_swap=0.0; book_comm=0.0; book_pnl=0.0;
      book_last_entry=0.0; book_last_time=0; book_first_time=0; scale_ins=0;
      hedge_lots=0.0; hedge_signed=0.0; hedge_wavg=0.0;
      hedge_profit=0.0; hedge_swap=0.0; hedge_comm=0.0; hedge_pnl=0.0;
      hedge_first_time=0;
      total_lots=0.0; net_signed_lots=0.0; total_pnl=0.0; margin_used=0.0; key=0;
     }
  };

//--- hedge lifecycle state (persisted through terminal global variables)
struct SHedgeState
  {
   bool              active;          // at least one hedge leg open
   double            born_lots;       // volume the hedge was born with (for the ladder)
   double            closed_lots;     // volume already unwound
   datetime          born_time;       // when the hedge was opened
   double            born_price;      // weighted hedge entry price
   double            anchor_R;        // R (money) of the book at hedge birth
   double            born_pnl;        // all-in floating P&L of the whole sleeve at birth
   int               tp_levels_used;  // how many hedge-TP levels were banked
   double            last_tp_level;   // R multiple of the last banked level
   int               flip_bars;       // consecutive regime-flip confirmations
                     SHedgeState()
     {
      active=false; born_lots=0.0; closed_lots=0.0; born_time=0; born_price=0.0;
      anchor_R=0.0; born_pnl=0.0; tp_levels_used=0; last_tp_level=0.0; flip_bars=0;
     }
  };

//==================================================================
//  2. GLOBAL STATE
//==================================================================
CTrade        g_trade;                 // single trade object, magic-bound
SSignal       g_signal;                // cached heavy signal (max 1 recompute / closed bar)
SBookStats    g_book;                  // cached aggregate book
SHedgeState   g_hedge;                 // hedge lifecycle state

datetime      g_lastBarTime   = 0;     // open time of the CLOSED bar behind the cached signal
bool          g_warmupReady   = false; // enough closed bars for every estimator
bool          g_forceFirstTick= false; // one-shot: evaluate + trade on the first tick
int           g_idleBars      = 0;     // closed bars since the last entry attempt with a flat book
bool          g_haltNewEntries= false; // set by daily-loss / equity-floor guards
bool          g_killFired     = false; // kill switch already executed (no repeat flattening)
datetime      g_lastDailyScan = 0;     // throttle for realized-P&L history scan
double        g_realizedToday = 0.0;   // realized P&L since day start (cached)
datetime      g_lastDash      = 0;     // dashboard throttle
datetime      g_lastLog       = 0;     // generic log throttle
int           g_entriesToday  = 0;     // entries opened since day start
datetime      g_entryDay      = 0;     // day the entry counter belongs to
double        g_symbolPoint   = 0.01;
int           g_digits        = 2;
double        g_volMin        = 0.01;
double        g_volMax        = 100.0;
double        g_volStep       = 0.01;
double        g_tickSize      = 0.01;
double        g_tickValue     = 1.0;
double        g_contractSize  = 100.0;
long          g_stopsLevel    = 0;
long          g_freezeLevel   = 0;
bool          g_hedgingAccount= false;
bool          g_goldSymbol    = false;
double        g_bookRPrice    = 0.0;   // R (price distance) of the aggregate book, persisted

//==================================================================
//  3. SMALL MATH / UTILITY PRIMITIVES
//==================================================================

//--- hyperbolic tangent: MQL5 has no MathTanh(), so it is built from exp().
//    tanh(x) = (e^{2x} - 1) / (e^{2x} + 1), guarded against overflow.
double Tanh(const double x)
  {
   if(x >  20.0) return( 1.0);
   if(x < -20.0) return(-1.0);
   double e = MathExp(2.0*x);
   return((e - 1.0)/(e + 1.0));
  }

//--- logistic function  s(x) = 1/(1+e^-x)  in (0,1), overflow-guarded
double Sigmoid(const double x)
  {
   if(x >  35.0) return(1.0);
   if(x < -35.0) return(0.0);
   return(1.0/(1.0 + MathExp(-x)));
  }

double ClampD(const double v, const double lo, const double hi)
  {
   if(v < lo) return(lo);
   if(v > hi) return(hi);
   return(v);
  }

double SafeLog(const double v)  { return(MathLog(MathMax(v,1.0e-12))); }
double SafeDiv(const double a, const double b, const double fallback)
  {
   if(MathAbs(b) < 1.0e-12) return(fallback);
   return(a/b);
  }
int SignD(const double v)
  {
   if(v >  1.0e-12) return( 1);
   if(v < -1.0e-12) return(-1);
   return(0);
  }
bool IsFiniteD(const double v) { return(MathIsValidNumber(v)); }

//--- number of decimal places implied by the broker volume step
int VolumeDigits()
  {
   double s = g_volStep;
   if(s <= 0.0) return(2);
   int d = 0;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1.0e-10) { s *= 10.0; d++; }
   return(d);
  }

//--- Normalize a volume to broker constraints.
//    RULE: round DOWN to the volume step and REJECT anything below
//    SYMBOL_VOLUME_MIN. We never silently bump a sub-minimum request up,
//    because that would inflate realized risk above the risk budget.
//    Capping to VOLUME_MAX / InpMaxTotalLots IS allowed (that is a limit,
//    not a bump).
double NormalizeVolume(const double raw, bool &ok)
  {
   ok = false;
   if(!IsFiniteD(raw) || raw <= 0.0) return(0.0);
   double v = raw;
   if(g_volStep > 0.0)
      v = MathFloor(v/g_volStep + 1.0e-8)*g_volStep;      // floor to step
   v = NormalizeDouble(v, VolumeDigits());
   if(v < g_volMin - 1.0e-9)                               // REJECT sub-minimum
      return(0.0);
   double cap = MathMin(g_volMax, InpMaxTotalLots);
   if(v > cap)
     {
      v = MathFloor(cap/g_volStep + 1.0e-8)*g_volStep;
      v = NormalizeDouble(v, VolumeDigits());
      if(v < g_volMin - 1.0e-9) return(0.0);
     }
   ok = true;
   return(v);
  }

double NormalizePrice(const double p) { return(NormalizeDouble(p, g_digits)); }

//--- minimum legal stop distance in price units (broker stops level + buffer)
double MinStopDistance()
  {
   double pts = (double)g_stopsLevel + (double)InpStopLevelBufferPts;
   if(pts < 1.0) pts = 1.0;
   return(NormalizeDouble(pts*g_symbolPoint, g_digits));
  }

//--- human readable trade-server return code
string RetcodeText(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_DONE:            return("DONE");
      case TRADE_RETCODE_DONE_PARTIAL:    return("DONE_PARTIAL");
      case TRADE_RETCODE_PLACED:          return("PLACED");
      case TRADE_RETCODE_REQUOTE:         return("REQUOTE");
      case TRADE_RETCODE_REJECT:          return("REJECT");
      case TRADE_RETCODE_CANCEL:          return("CANCELLED_BY_USER");
      case TRADE_RETCODE_ERROR:           return("COMMON_ERROR");
      case TRADE_RETCODE_TIMEOUT:         return("TIMEOUT");
      case TRADE_RETCODE_INVALID:         return("INVALID_REQUEST");
      case TRADE_RETCODE_INVALID_VOLUME:  return("INVALID_VOLUME");
      case TRADE_RETCODE_INVALID_PRICE:   return("INVALID_PRICE");
      case TRADE_RETCODE_INVALID_STOPS:   return("INVALID_STOPS");
      case TRADE_RETCODE_TRADE_DISABLED:  return("TRADE_DISABLED");
      case TRADE_RETCODE_MARKET_CLOSED:   return("MARKET_CLOSED");
      case TRADE_RETCODE_NO_MONEY:        return("NOT_ENOUGH_MONEY");
      case TRADE_RETCODE_PRICE_CHANGED:   return("PRICE_CHANGED");
      case TRADE_RETCODE_PRICE_OFF:       return("NO_QUOTE");
      case TRADE_RETCODE_TOO_MANY_REQUESTS:return("TOO_MANY_REQUESTS");
      case TRADE_RETCODE_NO_CHANGES:      return("NO_CHANGES");
      case TRADE_RETCODE_CONNECTION:      return("NO_CONNECTION");
      case TRADE_RETCODE_LOCKED:          return("REQUEST_LOCKED");
      case TRADE_RETCODE_FROZEN:          return("ORDER_OR_POSITION_FROZEN");
      case TRADE_RETCODE_INVALID_FILL:    return("INVALID_FILL_TYPE");
      case TRADE_RETCODE_LIMIT_VOLUME:    return("SYMBOL_VOLUME_LIMIT");
      case TRADE_RETCODE_POSITION_CLOSED: return("POSITION_ALREADY_CLOSED");
     }
   return("RETCODE_"+IntegerToString((long)rc));
  }

//--- retcodes worth an immediate retry (transient price/queue conditions)
bool IsRetryableRetcode(const uint rc)
  {
   return(rc==TRADE_RETCODE_REQUOTE       ||
          rc==TRADE_RETCODE_PRICE_CHANGED ||
          rc==TRADE_RETCODE_PRICE_OFF     ||
          rc==TRADE_RETCODE_TIMEOUT       ||
          rc==TRADE_RETCODE_CONNECTION    ||
          rc==TRADE_RETCODE_TOO_MANY_REQUESTS);
  }

bool IsSuccessRetcode(const uint rc)
  {
   return(rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_DONE_PARTIAL || rc==TRADE_RETCODE_PLACED);
  }

//--- terminal global variables (persist peak equity / R anchor across re-inits)
string GVName(const string tag)
  {
   return("QGE_"+IntegerToString(InpMagicNumber)+"_"+
          IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"_"+tag);
  }
double GVGet(const string tag, const double def)
  {
   string n = GVName(tag);
   if(!GlobalVariableCheck(n)) return(def);
   return(GlobalVariableGet(n));
  }
void   GVSet(const string tag, const double v) { GlobalVariableSet(GVName(tag), v); }
void   GVDel(const string tag)                 { if(GlobalVariableCheck(GVName(tag))) GlobalVariableDel(GVName(tag)); }

//--- throttled logging (uses simulated time so it behaves inside the tester)
bool LogElapsed(datetime &anchor, const int seconds)
  {
   datetime now = TimeCurrent();
   if(anchor != 0 && (int)(now - anchor) < seconds) return(false);
   anchor = now;
   return(true);
  }

void Verbose(const string msg) { if(InpVerboseLog) Print("QGE: ", msg); }
void VerboseT(const string msg, const int everySec)
  {
   if(!InpVerboseLog) return;
   if(LogElapsed(g_lastLog, everySec)) Print("QGE: ", msg);
  }

//==================================================================
//  4. SIGNAL ENGINE
//     All statistics are computed from CLOSED bars only (array index 0
//     == shift 1). ATR is fetched once per computation and used purely
//     as a volatility scalar for stops/sizing/spacing.
//==================================================================
class CSignalEngine
  {
private:
   int               m_hATR;      // iATR handle - created ONCE in Init()
   MqlRates          m_rates[];   // series array, index i == shift i+1
   int               m_have;      // number of closed bars currently loaded
   double            m_atr;       // ATR at shift 1 (scalar)

   //--- unbiased sample variance of a series
   double            SampleVariance(const double &v[], const int n)
     {
      if(n < 2) return(0.0);
      double mean=0.0;
      for(int i=0;i<n;i++) mean += v[i];
      mean /= (double)n;
      double acc=0.0;
      for(int i=0;i<n;i++) { double d=v[i]-mean; acc += d*d; }
      return(acc/(double)(n-1));
     }

   //--- slope of OLS y = a + b*x over paired points (used by the R/S Hurst)
   double            LineSlope(const double &x[], const double &y[], const int n)
     {
      if(n < 2) return(0.0);
      double sx=0.0, sy=0.0, sxy=0.0, sxx=0.0;
      for(int i=0;i<n;i++) { sx+=x[i]; sy+=y[i]; sxy+=x[i]*y[i]; sxx+=x[i]*x[i]; }
      double den = (double)n*sxx - sx*sx;
      if(MathAbs(den) < 1.0e-18) return(0.0);
      return(((double)n*sxy - sx*sy)/den);
     }

   //--- close-to-close variance fallback (guarantees a positive sigma)
   double            CloseCloseVariance(const int n)
     {
      if(m_have < n+1) return(0.0);
      double r[];
      if(ArrayResize(r,n) != n) return(0.0);
      for(int i=0;i<n;i++) r[i] = SafeLog(m_rates[i].close/m_rates[i+1].close);
      return(SampleVariance(r,n));
     }

   //---------------------------------------------------------------
   //  YANG-ZHANG (1880) realized volatility.
   //  Decomposes variance into three unbiased pieces and weights them
   //  optimally under a Brownian model with drift + opening jumps:
   //
   //     sigma^2_YZ = sigma^2_O + k*sigma^2_C + (1-k)*sigma^2_RS
   //     k            = 0.34 / (1.34 + (n+1)/(n-1))
   //
   //  with, for bar i (O,H,L,C) and previous close C_{i-1}:
   //     o_i  = ln(O_i / C_{i-1})        overnight (open jump) log return
   //     c_i  = ln(C_i / O_i)            open-to-close log return
   //     sigma^2_O  = 1/(n-1) * Sum (o_i - o_bar)^2
   //     sigma^2_C  = 1/(n-1) * Sum (c_i - c_bar)^2
   //     sigma^2_RS = 1/n * Sum GK_i     (Garman-Klass / Rogers-Satchell)
   //     GK_i = 0.5*ln(H_i/L_i)^2 - (2*ln2 - 1)*ln(C_i/O_i)^2
   //
   //  Why: GK is ~7.4x more efficient than close-to-close variance and,
   //  unlike Parkinson, it is drift-independent and uses the open, so it
   //  absorbs the gold overnight gap (Asian open) that dominates XAUUSD.
   //---------------------------------------------------------------
   bool              YangZhang(const int n, double &sigmaBar, double &sigmaGK)
     {
      sigmaBar=0.0; sigmaGK=0.0;
      if(n < 3 || m_have < n+1) return(false);
      double ov[], cl[];
      if(ArrayResize(ov,n)!=n || ArrayResize(cl,n)!=n) return(false);
      double sRS=0.0, oSum=0.0, cSum=0.0;
      double GK_CO = 2.0*MathLog(2.0) - 1.0;         // 2ln2-1 = 0.3862944
      for(int i=0;i<n;i++)
        {
         double O=m_rates[i].open, H=m_rates[i].high, L=m_rates[i].low,
                C=m_rates[i].close, Cp=m_rates[i+1].close;
         if(O<=0.0 || H<=0.0 || L<=0.0 || C<=0.0 || Cp<=0.0 || H<L) return(false);
         ov[i] = SafeLog(O/Cp);
         cl[i] = SafeLog(C/O);
         double lhl = SafeLog(H/L);
         double lco = SafeLog(C/O);
         sRS  += 0.5*lhl*lhl - GK_CO*lco*lco;
         oSum += ov[i];
         cSum += cl[i];
        }
      double oBar=oSum/(double)n, cBar=cSum/(double)n;
      double vO=0.0, vC=0.0;
      for(int i=0;i<n;i++)
        {
         double a=ov[i]-oBar, b=cl[i]-cBar;
         vO += a*a; vC += b*b;
        }
      vO /= (double)(n-1);
      vC /= (double)(n-1);
      double vRS = sRS/(double)n;
      double k   = 0.34/(1.34 + (double)(n+1)/(double)(n-1));
      double var = vO + k*vC + (1.0-k)*vRS;
      if(var <= 1.0e-18) var = CloseCloseVariance(n);   // pathological-data fallback
      if(var <= 1.0e-18) return(false);
      sigmaBar = MathSqrt(var);
      sigmaGK  = MathSqrt(MathMax(vRS,0.0));
      return(IsFiniteD(sigmaBar) && sigmaBar > 0.0);
     }

   //---------------------------------------------------------------
   //  VARIANCE RATIO TEST (Lo & MacKinlay) + implied Hurst exponent.
   //     r_i  = ln(C_i/C_{i+1})                    1-bar log returns
   //     R_j  = ln(C_j/C_{j+q}) = Sum_{i=j..j+q-1} r_i
   //     VR(q)= Var(R) / (q * Var(r))
   //  Under a random walk VR = 1. VR > 1 => positive autocorrelation
   //  (persistent / trending microstructure). VR < 1 => negative
   //  autocorrelation (mean reverting, liquidity-provision dominated).
   //  For fractional Brownian motion Var(R_q) = q^(2H-1) Var(r_1), hence
   //     H = 0.5 * ( ln VR / ln q + 1 )
   //---------------------------------------------------------------
   bool              VarianceRatio(const int n, const int q, double &vr, double &hVR)
     {
      vr=1.0; hVR=0.5;
      if(q < 2 || n < q+10 || m_have < n+1) return(false);
      double r[];
      if(ArrayResize(r,n)!=n) return(false);
      for(int i=0;i<n;i++) r[i]=SafeLog(m_rates[i].close/m_rates[i+1].close);
      int cnt = n - q + 1;
      if(cnt < 5) return(false);
      double R[];
      if(ArrayResize(R,cnt)!=cnt) return(false);
      for(int j=0;j<cnt;j++)
        {
         double s=0.0;
         for(int i=j;i<j+q;i++) s += r[i];
         R[j]=s;
        }
      double v1=SampleVariance(r,n), vq=SampleVariance(R,cnt);
      if(v1 <= 1.0e-18 || vq <= 1.0e-18) return(false);
      vr = vq/((double)q*v1);
      if(vr <= 1.0e-12) return(false);
      hVR = ClampD(0.5*(SafeLog(vr)/SafeLog((double)q) + 1.0), 0.05, 0.95);
      return(true);
     }

   //---------------------------------------------------------------
   //  HURST EXPONENT via multi-scale rescaled range (R/S) analysis.
   //  For block length s:
   //     Y_k = Sum_{i=1..k} (r_i - r_bar)      cumulative deviation
   //     R(s)= max(Y) - min(Y)                 range
   //     S(s)= sample stdev of the block
   //     (R/S)(s) ~ C * s^H     =>   H = slope of ln(R/S) on ln(s)
   //  Scales used: 8,16,32,64 (each must yield >= 2 blocks). A regression
   //  over several scales is far more stable than the single-window
   //  ln(R/S)/ln(n) estimator.
   //---------------------------------------------------------------
   bool              HurstRS(const int n, double &hRS)
     {
      hRS=0.5;
      if(n < 32 || m_have < n+1) return(false);
      double r[];
      if(ArrayResize(r,n)!=n) return(false);
      for(int i=0;i<n;i++)                       // ordered OLDEST -> NEWEST
         r[i] = SafeLog(m_rates[n-1-i].close/m_rates[n-i].close);
      int    scales[4]; int ns=0;
      for(int s=8; s<=n/2 && ns<4; s*=2) scales[ns++]=s;
      if(ns < 2) return(false);
      double lx[], ly[];
      if(ArrayResize(lx,ns)!=ns || ArrayResize(ly,ns)!=ns) return(false);
      int pts=0;
      for(int si=0; si<ns; si++)
        {
         int s = scales[si];
         int blocks = n/s;
         if(blocks < 1) continue;
         double rsSum=0.0; int used=0;
         for(int b=0;b<blocks;b++)
           {
            int off=b*s;
            double mean=0.0;
            for(int i=0;i<s;i++) mean += r[off+i];
            mean /= (double)s;
            double cum=0.0, hi=-1.0e300, lo=1.0e300, vsum=0.0;
            for(int i=0;i<s;i++)
              {
               double d=r[off+i]-mean;
               cum += d; vsum += d*d;
               if(cum>hi) hi=cum;
               if(cum<lo) lo=cum;
              }
            double sd=MathSqrt(vsum/(double)(s-1));
            if(sd <= 1.0e-12) continue;
            rsSum += (hi-lo)/sd;                 // R/S of this block
            used++;
           }
         if(used==0) continue;
         double avgRS = rsSum/(double)used;
         if(avgRS <= 1.0e-12) continue;
         lx[pts]=SafeLog((double)s);
         ly[pts]=SafeLog(avgRS);
         pts++;
        }
      if(pts < 2) return(false);
      double xs[], ys[];
      if(ArrayResize(xs,pts)!=pts || ArrayResize(ys,pts)!=pts) return(false);
      for(int i=0;i<pts;i++){ xs[i]=lx[i]; ys[i]=ly[i]; }
      hRS = ClampD(LineSlope(xs,ys,pts), 0.05, 0.95);
      return(true);
     }

   //---------------------------------------------------------------
   //  ROLLING ORDINARY LEAST SQUARES on log price.
   //     x_i = n-1-i   (i=0 is the newest closed bar => x increases with
   //                    time, so a positive slope is an uptrend)
   //     y_i = ln(C_i)
   //     beta  = (n*Sxy - Sx*Sy) / (n*Sxx - Sx^2)
   //     alpha = y_bar - beta*x_bar
   //     R^2   = 1 - SSE/SST                     explanatory power
   //     s^2   = SSE/(n-2)                       residual variance
   //     se(b) = sqrt( s^2 / Sum(x-x_bar)^2 )
   //     t     = beta / se(beta)                 Student-t significance
   //     z     = (y_0 - fit_0)/s                 residual z-score (newest)
   //  The t-statistic (not the raw slope) is the decision variable: it is
   //  scale free and already penalizes noisy fits. Sx/Sxx use the closed
   //  forms of Sum i and Sum i^2 to avoid an extra loop.
   //---------------------------------------------------------------
   bool              OLS(const int n, double &slope, double &r2, double &tstat, double &zres)
     {
      slope=0.0; r2=0.0; tstat=0.0; zres=0.0;
      if(n < 6 || m_have < n) return(false);
      double y[];
      if(ArrayResize(y,n)!=n) return(false);
      double Sx  = (double)n*(double)(n-1)/2.0;
      double Sxx = (double)(n-1)*(double)n*(double)(2*n-1)/6.0;
      double Sy=0.0, Sxy=0.0;
      for(int i=0;i<n;i++)
        {
         if(m_rates[i].close <= 0.0) return(false);
         y[i] = SafeLog(m_rates[i].close);
         Sy  += y[i];
         Sxy += (double)(n-1-i)*y[i];
        }
      double den = (double)n*Sxx - Sx*Sx;
      if(MathAbs(den) < 1.0e-18) return(false);
      double b   = ((double)n*Sxy - Sx*Sy)/den;
      double ybar= Sy/(double)n;
      double xbar= Sx/(double)n;
      double a   = ybar - b*xbar;
      double SST=0.0, SSE=0.0;
      for(int i=0;i<n;i++)
        {
         double fit = a + b*(double)(n-1-i);
         double e   = y[i]-fit;
         double dy  = y[i]-ybar;
         SSE += e*e;
         SST += dy*dy;
        }
      r2 = (SST > 1.0e-18) ? ClampD(1.0 - SSE/SST, 0.0, 1.0) : 0.0;
      slope = b;
      double s2  = SSE/(double)(n-2);
      double sxx = Sxx - Sx*Sx/(double)n;             // Sum (x-x_bar)^2
      if(s2 <= 1.0e-18 || sxx <= 1.0e-18)
        {                                             // (near) perfect fit: t undefined
         tstat = 0.0; zres = 0.0;
         return(true);
        }
      double s  = MathSqrt(s2);
      double se = MathSqrt(s2/sxx);
      tstat = b/se;
      double x0 = (double)(n-1);                      // newest closed bar
      zres  = (y[0] - (a + b*x0))/s;
      return(IsFiniteD(tstat) && IsFiniteD(zres));
     }

   //---------------------------------------------------------------
   //  MICROSTRUCTURE (order-flow proxy, no indicators involved)
   //   d_i = ln(C_i/C_{i+1})                       per-bar log returns
   //   EF  = |Sum_{i<nE} d_i| / Sum_{i<nE} |d_i|   path efficiency in
   //         [0,1]: 1 = one-sided flow (aggressive takers), 0 = churn
   //   ACC = (mean_{nf} d - mean_{ns} d) / sd_{ns} momentum ACCELERATION
   //         (2nd derivative of log price) in units of return stdev
   //   RE  = mean_{i<nR}(H-L) / mean_{nR<=i<2nR}(H-L) - 1
   //         high-low EXPANSION DELTA: fresh participation / liquidity
   //         consumption vs the previous, equally sized window.
   //---------------------------------------------------------------
   bool              Micro(double &eff, double &rangeExp, double &accel, int &dirRef)
     {
      eff=0.0; rangeExp=0.0; accel=0.0; dirRef=0;
      int nE=InpEffWindow, nf=InpMomFast, ns=InpMomSlow, nr=InpRangeWindow;
      if(nE<2 || nf<1 || ns<nf+1 || nr<2) return(false);
      int m = (int)MathMax(ns,nE);
      if(m_have < m+1 || m_have < 2*nr) return(false);
      double d[];
      if(ArrayResize(d,m)!=m) return(false);
      for(int i=0;i<m;i++)
        {
         if(m_rates[i].close<=0.0 || m_rates[i+1].close<=0.0) return(false);
         d[i]=SafeLog(m_rates[i].close/m_rates[i+1].close);
        }
      double sum=0.0, absum=0.0;
      for(int i=0;i<nE;i++){ sum+=d[i]; absum+=MathAbs(d[i]); }
      eff = (absum>1.0e-18) ? ClampD(MathAbs(sum)/absum,0.0,1.0) : 0.0;
      dirRef = SignD(sum);
      double mf=0.0; for(int i=0;i<nf;i++) mf+=d[i];
      mf /= (double)nf;
      double ms=0.0; for(int i=0;i<ns;i++) ms+=d[i];
      ms /= (double)ns;
      double var=0.0;
      for(int i=0;i<ns;i++){ double e=d[i]-ms; var+=e*e; }
      var /= (double)(ns-1);
      double sd=MathSqrt(var);
      accel = (sd>1.0e-18) ? (mf-ms)/sd : 0.0;
      double A=0.0, B=0.0;
      for(int i=0;i<nr;i++)    A += (m_rates[i].high - m_rates[i].low);
      for(int i=nr;i<2*nr;i++) B += (m_rates[i].high - m_rates[i].low);
      A /= (double)nr; B /= (double)nr;
      rangeExp = (B>1.0e-12) ? A/B - 1.0 : 0.0;
      return(IsFiniteD(eff) && IsFiniteD(accel) && IsFiniteD(rangeExp));
     }

public:
                     CSignalEngine()
     {
      m_hATR=INVALID_HANDLE; m_have=0; m_atr=0.0;
      ArraySetAsSeries(m_rates,true);
     }
                    ~CSignalEngine() { Deinit(); }

   //--- create the (single) indicator handle. Called once from OnInit.
   bool              Init()
     {
      ResetLastError();
      m_hATR = iATR(_Symbol, InpSignalTF, InpATRPeriod);
      if(m_hATR==INVALID_HANDLE)
        {
         PrintFormat("QGE FATAL: iATR handle creation failed (err=%d)", _LastError);
         return(false);
        }
      return(true);
     }

   void              Deinit()
     {
      if(m_hATR!=INVALID_HANDLE)
        {
         IndicatorRelease(m_hATR);
         m_hATR=INVALID_HANDLE;
        }
      m_have=0; m_atr=0.0;
     }

   //--- minimal warm-up window: just enough bars for the LONGEST estimator
   int               RequiredBars()
     {
      int need = InpATRPeriod + 3;
      need = (int)MathMax(need, InpYZSlowWindow + 2);
      need = (int)MathMax(need, InpYZFastWindow + 2);
      need = (int)MathMax(need, InpVRWindow + InpVRLag + 2);
      need = (int)MathMax(need, InpHurstRSWindow + 2);
      need = (int)MathMax(need, InpOLSWindow + 2);
      need = (int)MathMax(need, InpZWindow + 2);
      need = (int)MathMax(need, (int)MathMax(InpMomSlow,InpEffWindow) + 2);
      need = (int)MathMax(need, 2*InpRangeWindow + 2);
      return(need + 2);
     }

   int               BarsAvailable() { return(iBars(_Symbol, InpSignalTF)); }
   double            ATR()           { return(m_atr); }
   int               Have()          { return(m_have); }

   //--- load closed-bar history + refresh the ATR scalar; reports readiness
   bool              Prime(const bool loud)
     {
      int need  = RequiredBars();
      int avail = BarsAvailable();
      if(avail < need+1)
        {
         if(loud)
            VerboseT(StringFormat("warm-up: %d/%d closed bars on %s (need %d)",
                                  avail, need, EnumToString(InpSignalTF), need), 30);
         m_have=0;
         return(false);
        }
      ArraySetAsSeries(m_rates,true);
      int got = CopyRates(_Symbol, InpSignalTF, 1, need, m_rates);
      if(got < need)
        {
         if(loud)
            VerboseT(StringFormat("warm-up: CopyRates returned %d/%d (err=%d)",got,need,_LastError), 30);
         m_have=0;
         return(false);
        }
      m_have = got;
      if(m_hATR==INVALID_HANDLE) return(false);
      if(BarsCalculated(m_hATR) < InpATRPeriod+2)
        {
         if(loud) VerboseT("warm-up: ATR buffer not calculated yet", 30);
         return(false);
        }
      double buf[];
      ArraySetAsSeries(buf,true);
      if(CopyBuffer(m_hATR,0,1,1,buf) < 1)
        {
         if(loud) VerboseT(StringFormat("warm-up: CopyBuffer(ATR) failed (err=%d)",_LastError), 30);
         return(false);
        }
      if(!IsFiniteD(buf[0]) || buf[0] <= 0.0) return(false);
      m_atr = buf[0];
      return(true);
     }

   //---------------------------------------------------------------
   //  HEAVY COMPUTATION -- call at most once per closed bar
   //  (plus the single forced call on the first tick after attach).
   //
   //  FUSION MODEL (naive-Bayes style on bounded evidence):
   //     each pillar p emits evidence e_p in [-1,+1]  (e = 2*prob - 1)
   //     composite  E = Sum_p w_p * e_p ,  Sum w_p = 1
   //     confidence score = sigmoid( gain * |E| )  in (0,1)
   //     direction        = sign(E)
   //  Because |E| <= 1 the score is bounded in [0.5, sigmoid(gain)] and
   //  the threshold is directly interpretable as a probability.
   //---------------------------------------------------------------
   bool              Compute(SSignal &out)
     {
      out.Reset();
      //--- The orchestrator calls Prime() first, so the heavy history copy
      //    happens exactly once per closed bar. Prime() is only re-entered
      //    here when no buffer is loaded (defensive, never redundant).
      if(m_have <= 0)
        {
         if(!Prime(true)) return(false);
        }

      out.atr = m_atr;
      out.bar_time = m_rates[0].time;
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      out.spread_price = (ask>0.0 && bid>0.0) ? ask-bid : 0.0;

      //---- pillar inputs -------------------------------------------------
      double sigFast=0.0, gkFast=0.0, sigSlow=0.0, gkSlow=0.0;
      bool okYZf = YangZhang(InpYZFastWindow, sigFast, gkFast);
      bool okYZs = YangZhang(InpYZSlowWindow, sigSlow, gkSlow);
      double vr=1.0, hVR=0.5, hRS=0.5;
      bool okVR  = VarianceRatio(InpVRWindow, InpVRLag, vr, hVR);
      bool okRS  = HurstRS(InpHurstRSWindow, hRS);
      double slope=0.0, r2=0.0, tstat=0.0, zres=0.0;
      bool okOLS = OLS(InpOLSWindow, slope, r2, tstat, zres);
      //--- the residual z-score comes from an OLS fit too. When both windows
      //    are identical the fit is already computed above, so it is reused
      //    instead of repeating the same O(n) regression in the same tick.
      double zZ=zres;
      bool   okZ=okOLS;
      if(InpZWindow != InpOLSWindow)
        {
         double zSlope=0.0, zR2=0.0, zT=0.0;
         zZ=0.0;
         okZ = OLS(InpZWindow, zSlope, zR2, zT, zZ);
        }
      double eff=0.0, rExp=0.0, acc=0.0; int dirRef=0;
      bool okMic = Micro(eff, rExp, acc, dirRef);

      if(!okYZf || !okYZs || !okOLS || !okMic)
        {
         VerboseT(StringFormat("signal rejected: yzF=%d yzS=%d ols=%d micro=%d",
                               (int)okYZf,(int)okYZs,(int)okOLS,(int)okMic), 60);
         return(false);
        }

      out.sigma_yz     = sigFast;
      out.sigma_yz_ann = sigFast*MathSqrt((double)MathMax(InpBarsPerYear,1));
      out.sigma_gk_ann = gkFast*MathSqrt((double)MathMax(InpBarsPerYear,1));
      out.vol_ratio    = SafeDiv(sigFast, sigSlow, 1.0);
      out.vr           = okVR ? vr : 1.0;
      out.hurst_vr     = okVR ? hVR : 0.5;
      out.hurst_rs     = okRS ? hRS : 0.5;
      out.hurst        = (okVR && okRS) ? 0.5*(hVR+hRS) : (okVR ? hVR : (okRS ? hRS : 0.5));
      out.slope        = slope;
      out.drift_ann    = slope*(double)MathMax(InpBarsPerYear,1);
      out.r2           = r2;
      out.tstat        = tstat;
      out.zresid       = okZ ? zZ : 0.0;
      out.efficiency   = eff;
      out.range_exp    = rExp;
      out.accel        = acc;

      //---- PILLAR 2: trend (t-stat significance, R^2-damped) -------------
      //   e_trend = tanh(t / TRef) * (0.25 + 0.75*R^2)
      //   R^2 damps a large t produced by a fit that explains little of the
      //   variance; the gate InpR2Min (default 0 = permissive) can veto.
      double eTrend = 0.0;
      if(r2 >= InpR2Min)
         eTrend = Tanh(SafeDiv(tstat, InpTStatRef, 0.0))*(0.25 + 0.75*r2);
      out.e_trend = ClampD(eTrend,-1.0,1.0);

      //---- discrete regime classification from the Hurst bands -----------
      //   H >= InpTrendHurst    => trending      (persistent increments)
      //   H <= InpMeanRevHurst  => mean-reverting(antipersistent increments)
      //   otherwise             => neutral       (weight tilt is halved)
      if(out.hurst >= InpTrendHurst)        out.regime =  1;
      else if(out.hurst <= InpMeanRevHurst) out.regime = -1;
      else                                  out.regime =  0;
      out.vol_expanding = (out.vol_ratio >= InpVolExpansionRatio);

      //---- PILLAR 3: mean reversion on the OLS residual ------------------
      //   z = (y_newest - fit_newest)/s   =>  e_mrev = -tanh(z / ZRef)
      //   price ABOVE its own regression line => short evidence, and vice
      //   versa. This is a stationary-deviation test, not an oscillator.
      //   Damping: fading a deviation while realized volatility is EXPANDING
      //   is negative-expectancy (the deviation is more likely to be the start
      //   of a re-pricing than noise), so the pillar is attenuated by
      //      damp = 1 - 0.5 * clamp( (volRatio - expThr)/expThr , 0, 1 )
      //   which reaches 0.5 at twice the expansion threshold.
      double eMrev = -Tanh(SafeDiv(out.zresid, InpZRef, 0.0));
      if(out.vol_expanding)
        {
         double over = ClampD(SafeDiv(out.vol_ratio - InpVolExpansionRatio,
                                      MathMax(InpVolExpansionRatio,1.0e-9), 0.0), 0.0, 1.0);
         eMrev *= (1.0 - 0.5*over);
        }
      out.e_meanrev = ClampD(eMrev,-1.0,1.0);

      //---- PILLAR 4: microstructure --------------------------------------
      //   arg = wE*(dirRef*EF) + wA*tanh(ACC/ARef) + wX*(dirRef*tanh(RE/XRef))
      //   e_micro = tanh(arg)/tanh(1)  -> maps [-1,1] onto the full range.
      double wSum = InpMicroWEff + InpMicroWAccel + InpMicroWExp;
      double eMicro = 0.0;
      if(wSum > 1.0e-9)
        {
         double arg = ( InpMicroWEff  *(double)dirRef*eff
                      + InpMicroWAccel*Tanh(SafeDiv(acc, InpAccelRef, 0.0))
                      + InpMicroWExp  *(double)dirRef*Tanh(SafeDiv(rExp, InpExpansionRef, 0.0)) )/wSum;
         eMicro = Tanh(arg)/Tanh(1.0);
        }
      out.e_micro = ClampD(eMicro,-1.0,1.0);

      //---- PILLAR 1: persistence / volatility regime ---------------------
      //   The regime pillar votes WITH the dominant drift when returns are
      //   positively autocorrelated (VR>1) and AGAINST it when they are
      //   negatively autocorrelated (VR<1):
      //      e_vol = dirRef * tanh( ln(VR) / VRRef )
      //   dirRef prefers the trend pillar, falls back to microstructure.
      int dRef = (MathAbs(out.e_trend) > 1.0e-9) ? SignD(out.e_trend)
               : ((MathAbs(out.e_micro) > 1.0e-9) ? SignD(out.e_micro) : 0);
      out.e_vol = (dRef!=0 && okVR) ? ClampD((double)dRef*Tanh(SafeLog(vr)/MathMax(InpVRRef,1.0e-6)),-1.0,1.0) : 0.0;

      //---- regime-adaptive weights ---------------------------------------
      //   p = (H-0.5)/0.5 in [-1,1]: +1 persistent, -1 antipersistent.
      //   Trending  -> tilt weight toward trend & micro (continuation).
      //   Reverting -> tilt weight toward the residual z-score (fade).
      double p = ClampD((out.hurst-0.5)/0.5, -1.0, 1.0);
      double tilt = InpRegimeAdaptiveWeights ? ClampD(InpRegimeTilt,0.0,1.0) : 0.0;
      if(out.regime==0) tilt *= 0.5;                    // neutral band: half conviction
      double wT = MathMax(InpWTrend  *(1.0 + tilt*p),        0.0);
      double wX = MathMax(InpWMicro  *(1.0 + tilt*p),        0.0);
      double wM = MathMax(InpWMeanRev*(1.0 - tilt*p),        0.0);
      double wV = MathMax(InpWVol    *(1.0 + 0.5*tilt*p),    0.0);
      double wSumAll = wT + wX + wM + wV;
      if(wSumAll <= 1.0e-9)                       // degenerate inputs -> static
        {
         wT=InpWTrend; wX=InpWMicro; wM=InpWMeanRev; wV=InpWVol;
         wSumAll=wT+wX+wM+wV;
         if(wSumAll <= 1.0e-9){ wT=1.0; wSumAll=1.0; }
        }
      out.w_trend   = wT/wSumAll;
      out.w_micro   = wX/wSumAll;
      out.w_meanrev = wM/wSumAll;
      out.w_vol     = wV/wSumAll;

      //---- fusion --------------------------------------------------------
      double E = out.w_vol    *out.e_vol
               + out.w_trend  *out.e_trend
               + out.w_meanrev*out.e_meanrev
               + out.w_micro  *out.e_micro;
      E = ClampD(E,-1.0,1.0);
      out.evidence = E;
      out.score    = Sigmoid(InpSigmoidGain*MathAbs(E));
      out.direction= SignD(E);

      //---- degenerate-evidence tie break (keeps the EA from idling) ------
      if(MathAbs(E) < InpMinEvidence)
        {
         if(dRef != 0)             out.direction = dRef;
         else if(SignD(slope)!=0)  out.direction = SignD(slope);
         else                      out.direction = InpAllowLong ? 1 : (InpAllowShort ? -1 : 0);
        }
      out.valid = true;
      return(true);
     }
  };

CSignalEngine g_engine;

//==================================================================
//  5. ACCOUNT HELPERS
//==================================================================
double AccountEquityNow()     { return(AccountInfoDouble(ACCOUNT_EQUITY));      }
double AccountBalanceNow()    { return(AccountInfoDouble(ACCOUNT_BALANCE));     }
double AccountFreeMarginNow() { return(AccountInfoDouble(ACCOUNT_MARGIN_FREE)); }

//--- hedge-ticket bookkeeping that survives broker comment stripping
string HedgeTicketKey(const ulong tk) { return("HT_"+IntegerToString((long)tk)); }
void   MarkHedgeTicket(const ulong tk)   { GVSet(HedgeTicketKey(tk),1.0); }
void   UnmarkHedgeTicket(const ulong tk) { GVDel(HedgeTicketKey(tk)); }
bool   IsMarkedHedge(const ulong tk)     { return(GlobalVariableCheck(GVName(HedgeTicketKey(tk)))); }

//==================================================================
//  6. RISK MANAGER
//     Account-aware sizing and the global guard stack.
//==================================================================
class CRiskManager
  {
private:
   datetime          m_dayKey;          // server midnight of the current trading day
   double            m_dayStartEquity;  // equity anchored at day start
   double            m_peakEquity;      // running peak equity (persisted)

   //--- resolve the broker's "day start" bar time (timezone correct)
   datetime          DayKey()
     {
      datetime k = iTime(_Symbol, PERIOD_D1, 0);
      if(k == 0)
        {
         datetime t = TimeCurrent();
         k = t - (t % 86400);                       // UTC-midnight fallback
        }
      return(k);
     }

public:
                     CRiskManager() { m_dayKey=0; m_dayStartEquity=0.0; m_peakEquity=0.0; }

   //--- called from OnInit: anchors day-start equity and peak equity
   bool              Init()
     {
      double eq = AccountEquityNow();
      if(eq <= 0.0)
        {
         Print("QGE FATAL: account equity unavailable in OnInit");
         return(false);
        }
      m_dayKey = DayKey();
      double storedKey = GVGet("DAYKEY", 0.0);
      double storedEq  = GVGet("DAYEQ",  eq);
      if(storedKey == (double)m_dayKey && storedEq > 0.0) m_dayStartEquity = storedEq;
      else
        {
         m_dayStartEquity = eq;
         GVSet("DAYKEY",(double)m_dayKey);
         GVSet("DAYEQ", eq);
        }
      m_peakEquity = GVGet("PEAK", eq);
      if(eq > m_peakEquity) { m_peakEquity = eq; GVSet("PEAK", eq); }
      PrintFormat("QGE risk anchors: equity=%.2f dayStart=%.2f peak=%.2f day=%s",
                  eq, m_dayStartEquity, m_peakEquity, TimeToString(m_dayKey,TIME_DATE));
      return(true);
     }

   //--- per-tick housekeeping: rollover + peak tracking
   void              Update()
     {
      datetime k = DayKey();
      if(k != m_dayKey)
        {
         m_dayKey         = k;
         m_dayStartEquity = AccountEquityNow();
         GVSet("DAYKEY",(double)k);
         GVSet("DAYEQ", m_dayStartEquity);
         g_entriesToday   = 0;
         g_entryDay       = k;
         g_lastDailyScan  = 0;
         g_realizedToday  = 0.0;
         Verbose("new trading day anchored: dayStartEquity="+DoubleToString(m_dayStartEquity,2));
        }
      double eq = AccountEquityNow();
      if(eq > m_peakEquity) { m_peakEquity = eq; GVSet("PEAK", eq); }
     }

   datetime          DayStart()        const { return(m_dayKey);         }
   double            DayStartEquity()  const { return(m_dayStartEquity); }
   double            PeakEquity()      const { return(m_peakEquity);     }

   //--- drawdown from the running peak, in % of peak
   double            DDFromPeakPct()
     {
      double eq = AccountEquityNow();
      if(m_peakEquity <= 1.0e-9) return(0.0);
      return(ClampD((m_peakEquity - eq)/m_peakEquity*100.0, 0.0, 100.0));
     }

   //--- realized P&L since day start, from history deals of THIS magic only
   double            RealizedSinceDayStart()
     {
      if(!HistorySelect(m_dayKey, TimeCurrent()+120)) return(0.0);
      double sum=0.0;
      int deals = HistoryDealsTotal();
      for(int i=0;i<deals;i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt==0) continue;
         if(HistoryDealGetInteger(dt,DEAL_MAGIC) != InpMagicNumber) continue;
         if(HistoryDealGetString(dt,DEAL_SYMBOL) != _Symbol)        continue;
         long ent = HistoryDealGetInteger(dt,DEAL_ENTRY);
         if(ent==DEAL_ENTRY_IN)
           {   // entry commissions/fees are real cash costs
            sum += HistoryDealGetDouble(dt,DEAL_COMMISSION) + HistoryDealGetDouble(dt,DEAL_FEE);
            continue;
           }
         if(ent==DEAL_ENTRY_OUT || ent==DEAL_ENTRY_INOUT || ent==DEAL_ENTRY_OUT_BY)
            sum += HistoryDealGetDouble(dt,DEAL_PROFIT)
                 + HistoryDealGetDouble(dt,DEAL_SWAP)
                 + HistoryDealGetDouble(dt,DEAL_COMMISSION)
                 + HistoryDealGetDouble(dt,DEAL_FEE);
        }
      return(sum);
     }

   //--- daily loss guard: realized + floating vs day-start equity
   bool              DailyLossBreached(const double floating, double &dayPnL, double &limitMoney)
     {
      dayPnL    = g_realizedToday + floating;
      limitMoney= -InpDailyLossLimitPct/100.0*m_dayStartEquity;
      if(InpDailyLossLimitPct <= 0.0) return(false);       // disabled
      return(dayPnL <= limitMoney);
     }

   //--- equity-floor kill switch: total drawdown from peak equity
   bool              EquityFloorBreached(double &ddPct)
     {
      ddPct = DDFromPeakPct();
      if(InpEquityFloorDDPct <= 0.0) return(false);        // disabled
      return(ddPct >= InpEquityFloorDDPct);
     }

   //--- spread filter: absolute points AND relative to ATR
   bool              SpreadOK(const double atr, const double spreadPrice, string &why)
     {
      why="";
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(ask<=0.0 || bid<=0.0) { why="no quotes"; return(false); }
      double sp = (spreadPrice>0.0) ? spreadPrice : ask-bid;
      double pts = SafeDiv(sp, g_symbolPoint, 0.0);
      if(InpMaxSpreadPoints > 0 && pts > (double)InpMaxSpreadPoints)
        { why=StringFormat("spread %.1f pts > max %d pts", pts, InpMaxSpreadPoints); return(false); }
      if(InpMaxSpreadPctOfATR > 0.0 && atr > 0.0 && sp > InpMaxSpreadPctOfATR*atr)
        { why=StringFormat("spread %.5f > %.0f%% of ATR %.5f", sp, InpMaxSpreadPctOfATR*100.0, atr); return(false); }
      return(true);
     }

   //--- trade permission (terminal / account / symbol / direction)
   bool              TradingPermitted(const int dir, string &why)
     {
      why="";
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))          { why="MQL trade disabled";       return(false); }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)){ why="terminal trading off";     return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))  { why="account trading off";      return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))   { why="EA trading off (account)"; return(false); }
      long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
      if(mode==SYMBOL_TRADE_MODE_DISABLED)            { why="symbol trading disabled";  return(false); }
      if(mode==SYMBOL_TRADE_MODE_CLOSEONLY)           { why="symbol close-only";        return(false); }
      if(dir>0 && mode==SYMBOL_TRADE_MODE_SHORTONLY)  { why="long-only violation";      return(false); }
      if(dir<0 && mode==SYMBOL_TRADE_MODE_LONGONLY)   { why="short-only violation";     return(false); }
      return(true);
     }

   //--- session filter (disabled by default so it never blocks the open)
   bool              SessionOK(string &why)
     {
      why="";
      if(!InpUseSessionFilter && !InpSkipLateFriday) return(true);
      MqlDateTime st;
      TimeToStruct(TimeCurrent(), st);
      if(InpUseSessionFilter)
        {
         int h = st.hour;
         bool inside = (InpSessionStartHour <= InpSessionEndHour)
                       ? (h >= InpSessionStartHour && h < InpSessionEndHour)
                       : (h >= InpSessionStartHour || h < InpSessionEndHour);   // overnight window
         if(!inside) { why=StringFormat("outside session %02d-%02d (now %02d)",
                                        InpSessionStartHour,InpSessionEndHour,h); return(false); }
        }
      if(InpSkipLateFriday && st.day_of_week==5 && st.hour>=21)
        { why="late-Friday entry lock (server hour >= 21)"; return(false); }
      return(true);
     }

   //--- margin feasibility with a cushion multiple
   bool              MarginOK(const ENUM_ORDER_TYPE type, const double lots, const double price, string &why)
     {
      why="";
      double need=0.0;
      if(!OrderCalcMargin(type,_Symbol,lots,price,need))
        {                                             // broker refused to quote margin:
         why="OrderCalcMargin unavailable (allowed)";   // stay permissive, log once
         return(true);
        }
      if(need <= 0.0) return(true);
      double free = AccountFreeMarginNow();
      double cushion = MathMax(InpMarginCushion,1.0);
      if(free < cushion*need)
        {
         why=StringFormat("free margin %.2f < %.2fx required %.2f", free, cushion, need);
         return(false);
        }
      return(true);
     }

   //---------------------------------------------------------------
   //  LOT SIZING FROM RISK
   //     risk_money = equity * RiskPct/100
   //     loss_per_lot = | P&L of 1 lot stopped out at SL |
   //     lots = risk_money / loss_per_lot
   //  loss_per_lot is taken from OrderCalcProfit() (broker-exact, handles
   //  XAUUSD tick size/value and any account currency) with two fallbacks:
   //     (a) tick-value formula: (SL/tick_size)*tick_value
   //     (b) contract-size formula: SL * contract_size  (valid when the
   //         account currency is the quote currency, e.g. USD on XAUUSD:
   //         1.00 price move x 100 oz = $100 per lot)
   //  The result is floored to VOLUME_STEP and REJECTED below VOLUME_MIN.
   //---------------------------------------------------------------
   double            LotForRisk(const double riskMoney, const double slDistance,
                                const ENUM_ORDER_TYPE type, const double entry, string &why)
     {
      why="";
      if(riskMoney <= 0.0 || slDistance <= 0.0 || entry <= 0.0)
        { why="invalid risk inputs"; return(0.0); }
      double slPrice = (type==ORDER_TYPE_BUY) ? entry - slDistance : entry + slDistance;
      if(slPrice <= 0.0) { why="SL price non-positive"; return(0.0); }
      double lossPerLot=0.0, p=0.0;
      if(OrderCalcProfit(type,_Symbol,1.0,entry,slPrice,p) && p < 0.0) lossPerLot = -p;
      if(lossPerLot <= 1.0e-9 && g_tickSize > 0.0 && g_tickValue > 0.0)
         lossPerLot = (slDistance/g_tickSize)*g_tickValue;
      if(lossPerLot <= 1.0e-9 && g_contractSize > 0.0)
         lossPerLot = slDistance*g_contractSize;
      if(lossPerLot <= 1.0e-9 || !IsFiniteD(lossPerLot))
        { why="cannot price the SL distance (tick value unavailable)"; return(0.0); }
      double raw = riskMoney/lossPerLot;
      bool   ok  = false;
      double v   = NormalizeVolume(raw, ok);
      if(!ok || v <= 0.0)
        {
         why=StringFormat("required volume %.5f rejected (broker min %.2f, step %.2f) - NOT bumped",
                          raw, g_volMin, g_volStep);
         return(0.0);
        }
      return(v);
     }

   //---------------------------------------------------------------
   //  FRACTIONAL KELLY CAP (used for pyramid add-ons)
   //     f* = (p*b - q)/b ,  p = score, q = 1-p, b = payoff ratio (TP/SL)
   //  f* is the fraction of bankroll to put at risk; we use
   //     riskMoney = equity * min(RiskPct, KellyFraction*f* *100)
   //  so the Kelly term can only SHRINK the risk budget (cap, never boost).
   //---------------------------------------------------------------
   double            KellyCappedRiskPct(const double score, const double payoff)
     {
      double p = ClampD(score,0.0,1.0);
      double b = MathMax(payoff,1.0e-6);
      double f = (p*b - (1.0-p))/b;                   // Kelly fraction
      if(f <= 0.0) return(0.0);                       // negative edge: no add-on
      double capped = InpKellyFraction*f*100.0;       // fractional Kelly, in %
      return(ClampD(MathMin(InpRiskPctOfEquity, capped), 0.0, InpRiskPctOfEquity));
     }

   //---------------------------------------------------------------
   //  AGGREGATE OPEN RISK, % of equity.
   //     risk% = |book_net_lots| * loss_per_lot(R) / equity * 100
   //  where loss_per_lot(R) is the broker-exact loss of 1 lot stopped out
   //  R price units away. Uses the live quote as the reference entry so
   //  OrderCalcProfit() stays inside the symbol's real price domain.
   //---------------------------------------------------------------
   double            OpenRiskPct(const double bookLots, const double rPrice)
     {
      double eq = AccountEquityNow();
      if(eq <= 1.0e-9 || bookLots <= 0.0 || rPrice <= 0.0) return(0.0);
      double ref = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(ref <= 0.0) ref = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(ref <= 0.0) return(0.0);
      double lossPerLot=0.0, p=0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,1.0,ref,ref-rPrice,p) && p<0.0) lossPerLot=-p;
      if(lossPerLot <= 1.0e-9 && g_tickSize>0.0 && g_tickValue>0.0)
         lossPerLot = (rPrice/g_tickSize)*g_tickValue;
      if(lossPerLot <= 1.0e-9) lossPerLot = rPrice*g_contractSize;
      if(lossPerLot <= 1.0e-9) return(0.0);
      return(ClampD(bookLots*lossPerLot/eq*100.0, 0.0, 1000.0));
     }
  };

CRiskManager g_risk;

//==================================================================
//  7. POSITION MANAGER
//     Book aggregation, order execution with retry, stop management.
//==================================================================
class CPositionManager
  {
public:
   //---------------------------------------------------------------
   //  Aggregate every position belonging to this magic + symbol and
   //  split it into the directional BOOK and the HEDGE sleeve.
   //  Commission/fees are read from history deals once per refresh
   //  (refreshes are throttled to bar changes / book mutations).
   //---------------------------------------------------------------
   void              RefreshBook(SBookStats &bk, const bool withCommission)
     {
      //--- carry the cached commission forward on cheap (structural) scans;
      //    history-deal lookups are the only expensive part of a refresh.
      double cachedBookComm  = bk.book_comm;
      double cachedHedgeComm = bk.hedge_comm;
      bk.Reset();
      if(!withCommission)
        {
         bk.book_comm  = cachedBookComm;
         bk.hedge_comm = cachedHedgeComm;
        }
      int total = PositionsTotal();
      for(int i=total-1;i>=0;i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)            continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)     continue;

         double   vol   = PositionGetDouble(POSITION_VOLUME);
         double   open  = PositionGetDouble(POSITION_PRICE_OPEN);
         double   prof  = PositionGetDouble(POSITION_PROFIT);
         double   swap  = PositionGetDouble(POSITION_SWAP);
         long     type  = PositionGetInteger(POSITION_TYPE);
         datetime otime = (datetime)PositionGetInteger(POSITION_TIME);
         string   cmt   = PositionGetString(POSITION_COMMENT);
         double   sgn   = (type==POSITION_TYPE_BUY) ? 1.0 : -1.0;
         bool     hedge = (StringFind(cmt,InpTagHedge) >= 0) || IsMarkedHedge(tk);

         //--- cheap checksum so the orchestrator can detect mutations
         bk.key += tk*7 + (ulong)MathRound(vol*10000.0)*13
                 + ((type==POSITION_TYPE_BUY) ? 3 : 5) + (hedge ? 17 : 0)
                 + (ulong)(otime/60);

         double comm = withCommission ? CommissionOfPosition(tk) : 0.0;
         double need = 0.0;
         ENUM_ORDER_TYPE ot = (type==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         if(!OrderCalcMargin(ot,_Symbol,vol,open,need)) need = 0.0;

         bk.total_positions++;
         bk.total_lots     += vol;
         bk.margin_used    += need;
         if(hedge)
           {
            bk.hedge_positions++;
            bk.hedge_lots    += vol;
            bk.hedge_signed  += sgn*vol;
            bk.hedge_wavg    += sgn*vol*open;      // signed-weighted, fixed below
            bk.hedge_profit  += prof;
            bk.hedge_swap    += swap;
            bk.hedge_comm    += comm;
            if(bk.hedge_first_time==0 || otime<bk.hedge_first_time) bk.hedge_first_time=otime;
           }
         else
           {
            bk.book_positions++;
            if(sgn>0.0) bk.book_long_lots  += vol; else bk.book_short_lots += vol;
            bk.book_net_lots  += sgn*vol;
            bk.book_wavg      += vol*open;         // volume weighted (unsigned)
            bk.book_profit    += prof;
            bk.book_swap      += swap;
            bk.book_comm      += comm;
            if(otime > bk.book_last_time)
              {
               bk.book_last_time  = otime;
               bk.book_last_entry = open;              // newest leg => spacing reference
              }
            if(bk.book_first_time==0 || otime < bk.book_first_time) bk.book_first_time = otime;
            if(StringFind(cmt,InpTagPyramid) >= 0) bk.scale_ins++;
           }
        }
      double bl = bk.book_long_lots + bk.book_short_lots;
      bk.book_wavg   = (bl>0.0) ? bk.book_wavg/bl : 0.0;
      double hl      = bk.hedge_lots;
      bk.hedge_wavg  = (hl>0.0) ? MathAbs(bk.hedge_wavg)/hl : 0.0;
      bk.book_pnl    = bk.book_profit  + bk.book_swap  + bk.book_comm;
      bk.hedge_pnl   = bk.hedge_profit + bk.hedge_swap + bk.hedge_comm;
      bk.total_pnl   = bk.book_pnl + bk.hedge_pnl;
      bk.net_signed_lots = bk.book_net_lots + bk.hedge_signed;
      //--- scale-in count falls back to (legs-1) when comments are stripped
      if(bk.book_positions > 0 && bk.scale_ins==0) bk.scale_ins = bk.book_positions-1;
     }

   //--- commission + fees already booked against an open position
   double            CommissionOfPosition(const ulong positionTicket)
     {
      if(!HistorySelectByPosition(positionTicket)) return(0.0);
      double sum=0.0;
      int deals = HistoryDealsTotal();
      for(int i=0;i<deals;i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt==0) continue;
         sum += HistoryDealGetDouble(dt,DEAL_COMMISSION) + HistoryDealGetDouble(dt,DEAL_FEE);
        }
      return(sum);
     }

   //---------------------------------------------------------------
   //  MARKET ORDER WITH RETRY
   //  - volume re-normalized (sub-minimum rejected, never bumped)
   //  - prices normalized to _Digits
   //  - stops repaired once on TRADE_RETCODE_INVALID_STOPS
   //  - transient retcodes retried up to InpOrderRetries
   //---------------------------------------------------------------
   bool              OpenMarket(const int dir, const double lots, double sl, double tp,
                                const string tag, const bool asHedge, ulong &ticketOut)
     {
      ticketOut=0;
      if(dir==0 || lots<=0.0) return(false);
      bool ok=false;
      double v = NormalizeVolume(lots, ok);
      if(!ok || v<=0.0)
        {
         PrintFormat("QGE REJECT: volume %.5f not broker-legal (min=%.2f step=%.2f) - not bumped",
                     lots,g_volMin,g_volStep);
         return(false);
        }
      ENUM_ORDER_TYPE otype = (dir>0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      int attempts = (int)MathMax(InpOrderRetries,1);
      bool repairedStops=false;

      for(int attempt=1; attempt<=attempts; attempt++)
        {
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double price = (dir>0) ? ask : bid;
         if(price<=0.0)
           {
            Print("QGE: no quote for entry attempt ",attempt);
            continue;
           }
         double minStop = MinStopDistance();
         double slUse = (sl>0.0) ? NormalizePrice(sl) : 0.0;
         double tpUse = (tp>0.0) ? NormalizePrice(tp) : 0.0;
         //--- enforce the broker stops level (this is a legality repair,
         //    not a risk bump: the risk model is re-checked afterwards)
         if(slUse>0.0)
           {
            double d = (dir>0) ? price-slUse : slUse-price;
            if(d < minStop)
               slUse = NormalizePrice((dir>0) ? price-minStop : price+minStop);
           }
         string mwhy="";
         if(!g_risk.MarginOK(otype, v, price, mwhy))
           {
            PrintFormat("QGE ABORT: margin check failed (%s)", mwhy);
            return(false);
           }
         bool sent = (dir>0)
                     ? g_trade.Buy (v,_Symbol,price,slUse,tpUse,tag)
                     : g_trade.Sell(v,_Symbol,price,slUse,tpUse,tag);
         uint rc = g_trade.ResultRetcode();
         if(sent && IsSuccessRetcode(rc))
           {
            ticketOut = g_trade.ResultOrder();
            if(ticketOut==0) ticketOut = g_trade.ResultDeal();
            if(asHedge && ticketOut>0) MarkHedgeTicket(ticketOut);
            PrintFormat("QGE FILLED: %s %.2f lots @ %.5f SL=%.5f TP=%.5f tag=%s rc=%s deal=%I64u",
                        (dir>0?"BUY":"SELL"), v, g_trade.ResultPrice(), slUse, tpUse, tag,
                        RetcodeText(rc), ticketOut);
            return(true);
           }
         PrintFormat("QGE ORDER FAILED (%d/%d): rc=%u (%s) retcode_desc=%s comment=%s",
                     attempt, attempts, rc, RetcodeText(rc),
                     g_trade.ResultRetcodeDescription(), g_trade.ResultComment());
         if(rc==TRADE_RETCODE_INVALID_STOPS && !repairedStops)
           {
            repairedStops = true;                         // rebuild legal stops and retry
            sl = NormalizePrice((dir>0) ? price-minStop : price+minStop);
            tp = (InpTP_RR>0.0)
                 ? NormalizePrice((dir>0) ? price+minStop*InpTP_RR : price-minStop*InpTP_RR) : 0.0;
            continue;
           }
         if(!IsRetryableRetcode(rc)) return(false);        // permanent rejection
         if(!MQLInfoInteger(MQL_TESTER) && InpRetryDelayMs>0) Sleep(InpRetryDelayMs);
        }
      return(false);
     }

   //--- close a single position, with retry on transient retcodes
   bool              CloseTicket(const ulong ticket, const string reason)
     {
      if(ticket==0) return(false);
      int attempts = (int)MathMax(InpOrderRetries,1);
      for(int attempt=1; attempt<=attempts; attempt++)
        {
         if(!PositionSelectByTicket(ticket))
           {
            UnmarkHedgeTicket(ticket);
            PrintFormat("QGE CLOSE: ticket %I64u already gone (%s)", ticket, reason);
            return(true);
           }
         if(g_trade.PositionClose(ticket,(ulong)InpSlippagePoints))
           {
            uint rc=g_trade.ResultRetcode();
            if(IsSuccessRetcode(rc) || rc==TRADE_RETCODE_POSITION_CLOSED)
              {
               UnmarkHedgeTicket(ticket);
               PrintFormat("QGE CLOSED: ticket %I64u (%s) rc=%s", ticket, reason, RetcodeText(rc));
               return(true);
              }
           }
         uint rc2 = g_trade.ResultRetcode();
         PrintFormat("QGE CLOSE FAILED (%d/%d) ticket %I64u rc=%u (%s) - %s",
                     attempt, attempts, ticket, rc2, RetcodeText(rc2), reason);
         if(rc2==TRADE_RETCODE_POSITION_CLOSED) { UnmarkHedgeTicket(ticket); return(true); }
         if(!IsRetryableRetcode(rc2)) return(false);
         if(!MQLInfoInteger(MQL_TESTER) && InpRetryDelayMs>0) Sleep(InpRetryDelayMs);
        }
      return(false);
     }

   //--- partial close (used by the hedge ladder and netting-mode deleveraging)
   bool              ClosePartial(const ulong ticket, double lots, const string reason)
     {
      if(ticket==0 || lots<=0.0) return(false);
      if(!PositionSelectByTicket(ticket)) return(false);
      double have = PositionGetDouble(POSITION_VOLUME);
      if(lots >= have - 1.0e-9) return(CloseTicket(ticket,reason));   // full close
      bool ok=false;
      double v = NormalizeVolume(lots, ok);
      if(!ok || v<=0.0)
        {
         PrintFormat("QGE REJECT partial %.5f on ticket %I64u (broker min %.2f) - skipped, NOT bumped",
                     lots, ticket, g_volMin);
         return(false);
        }
      if(v >= have - 1.0e-9) return(CloseTicket(ticket,reason));
      if(g_trade.PositionClosePartial(ticket,v,(ulong)InpSlippagePoints))
        {
         uint rc=g_trade.ResultRetcode();
         if(IsSuccessRetcode(rc))
           {
            PrintFormat("QGE PARTIAL CLOSE: %I64u %.2f of %.2f lots (%s)", ticket, v, have, reason);
            return(true);
           }
        }
      PrintFormat("QGE PARTIAL CLOSE FAILED ticket %I64u rc=%u (%s) - %s",
                  ticket, g_trade.ResultRetcode(), RetcodeText(g_trade.ResultRetcode()), reason);
      return(false);
     }

   //--- flatten a sleeve (book or hedge), newest first
   int               CloseSleeve(const bool hedgeSleeve, const string reason)
     {
      int closed=0;
      for(int pass=0; pass<PositionsTotal()+1; pass++)
        {
         bool did=false;
         for(int i=PositionsTotal()-1;i>=0;i--)
           {
            ulong tk=PositionGetTicket(i);
            if(tk==0) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol)        continue;
            if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
            string cmt=PositionGetString(POSITION_COMMENT);
            bool isH=(StringFind(cmt,InpTagHedge)>=0)||IsMarkedHedge(tk);
            if(isH!=hedgeSleeve) continue;
            if(CloseTicket(tk,reason)) { closed++; did=true; break; }
           }
         if(!did) break;
        }
      return(closed);
     }

   //---------------------------------------------------------------
   //  Recover the R anchor (SL distance of the BASE leg) after a restart
   //  when the persisted value is gone: take |entry - SL| of the oldest
   //  directional leg that still carries a stop.
   //---------------------------------------------------------------
   double            InferRPrice()
     {
      datetime oldest=0; double r=0.0;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol)        continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
         string cmt=PositionGetString(POSITION_COMMENT);
         if((StringFind(cmt,InpTagHedge)>=0)||IsMarkedHedge(tk)) continue;
         double sl=PositionGetDouble(POSITION_SL);
         double op=PositionGetDouble(POSITION_PRICE_OPEN);
         if(sl<=0.0 || op<=0.0) continue;
         datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
         if(oldest==0 || ot<oldest){ oldest=ot; r=MathAbs(op-sl); }
        }
      return(r);
     }

   //---------------------------------------------------------------
   //  AGGREGATE STOP MANAGEMENT (break-even + ATR trailing)
   //  R (price distance) is the SL distance used when the book was
   //  opened; favorable excursion is measured from the volume-weighted
   //  average entry so pyramided books are handled coherently.
   //---------------------------------------------------------------
   void              ManageStops(const SBookStats &bk, const double atr)
     {
      if(bk.book_positions==0) return;
      if(g_bookRPrice <= 0.0 || atr <= 0.0) return;
      int dir = SignD(bk.book_net_lots);
      if(dir==0) return;
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(bid<=0.0 || ask<=0.0) return;
      double mark = (dir>0) ? bid : ask;                      // exit mark for the book
      double fav  = (dir>0) ? mark-bk.book_wavg : bk.book_wavg-mark;
      if(fav <= 0.0) return;                                  // nothing to protect yet
      double R    = g_bookRPrice;
      double minStop = MinStopDistance();
      bool doBE = InpUseBreakEven && fav >= InpBreakEvenAtR*R;
      bool doTR = InpUseTrailing  && fav >= InpTrailStartR*R;
      if(!doBE && !doTR) return;

      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol)        continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
         string cmt=PositionGetString(POSITION_COMMENT);
         if((StringFind(cmt,InpTagHedge)>=0)||IsMarkedHedge(tk)) continue;   // book only
         long   type  = PositionGetInteger(POSITION_TYPE);
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL = PositionGetDouble(POSITION_SL);
         double curTP = PositionGetDouble(POSITION_TP);
         bool   isBuy = (type==POSITION_TYPE_BUY);
         double px    = isBuy ? bid : ask;                     // closing price side
         double newSL = 0.0;
         if(doBE)
           {
            double be = isBuy ? entry + InpBreakEvenLockR*R : entry - InpBreakEvenLockR*R;
            newSL = be;
           }
         if(doTR)
           {
            double tr = isBuy ? px - InpTrailATR*atr : px + InpTrailATR*atr;
            newSL = (newSL==0.0) ? tr : (isBuy ? MathMax(newSL,tr) : MathMin(newSL,tr));
           }
         if(newSL<=0.0) continue;
         newSL = NormalizePrice(newSL);
         double dist = isBuy ? px-newSL : newSL-px;
         if(dist < minStop) continue;                          // broker would reject
         if(isBuy  && curSL>0.0 && newSL <= curSL + g_symbolPoint*0.5) continue;  // not improving
         if(!isBuy && curSL>0.0 && newSL >= curSL - g_symbolPoint*0.5) continue;
         if(g_freezeLevel>0 && curSL>0.0 &&
            MathAbs(px-curSL)/g_symbolPoint < (double)g_freezeLevel) continue;     // frozen
         if(g_trade.PositionModify(tk,newSL,curTP))
            Verbose(StringFormat("SL updated ticket %I64u -> %.5f (BE=%d TR=%d fav=%.5f R=%.5f)",
                                 tk,newSL,(int)doBE,(int)doTR,fav,R));
         else
           {
            uint rc=g_trade.ResultRetcode();
            if(rc!=TRADE_RETCODE_NO_CHANGES && rc!=TRADE_RETCODE_INVALID_STOPS)
               PrintFormat("QGE: SL modify failed ticket %I64u rc=%u (%s)",tk,rc,RetcodeText(rc));
           }
        }
     }
  };

CPositionManager g_pos;

//==================================================================
//  8. EXTRA GLOBALS USED BY THE ORCHESTRATION LAYER
//==================================================================
datetime      g_lastComputeAttempt = 0;   // throttle for failed heavy computations
int           g_hedgeLogOnce       = 0;   // one-shot log flags (bit 0 = netting warning)

//--- maximum affordable volume for an order type at a price, honouring the
//    margin cushion and the broker volume grid. Returns 0 when infeasible.
double MaxAffordableLots(const ENUM_ORDER_TYPE type, const double price)
  {
   if(price <= 0.0) return(0.0);
   double need1=0.0;
   if(!OrderCalcMargin(type,_Symbol,g_volMin,price,need1)) return(g_volMax);  // unknown -> grid max
   if(need1 <= 1.0e-9) return(g_volMax);
   double perLot = need1/g_volMin;
   double cushion= MathMax(InpMarginCushion,1.0);
   double budget = AccountFreeMarginNow()/cushion;
   double lots   = budget/perLot;
   bool   ok=false;
   return(NormalizeVolume(lots, ok));
  }

//==================================================================
//  9. HEDGE MANAGER -- full lifecycle: open / manage / ladder-unwind
//==================================================================
class CHedgeManager
  {
   //---------------------------------------------------------------
   //  R (money) of the aggregate directional book.
   //     R_money = |net_lots| * loss_per_lot(R_price)
   //  This is the true "1R" of the whole sleeve (not of one leg) and it
   //  is the unit in which every hedge/recovery target is expressed.
   //---------------------------------------------------------------
   double            BookRMoney(const SBookStats &bk)
     {
      double L = MathAbs(bk.book_net_lots);
      if(L <= 0.0 || g_bookRPrice <= 0.0) return(0.0);
      double ref = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(ref <= 0.0) ref = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(ref <= 0.0) return(0.0);
      double lossPerLot=0.0, p=0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,1.0,ref,ref-g_bookRPrice,p) && p<0.0) lossPerLot=-p;
      if(lossPerLot <= 1.0e-9 && g_tickSize>0.0 && g_tickValue>0.0)
         lossPerLot = (g_bookRPrice/g_tickSize)*g_tickValue;
      if(lossPerLot <= 1.0e-9) lossPerLot = g_bookRPrice*g_contractSize;
      if(lossPerLot <= 1.0e-9) return(0.0);
      return(L*lossPerLot);
     }

   //--- persist / restore the hedge lifecycle across re-initialisation
   void              SaveState()
     {
      GVSet("HG_BORN",   g_hedge.born_lots);
      GVSet("HG_TIME",   (double)g_hedge.born_time);
      GVSet("HG_PRICE",  g_hedge.born_price);
      GVSet("HG_R",      g_hedge.anchor_R);
      GVSet("HG_PNL0",   g_hedge.born_pnl);
      GVSet("HG_CLOSED", g_hedge.closed_lots);
      GVSet("HG_TP",     (double)g_hedge.tp_levels_used);
      GVSet("HG_LASTTP", g_hedge.last_tp_level);
     }
   void              LoadState()
     {
      g_hedge.born_lots     = GVGet("HG_BORN",   0.0);
      g_hedge.born_time     = (datetime)GVGet("HG_TIME", 0.0);
      g_hedge.born_price    = GVGet("HG_PRICE",  0.0);
      g_hedge.anchor_R      = GVGet("HG_R",      0.0);
      g_hedge.born_pnl      = GVGet("HG_PNL0",   0.0);
      g_hedge.closed_lots   = GVGet("HG_CLOSED", 0.0);
      g_hedge.tp_levels_used= (int)GVGet("HG_TP",0.0);
      g_hedge.last_tp_level = GVGet("HG_LASTTP", 0.0);
     }
   //--- delete every persisted hedge-ticket marker belonging to this EA
   //    (positions closed by their catastrophe SL leave markers behind)
   void              PurgeHedgeMarkers()
     {
      string prefix = GVName("HT_");
      int plen = StringLen(prefix);
      for(int i=GlobalVariablesTotal()-1;i>=0;i--)
        {
         string nm = GlobalVariableName(i);
         if(StringLen(nm) >= plen && StringSubstr(nm,0,plen)==prefix) GlobalVariableDel(nm);
        }
     }

   void              ClearState()
     {
      g_hedge.active=false; g_hedge.born_lots=0.0; g_hedge.closed_lots=0.0;
      g_hedge.born_time=0; g_hedge.born_price=0.0; g_hedge.anchor_R=0.0; g_hedge.born_pnl=0.0;
      g_hedge.tp_levels_used=0; g_hedge.last_tp_level=0.0; g_hedge.flip_bars=0;
      GVDel("HG_BORN"); GVDel("HG_TIME"); GVDel("HG_PRICE"); GVDel("HG_R"); GVDel("HG_PNL0");
      GVDel("HG_CLOSED"); GVDel("HG_TP"); GVDel("HG_LASTTP");
      PurgeHedgeMarkers();
     }

private:
   bool              m_mutated;      // lifecycle changed the sleeve during this cycle

public:
                     CHedgeManager() { m_mutated=false; }

   bool              Mutated()    const { return(m_mutated); }
   void              BeginCycle()       { m_mutated=false;   }

   void              Init()
     {
      ClearState();
      LoadState();                      // restore if a hedge survived a restart
      g_hedge.active = false;           // resolved by SyncState() from live positions
     }

   //---------------------------------------------------------------
   //  Reconcile the lifecycle object with the real position sleeve.
   //  Runs on every book mutation and once per bar.
   //---------------------------------------------------------------
   void              SyncState(const SBookStats &bk)
     {
      if(bk.hedge_positions <= 0 || bk.hedge_lots <= 0.0)
        {
         if(g_hedge.active) Verbose("hedge sleeve flat -> lifecycle reset");
         ClearState();
         return;
        }
      if(!g_hedge.active)
        {
         LoadState();
         g_hedge.active = true;
         if(g_hedge.born_lots <= 0.0)  g_hedge.born_lots  = bk.hedge_lots;   // recovered
         if(g_hedge.born_time == 0)    g_hedge.born_time  = bk.hedge_first_time;
         if(g_hedge.born_price<= 0.0)  g_hedge.born_price = bk.hedge_wavg;
         if(g_hedge.anchor_R  <= 0.0)  g_hedge.anchor_R   = BookRMoney(bk);
         if(g_hedge.born_pnl  == 0.0)  g_hedge.born_pnl   = bk.total_pnl;
         if(g_hedge.closed_lots > g_hedge.born_lots) g_hedge.closed_lots = g_hedge.born_lots;
         Verbose("hedge lifecycle recovered from terminal state");
        }
      //--- self-heal: the sleeve can only shrink through our own unwinds
      if(g_hedge.born_lots < bk.hedge_lots)
        {
         g_hedge.born_lots = bk.hedge_lots;
         g_hedge.born_price= bk.hedge_wavg;
         SaveState();
        }
     }

   //---------------------------------------------------------------
   //  TRIGGER LOGIC -- a hedge is opened ONLY on
   //    (a) a drawdown-from-peak breach of InpHedgeDDTriggerPct, or
   //    (b) a confirmed regime flip: the fused score crosses
   //        InpHedgeFlipMinScore in the direction OPPOSITE the book.
   //  Never a blind opposite trade.
   //---------------------------------------------------------------
   bool              TriggerArmed(const SSignal &sig, const SBookStats &bk,
                                  const double ddPct, const double totalPnL,
                                  string &reason, double &severity, const bool allowFlip)
     {
      reason=""; severity=0.0;
      if(!InpEnableHedging)            return(false);
      if(g_hedge.active)               return(false);       // already hedged
      if(bk.book_positions <= 0)       return(false);       // nothing to protect
      double L = MathAbs(bk.book_net_lots);
      if(L <= 0.0)                     return(false);       // already delta neutral
      if(totalPnL >= 0.0)              return(false);       // book is not bleeding

      //--- (a) drawdown breach -- evaluated on EVERY tick (light path)
      double ddEff = EffectiveDD(bk,ddPct);
      if(InpHedgeDDTriggerPct > 0.0 && ddEff >= InpHedgeDDTriggerPct)
        {
         //--- graduated severity: 0 exactly at the breach, 1 at twice the
         //    trigger. This is what scales the hedge from the base ratio to
         //    the maximum ratio, so a marginal breach does NOT lock the book.
         severity = ClampD((ddEff - InpHedgeDDTriggerPct)/InpHedgeDDTriggerPct, 0.0, 1.0);
         reason   = StringFormat("DD breach %.2f%% >= trigger %.2f%% (peak DD %.2f%%, book loss %.2f)",
                                 ddEff, InpHedgeDDTriggerPct, ddPct, bk.total_pnl);
         return(true);
        }
      //--- (b) regime flip against the book, confirmed over N CLOSED bars.
      //    Only counted on the heavy (per-bar) path so the confirmation
      //    counter cannot be inflated by intra-bar ticks.
      if(!allowFlip) return(false);
      int bookDir = SignD(bk.book_net_lots);
      if(sig.valid && sig.direction == -bookDir && sig.score >= InpHedgeFlipMinScore)
         g_hedge.flip_bars++;
      else
         g_hedge.flip_bars = 0;
      int need = (int)MathMax(InpHedgeFlipConfirmBars,1);
      if(g_hedge.flip_bars >= need)
        {
         double denom = MathMax(1.0 - InpHedgeFlipMinScore, 1.0e-6);
         severity = ClampD((sig.score - InpHedgeFlipMinScore)/denom, 0.0, 1.0);
         reason   = StringFormat("regime flip vs book (%d bars, score %.3f, E %+.3f)",
                                 g_hedge.flip_bars, sig.score, sig.evidence);
         g_hedge.flip_bars = 0;
         return(true);
        }
      return(false);
     }

   //---------------------------------------------------------------
   //  HEDGE SIZE -- exact derivation.
   //
   //  Notation (book is net long when s = +1):
   //     s   = sign(net book lots)              L = |net book lots|
   //     W   = volume-weighted book entry       P0 = hedge execution price
   //     P_u = modelled unwind price = P0 - s*d,  d = UnwindATR * ATR
   //     CS  = contract size (oz per lot)       Rm  = R money of the book
   //     T   = InpHedgeTargetRecoveryR (R units, 0 = break-even)
   //
   //  Total P&L if the hedge is unwound at P_u:
   //     Pi(P_u) = s*L*CS*(P_u - W)      +      L_h*CS*d
   //               \__ directional book __/      \__ short/long hedge __/
   //  (the hedge leg carries signed volume -s*L_h and earns
   //   (-s*L_h)*CS*(P_u-P0) = L_h*CS*d because P0-P_u = s*d).
   //
   //  Impose the recovery requirement  Pi(P_u) >= T*Rm  and solve for L_h:
   //     L_h >= [ T*Rm - s*L*CS*(P_u - W) ] / (CS*d)
   //     L_h  = [ T*Rm/CS + s*L*(W - P_u) ] / d
   //  With A = s*(W - P0)  (adverse distance, >0 when the book is under
   //  water) and W - P_u = (W - P0) + s*d, this collapses to the closed form
   //
   //     L_h_required = L*(1 + A/d) + T*Rm/(CS*d)
   //
   //  Interpretation: a full delta-neutral hedge (L) PLUS an extra tranche
   //  proportional to how deep the book is under water relative to the
   //  expected unwind excursion, PLUS the R-based recovery term.
   //
   //  Severity scaling and caps (the hedge is a function of the recovery
   //  requirement, scaled by how bad the drawdown is, then capped):
   //     sev    = 0 at the trigger, 1 at 2x the trigger (or flip conviction)
   //     scale  = clamp(base + (max-base)*sev, base, max)      in [0,1]
   //     L_h    = clamp( scale * L_h_required , 0 , cap )
   //     cap    = min( maxRatio*L, InpHedgeMaxLots, room, affordable )
   //  Note scale <= maxRatio <= 1 and cap <= maxRatio*L, therefore
   //     L_h <= L  always:  the hedge can neutralize the book but can NEVER
   //     flip the account into a net opposite position.
   //---------------------------------------------------------------
   double            ComputeHedgeLots(const SBookStats &bk, const double atr,
                                      const double severity, const double totalPnL,
                                      string &detail)
     {
      detail="";
      double L = MathAbs(bk.book_net_lots);
      int    s = SignD(bk.book_net_lots);
      if(L <= 0.0 || s==0 || atr <= 0.0) return(0.0);
      double CS = (g_contractSize>0.0) ? g_contractSize : 100.0;
      double W  = bk.book_wavg;
      double P0 = (s>0) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)   // hedge is a SELL
                        : SymbolInfoDouble(_Symbol,SYMBOL_ASK);  // hedge is a BUY
      if(P0 <= 0.0 || W <= 0.0) return(0.0);

      double d  = MathMax(InpHedgeUnwindATR,0.1)*atr;            // expected unwind excursion
      double A  = (double)s*(W - P0);                            // adverse distance
      double Rm = BookRMoney(bk);
      if(Rm <= 0.0) Rm = AccountEquityNow()*InpRiskPctOfEquity/100.0*MathMax(L,1.0);
      double T  = InpHedgeTargetRecoveryR;

      double L_required = L*(1.0 + SafeDiv(A,d,0.0)) + SafeDiv(T*Rm, CS*d, 0.0);
      L_required = MathMax(L_required, 0.0);

      double base = ClampD(InpHedgeBaseRatio,0.0,1.0);
      double mx   = ClampD(MathMax(InpHedgeMaxRatio,base),base,1.0);
      double sev  = ClampD(severity,0.0,1.0);
      double scale= ClampD(base + (mx-base)*sev, base, mx);

      double room = MathMax(InpMaxTotalLots - bk.total_lots, 0.0);
      ENUM_ORDER_TYPE ht = (s>0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      double afford = MaxAffordableLots(ht, P0);
      double cap = MathMin(MathMin(mx*L, InpHedgeMaxLots), MathMin(room, afford));
      if(cap <= 0.0)
        {
         detail=StringFormat("hedge capped to zero (room=%.2f afford=%.2f maxRatio=%.2f L=%.2f)",
                             room,afford,mx,L);
         return(0.0);
        }
      double raw = ClampD(scale*L_required, 0.0, cap);
      bool   ok=false;
      double v   = NormalizeVolume(raw, ok);
      detail = StringFormat(
              "L=%.2f W=%.5f P0=%.5f A=%+.5f d=%.5f CS=%.0f Rm=%.2f T=%.2f PnL=%.2f | "
              "L_req=%.4f sev=%.2f scale=%.3f cap=%.4f -> %.2f lots%s",
              L,W,P0,A,d,CS,Rm,T,totalPnL,L_required,sev,scale,cap,v,
              ok ? "" : " (REJECTED: below broker minimum)");
      if(!ok) return(0.0);
      return(v);
     }

   //--- open the hedge leg (opposite to the book, wide catastrophe SL, no TP:
   //    the lifecycle manager owns the exit)
   bool              Open(const SBookStats &bk, const double atr, const double severity,
                          const string reason)
     {
      int s = SignD(bk.book_net_lots);
      if(s==0) return(false);
      string detail="";
      double lots = ComputeHedgeLots(bk, atr, severity, bk.total_pnl, detail);
      if(lots <= 0.0)
        {
         Print("QGE HEDGE skipped: ", detail, " | trigger: ", reason);
         return(false);
        }
      int    dir  = -s;                                        // opposite the book
      double mark = (dir>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double minStop = MinStopDistance();
      //--- catastrophe stop only: 3x the standard ATR stop, so the hedge is
      //    managed by the lifecycle logic, not by a tight stop.
      double slDist  = MathMax(3.0*InpSL_ATR_Mult*atr, minStop);
      double sl      = NormalizePrice((dir>0) ? mark-slDist : mark+slDist);
      ulong  ticket  = 0;
      bool   done    = g_pos.OpenMarket(dir, lots, sl, 0.0, InpTagHedge, true, ticket);
      if(!done)
        {
         Print("QGE HEDGE order failed | trigger: ", reason, " | sizing: ", detail);
         return(false);
        }
      g_hedge.active          = true;
      g_hedge.born_lots       = lots;
      g_hedge.closed_lots     = 0.0;
      g_hedge.born_time       = TimeCurrent();
      g_hedge.born_price      = mark;
      g_hedge.anchor_R        = BookRMoney(bk);
      g_hedge.born_pnl        = bk.total_pnl;      // P&L floor for the unwind ladder
      g_hedge.tp_levels_used  = 0;
      g_hedge.last_tp_level   = 0.0;
      g_hedge.flip_bars       = 0;
      SaveState();
      PrintFormat("QGE HEDGE OPENED: %s %.2f lots @ %.5f SL=%.5f | %s | %s",
                  (dir>0?"BUY":"SELL"), lots, mark, sl, reason, detail);
      return(true);
     }

   //---------------------------------------------------------------
   //  EFFECTIVE DRAWDOWN used by both the trigger and the unwind ladder:
   //     ddEff = max( peak-equity DD , open-book loss as % of equity )
   //  The peak-based term catches slow account bleed; the book-based term
   //  is immune to stale peaks (e.g. after a deposit) and reacts to the
   //  sleeve that is actually bleeding.
   //---------------------------------------------------------------
   double            EffectiveDD(const SBookStats &bk, const double peakDD)
     {
      double eq = AccountEquityNow();
      double bookLossPct = 0.0;
      if(eq > 1.0e-9 && bk.total_pnl < 0.0) bookLossPct = -bk.total_pnl/eq*100.0;
      return(MathMax(peakDD, bookLossPct));
     }

   //--- netting-account degradation: cut gross exposure instead of hedging
   bool              Deleverage(const SBookStats &bk, const double ratio, const string reason)
     {
      if((g_hedgeLogOnce & 1)==0)
        {
         g_hedgeLogOnce |= 1;
         Print("QGE: NETTING account detected - hedge sleeve replaced by delta reduction "
               "(partial close of the book).");
        }
      double target = MathAbs(bk.book_net_lots)*ClampD(ratio,0.0,1.0);
      bool did = CloseFractionOfSleeve(false, target, reason);
      if(did) m_mutated=true;
      return(did);
     }

   //---------------------------------------------------------------
   //  Close `lots` of volume from a sleeve, largest leg first.
   //---------------------------------------------------------------
   bool              CloseFractionOfSleeve(const bool hedgeSleeve, double lots, const string reason)
     {
      if(lots <= 0.0) return(false);
      double remaining = lots;
      for(int pass=0; pass<PositionsTotal()+1 && remaining > g_volMin*0.5; pass++)
        {
         ulong  bestTicket=0; double bestVol=0.0;
         for(int i=PositionsTotal()-1;i>=0;i--)
           {
            ulong tk=PositionGetTicket(i);
            if(tk==0) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol)        continue;
            if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
            string cmt=PositionGetString(POSITION_COMMENT);
            bool isH=(StringFind(cmt,InpTagHedge)>=0)||IsMarkedHedge(tk);
            if(isH!=hedgeSleeve) continue;
            double v=PositionGetDouble(POSITION_VOLUME);
            if(v>bestVol){ bestVol=v; bestTicket=tk; }
           }
         if(bestTicket==0) break;
         double take = MathMin(remaining, bestVol);
         bool   ok=false;
         double vn = NormalizeVolume(take, ok);
         if(!ok || vn<=0.0)
           {
            //--- cannot split further: only a full-leg close is broker-legal
            if(remaining >= bestVol*0.75)
              {
               if(!g_pos.CloseTicket(bestTicket,reason)) break;
               remaining -= bestVol;
               continue;
              }
            break;                                   // sub-minimum remainder: stop, never bump
           }
         if(vn >= bestVol - 1.0e-9)
           {
            if(!g_pos.CloseTicket(bestTicket,reason)) break;
            remaining -= bestVol;
           }
         else
           {
            if(!g_pos.ClosePartial(bestTicket,vn,reason)) break;
            remaining -= vn;
           }
        }
      return(remaining < lots - 1.0e-9);
     }

   //---------------------------------------------------------------
   //  MANAGE / UNWIND  (runs every tick -- cheap: uses the cached book)
   //
   //  Effective drawdown   ddEff = max(peak-equity DD, open-book loss % eq)
   //  Recovery progress    rho   = clamp( (trigger - ddEff) /
   //                                      (trigger*(1-releaseFrac)), 0, 1)
   //  Ladder rung          k*    = floor(rho * steps),  frac = k*/steps
   //  Cumulative unwind    target_closed = frac * born_lots
   //
   //  Money condition: intermediate rungs need only
   //     Pi >= min( Pi_birth - 0.10*Rm , frac*T*Rm )
   //  (i.e. "the drawdown recovered and we are not worse than when we
   //  hedged"), while the FINAL rung enforces the contractual recovery
   //  target  Pi >= T*R_money  (T=0 => break-even).
   //
   //  Hard exits (checked first, every tick) guarantee the account can
   //  never stay permanently locked in a two-sided position:
   //     0 orphan hedge (book gone)  1 anti-lock time stop
   //     2 regime re-flip in favour of the book
   //     3 hedge take-profit banking (partial close at each R level)
   //---------------------------------------------------------------
   void              Manage(const SSignal &sig, const SBookStats &bk,
                            const double ddPct, const double atr)
     {
      SyncState(bk);
      if(!g_hedge.active) return;

      double Rm = (g_hedge.anchor_R>0.0) ? g_hedge.anchor_R : BookRMoney(bk);
      if(Rm <= 0.0) Rm = AccountEquityNow()*InpRiskPctOfEquity/100.0;
      double T  = InpHedgeTargetRecoveryR;
      int    s  = SignD(bk.book_net_lots);

      //--- HARD EXIT 0: orphan hedge (the directional book is gone) -------
      if(bk.book_positions<=0 || s==0 || MathAbs(bk.book_net_lots)<=0.0)
        {
         Print("QGE HEDGE UNWIND (orphan): directional book is flat -> closing hedge sleeve");
         g_pos.CloseSleeve(true,"hedge-orphan-cleanup");
         ClearState();
         m_mutated=true;
         return;
        }
      //--- HARD EXIT 1: anti-lock time stop -------------------------------
      if(InpHedgeMaxAgeHours > 0 && g_hedge.born_time > 0)
        {
         double ageH = (double)(TimeCurrent()-g_hedge.born_time)/3600.0;
         if(ageH >= (double)InpHedgeMaxAgeHours)
           {
            PrintFormat("QGE HEDGE UNWIND (time stop): age %.1fh >= %dh", ageH, InpHedgeMaxAgeHours);
            g_pos.CloseSleeve(true,"hedge-time-stop");
            ClearState();
            m_mutated=true;
            return;
           }
        }
      //--- HARD EXIT 2: regime re-flip back in favour of the book ---------
      if(sig.valid && sig.direction == s && sig.score >= InpHedgeFlipMinScore)
        {
         PrintFormat("QGE HEDGE UNWIND (regime re-flip): score %.3f direction %+d matches book",
                     sig.score, s);
         g_pos.CloseSleeve(true,"hedge-regime-reflip");
         ClearState();
         m_mutated=true;
         return;
        }
      //--- SOFT EXIT 3: bank hedge profit at each R level -----------------
      if(InpHedgeTakeProfitR > 0.0 && Rm > 0.0)
        {
         double nextLevel = (double)(g_hedge.tp_levels_used+1)*InpHedgeTakeProfitR*Rm;
         if(bk.hedge_pnl >= nextLevel)
           {
            double pct = ClampD(InpHedgePartialClosePct,1.0,100.0)/100.0;
            double take= bk.hedge_lots*pct;
            PrintFormat("QGE HEDGE TAKE-PROFIT level %d: hedge P&L %.2f >= %.2f (%.2fR) -> closing %.1f%%",
                        g_hedge.tp_levels_used+1, bk.hedge_pnl, nextLevel,
                        InpHedgeTakeProfitR, pct*100.0);
            if(CloseFractionOfSleeve(true, take, "hedge-take-profit"))
              {
               g_hedge.tp_levels_used++;
               g_hedge.last_tp_level = nextLevel/Rm;
               g_hedge.closed_lots  += take;
               SaveState();
               m_mutated=true;
              }
            return;                                   // one lifecycle action per tick
           }
        }
      //--- SOFT EXIT 4: graduated drawdown-recovery ladder ----------------
      //    rho maps the effective drawdown onto [0,1]:
      //       ddEff = trigger            -> rho = 0 (hedge fully retained)
      //       ddEff = trigger*release    -> rho = 1 (hedge fully released)
      //    so InpHedgeReleaseDDFraction defines the recovery level at which
      //    the last tranche is unwound.
      double ddEff   = EffectiveDD(bk,ddPct);
      double trigger = MathMax(InpHedgeDDTriggerPct, 1.0e-6);
      double relFrac = ClampD(InpHedgeReleaseDDFraction,0.0,0.99);
      double span    = MathMax(trigger*(1.0-relFrac), 1.0e-9);
      double rho     = ClampD((trigger - ddEff)/span, 0.0, 1.0);
      int    steps   = (int)MathMax(InpHedgeUnwindLadderSteps,1);
      int    k       = (int)MathFloor(rho*(double)steps + 1.0e-9);
      if(k <= 0) return;                              // still in drawdown: hold the hedge
      double frac   = (double)k/(double)steps;
      //------------------------------------------------------------
      //  Money condition per tranche:
      //   - FINAL tranche (k == steps): the net book must be back at the
      //     contractual recovery target      Pi >= T * R_money
      //     (T = 0 => break-even, T < 0 => a bounded residual loss).
      //   - intermediate tranches: released by DRAWDOWN RECOVERY alone,
      //     guarded so we never unwind into a position worse than at hedge
      //     birth (minus a 0.10R allowance for accrued swap/commission).
      //------------------------------------------------------------
      double goal = (k>=steps) ? T*Rm
                               : MathMin(g_hedge.born_pnl - 0.10*Rm, frac*T*Rm);
      if(bk.total_pnl < goal) return;                 // not recovered enough in money terms
      double targetClosed = frac*g_hedge.born_lots;
      double toClose      = targetClosed - g_hedge.closed_lots;
      if(toClose <= 0.0) return;
      PrintFormat("QGE HEDGE UNWIND ladder step %d/%d: DD %.2f%% (rho %.2f), P&L %.2f >= goal %.2f -> closing %.2f lots",
                  k, steps, ddPct, rho, bk.total_pnl, goal, toClose);
      if(k >= steps)
        {
         g_pos.CloseSleeve(true,"hedge-full-unwind");
         ClearState();
         m_mutated=true;
         return;
        }
      if(CloseFractionOfSleeve(true, toClose, "hedge-ladder-unwind"))
        {
         g_hedge.closed_lots += toClose;
         SaveState();
         m_mutated=true;
        }
     }

   //--- lifecycle status string for the dashboard/log
   string            Status(const SBookStats &bk, const double ddPct)
     {
      if(!g_hedge.active) return("none");
      double ddEff   = EffectiveDD(bk,ddPct);
      double trigger = MathMax(InpHedgeDDTriggerPct,1.0e-6);
      double relFrac = ClampD(InpHedgeReleaseDDFraction,0.0,0.99);
      double rho     = ClampD((trigger-ddEff)/MathMax(trigger*(1.0-relFrac),1.0e-9), 0.0, 1.0);
      int steps = (int)MathMax(InpHedgeUnwindLadderSteps,1);
      return(StringFormat("%.2f lots (born %.2f, unwound %.2f) ddEff=%.2f%% rho=%.2f step=%d/%d age=%.1fh pnl=%.2f",
                          bk.hedge_lots, g_hedge.born_lots, g_hedge.closed_lots, ddEff, rho,
                          (int)MathFloor(rho*steps), steps,
                          (g_hedge.born_time>0)?(double)(TimeCurrent()-g_hedge.born_time)/3600.0:0.0,
                          bk.hedge_pnl));
     }
  };

CHedgeManager g_hedgeMgr;

//==================================================================
//  10. ACTIVATION MANAGER -- warm-up, bar guard, immediate activation
//==================================================================
class CActivationManager
  {
private:
   datetime          m_lastBar0;        // open time of bar 0 at the previous check
   bool              m_firstTickDone;

public:
                     CActivationManager() { m_lastBar0=0; m_firstTickDone=false; }

   void              Init()
     {
      m_lastBar0      = iTime(_Symbol,InpSignalTF,0);   // seed so only a REAL new bar counts
      m_firstTickDone = false;
     }

   //--- bar-change guard: true exactly once per newly opened bar 0
   bool              IsNewBar()
     {
      datetime t = iTime(_Symbol,InpSignalTF,0);
      if(t==0) return(false);                            // history not ready
      if(t != m_lastBar0)
        {
         m_lastBar0 = t;
         return(true);
        }
      return(false);
     }

   //--- cheap readiness probe (no data copy) for the per-tick path
   bool              CheapWarmupOK()
     {
      return(iBars(_Symbol,InpSignalTF) >= g_engine.RequiredBars()+1);
     }

   bool              FirstTickDone()      const { return(m_firstTickDone); }
   void              SetFirstTickDone()          { m_firstTickDone=true;   }
  };

CActivationManager g_act;

//==================================================================
//  11. ORCHESTRATION HELPERS
//==================================================================
void RefreshBookCheap() { g_pos.RefreshBook(g_book,false); }   // structural scan, cached commissions
void RefreshBookFull()  { g_pos.RefreshBook(g_book,true);  }   // + history-deal commission refresh
double CurrentATR()     { return(g_engine.ATR());          }   // volatility SCALAR

//--- readable name of the discrete Hurst regime band
string RegimeName(const int regime)
  {
   if(regime > 0) return("TRENDING");
   if(regime < 0) return("MEAN-REVERTING");
   return("NEUTRAL");
  }

//--- one-line, fully diagnostic rendering of a cached signal.
//    Format specifiers and arguments are strictly positional: keep in sync.
string SignalLine(const SSignal &s)
  {
   return(StringFormat(
     "bar=%s dir=%+d score=%.4f E=%+.4f | e[vol=%+.3f trend=%+.3f mrev=%+.3f micro=%+.3f] "
     "w[%.3f/%.3f/%.3f/%.3f] | YZann=%.2f%% GKann=%.2f%% volR=%.3f H=%.3f(vr=%.3f rs=%.3f) VR=%.3f | "
     "regime=%s volExp=%d | OLS slope=%+.3e t=%+.2f R2=%.3f drift=%.1f%%/yr z=%+.2f | "
     "micro EF=%.3f RE=%+.3f ACC=%+.2f | ATR=%.5f spread=%.5f",
     TimeToString(s.bar_time,TIME_DATE|TIME_MINUTES),   //  1 bar
     s.direction, s.score, s.evidence,                  //  2..4
     s.e_vol, s.e_trend, s.e_meanrev, s.e_micro,        //  5..8  pillar evidences
     s.w_vol, s.w_trend, s.w_meanrev, s.w_micro,        //  9..12 effective weights
     s.sigma_yz_ann*100.0, s.sigma_gk_ann*100.0,        // 13..14 annualized vol
     s.vol_ratio, s.hurst, s.hurst_vr, s.hurst_rs, s.vr,// 15..19 regime inputs
     RegimeName(s.regime), (int)s.vol_expanding,        // 20..21 regime labels
     s.slope, s.tstat, s.r2, s.drift_ann*100.0, s.zresid, // 22..26 OLS pillar
     s.efficiency, s.range_exp, s.accel,                // 27..29 microstructure
     s.atr, s.spread_price));                           // 30..31 scalars
  }

//==================================================================
//  12. ENTRY EXECUTION
//      Base entry and pyramid add-on share the same vol-normalized
//      sizing pipeline:  lots = riskMoney / lossPerLot(ATR-scaled SL).
//      Because the SL distance is ATR-scaled, lots ~ 1/ATR, so each leg
//      commits the SAME money risk regardless of the volatility regime.
//==================================================================
bool AttemptBaseEntry(const int dir, const bool forced)
  {
   string why="";
   if(dir==0)                       { Verbose("entry skipped: direction undecided");            return(false); }
   if(dir>0 && !InpAllowLong)       { Verbose("entry skipped: long entries disabled");           return(false); }
   if(dir<0 && !InpAllowShort)      { Verbose("entry skipped: short entries disabled");          return(false); }
   if(!g_risk.TradingPermitted(dir,why)) { VerboseT("entry blocked: "+why,30);                   return(false); }

   double atr=CurrentATR();
   if(atr<=0.0)                     { VerboseT("entry blocked: ATR scalar unavailable",30);      return(false); }
   if(!g_risk.SpreadOK(atr,0.0,why)){ VerboseT("entry blocked: "+why,30);                        return(false); }
   if(!g_risk.SessionOK(why))       { VerboseT("entry blocked: "+why,60);                        return(false); }

   double eq=AccountEquityNow();
   if(eq<=0.0) return(false);

   //--- SL distance: ATR scalar x multiple, floored at the broker stops level
   double slDist  = InpSL_ATR_Mult*atr;
   double minStop = MinStopDistance();
   if(slDist < minStop) slDist = minStop;                 // legality repair, not a risk bump
   slDist = NormalizePrice(slDist);
   if(slDist<=0.0) return(false);

   //--- global risk budget: new risk must fit under InpMaxTotalRiskPct
   double openRisk = g_risk.OpenRiskPct(MathAbs(g_book.book_net_lots),g_bookRPrice);
   double riskPct  = InpRiskPctOfEquity;
   if(InpMaxTotalRiskPct>0.0)
     {
      double room=InpMaxTotalRiskPct-openRisk;
      if(riskPct>room) riskPct=room;
     }
   if(riskPct<=0.0001)
     {
      VerboseT(StringFormat("entry blocked: aggregate risk budget exhausted (open %.2f%% / cap %.2f%%)",
                            openRisk,InpMaxTotalRiskPct),60);
      return(false);
     }
   double riskMoney = eq*riskPct/100.0;

   ENUM_ORDER_TYPE ot = (dir>0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry = (dir>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(entry<=0.0) return(false);

   double lots = g_risk.LotForRisk(riskMoney,slDist,ot,entry,why);
   if(lots<=0.0) { Print("QGE entry rejected: ",why); return(false); }

   //--- transaction-cost sanity gate: the estimated round-turn commission
   //    must not eat more than half of the money risked (otherwise the edge
   //    is dominated by costs and the trade is negative-expectancy ex ante).
   if(InpEstRoundTurnCommPerLot>0.0 && riskMoney>0.0 &&
      InpEstRoundTurnCommPerLot*lots > 0.5*riskMoney)
     {
      VerboseT(StringFormat("entry blocked: est. commission %.2f > 50%% of risk budget %.2f",
                            InpEstRoundTurnCommPerLot*lots,riskMoney),60);
      return(false);
     }

   //--- aggregate volume cap (never bump, only shrink or reject)
   double roomLots = InpMaxTotalLots - g_book.total_lots;
   if(roomLots < g_volMin)
     { VerboseT("entry blocked: total-lot cap reached",60); return(false); }
   if(lots > roomLots)
     {
      bool okc=false;
      double capped=NormalizeVolume(roomLots,okc);
      if(!okc){ VerboseT("entry blocked: residual lot capacity below broker minimum",60); return(false); }
      Verbose(StringFormat("entry volume shrunk %.2f -> %.2f by the total-lot cap",lots,capped));
      lots=capped;
     }

   double sl = NormalizePrice((dir>0) ? entry-slDist : entry+slDist);
   double tp = (InpTP_RR>0.0) ? NormalizePrice((dir>0) ? entry+slDist*InpTP_RR
                                                        : entry-slDist*InpTP_RR) : 0.0;
   ulong ticket=0;
   if(!g_pos.OpenMarket(dir,lots,sl,tp,InpTagBook,false,ticket)) return(false);

   //--- anchor R for the whole book (break-even / trailing / hedge R-money)
   g_bookRPrice = slDist;
   GVSet("RPRICE",slDist);
   g_entriesToday++;
   g_idleBars=0;
   RefreshBookFull();
   PrintFormat("QGE BASE ENTRY %s: %.2f lots entry~%.5f SL=%.5f TP=%.5f R=%.5f risk=%.2f%% ($%.2f)%s",
               (dir>0?"LONG":"SHORT"), lots, entry, sl, tp, slDist, riskPct, riskMoney,
               forced ? "  [IDLE-GUARD FORCED]" : "");
   Verbose(SignalLine(g_signal));
   return(true);
  }

//--- pyramid add-on: scale INTO the confirmed direction only
bool AttemptPyramid(const int dir)
  {
   if(!InpEnablePyramiding) return(false);
   if(g_hedge.active)      { VerboseT("add-on suspended: hedge lifecycle active",60); return(false); }
   int s = SignD(g_book.book_net_lots);
   if(s==0) return(false);
   if(dir!=s)
     {
      VerboseT(StringFormat("add-on rejected: fresh signal %+d opposes the open book %+d (never scale against)",
                            dir,s),60);
      return(false);
     }
   if(g_book.scale_ins >= InpMaxScaleIns)
     { VerboseT(StringFormat("add-on cap reached (%d/%d)",g_book.scale_ins,InpMaxScaleIns),120); return(false); }
   if(g_signal.score < InpAddOnMinScore)
     { VerboseT(StringFormat("add-on deferred: score %.3f < %.3f",g_signal.score,InpAddOnMinScore),60); return(false); }
   if(InpAddOnRequireProfit && g_book.book_pnl <= 0.0)
     { VerboseT(StringFormat("add-on deferred: book P&L %.2f not positive",g_book.book_pnl),60); return(false); }

   string why="";
   if(!g_risk.TradingPermitted(dir,why)) { VerboseT("add-on blocked: "+why,30); return(false); }
   double atr=CurrentATR();
   if(atr<=0.0) return(false);
   if(!g_risk.SpreadOK(atr,0.0,why))     { VerboseT("add-on blocked: "+why,30); return(false); }
   if(!g_risk.SessionOK(why))            { VerboseT("add-on blocked: "+why,60); return(false); }

   //--- ATR-scaled minimum spacing from the most recent book entry
   double entry=(dir>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(entry<=0.0) return(false);
   if(g_book.book_last_entry>0.0)
     {
      double gap=MathAbs(entry-g_book.book_last_entry);
      double need=InpSpacingATR*atr;
      if(gap < need)
        {
         VerboseT(StringFormat("add-on deferred: spacing %.5f < %.2f x ATR (%.5f)",gap,InpSpacingATR,need),60);
         return(false);
        }
     }

   //------------------------------------------------------------
   //  ADD-ON RISK BUDGET = geometric decay x base add-on risk,
   //  then capped by fractional Kelly:
   //     riskPct_k = RiskPct * (AddOnRiskScale/100) * decay^k
   //     f*        = (p*b - (1-p))/b ,  b = TP/SL payoff, p = score
   //     riskPct_k = min(riskPct_k, KellyFraction*f* , RiskPct)
   //  Kelly can only SHRINK the budget (it is a cap, never a booster).
   //------------------------------------------------------------
   int    k      = g_book.scale_ins+1;
   double decay  = MathPow(ClampD(InpSizeDecay,0.0,1.0),(double)k);
   double riskPct= InpRiskPctOfEquity*(InpAddOnRiskScalePct/100.0)*decay;
   double kelly  = g_risk.KellyCappedRiskPct(g_signal.score,MathMax(InpTP_RR,1.0e-6));
   if(kelly<=0.0)
     {
      VerboseT(StringFormat("add-on rejected: Kelly edge non-positive (score %.3f, payoff %.2f)",
                            g_signal.score,InpTP_RR),60);
      return(false);
     }
   if(kelly < riskPct) riskPct = kelly;

   double openRisk=g_risk.OpenRiskPct(MathAbs(g_book.book_net_lots),g_bookRPrice);
   if(InpMaxTotalRiskPct>0.0)
     {
      double room=InpMaxTotalRiskPct-openRisk;
      if(riskPct>room) riskPct=room;
     }
   if(riskPct<=0.0001)
     {
      VerboseT(StringFormat("add-on blocked: aggregate risk budget exhausted (open %.2f%% / cap %.2f%%)",
                            openRisk,InpMaxTotalRiskPct),60);
      return(false);
     }
   double eq=AccountEquityNow();
   double riskMoney=eq*riskPct/100.0;

   double slDist  = InpSL_ATR_Mult*atr;
   double minStop = MinStopDistance();
   if(slDist<minStop) slDist=minStop;
   slDist=NormalizePrice(slDist);
   if(slDist<=0.0) return(false);

   ENUM_ORDER_TYPE ot=(dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double lots=g_risk.LotForRisk(riskMoney,slDist,ot,entry,why);
   if(lots<=0.0){ Print("QGE add-on rejected: ",why); return(false); }
   if(InpEstRoundTurnCommPerLot>0.0 && riskMoney>0.0 &&
      InpEstRoundTurnCommPerLot*lots > 0.5*riskMoney)
     {
      VerboseT(StringFormat("add-on blocked: est. commission %.2f > 50%% of risk budget %.2f",
                            InpEstRoundTurnCommPerLot*lots,riskMoney),60);
      return(false);
     }

   double roomLots=InpMaxTotalLots-g_book.total_lots;
   if(roomLots<g_volMin){ VerboseT("add-on blocked: total-lot cap reached",60); return(false); }
   if(lots>roomLots)
     {
      bool okc=false;
      double capped=NormalizeVolume(roomLots,okc);
      if(!okc){ VerboseT("add-on blocked: residual lot capacity below broker minimum",60); return(false); }
      lots=capped;
     }

   double sl=NormalizePrice((dir>0)?entry-slDist:entry+slDist);
   double tp=(InpTP_RR>0.0)?NormalizePrice((dir>0)?entry+slDist*InpTP_RR:entry-slDist*InpTP_RR):0.0;
   ulong ticket=0;
   if(!g_pos.OpenMarket(dir,lots,sl,tp,InpTagPyramid,false,ticket)) return(false);

   g_entriesToday++;
   RefreshBookFull();
   PrintFormat("QGE PYRAMID #%d %s: %.2f lots entry~%.5f SL=%.5f TP=%.5f risk=%.3f%% ($%.2f) decay=%.3f kellyCap=%.3f%% | book net %+.2f lots wavg %.5f",
               k,(dir>0?"LONG":"SHORT"),lots,entry,sl,tp,riskPct,riskMoney,decay,kelly*100.0,
               g_book.book_net_lots,g_book.book_wavg);
   //--- R anchor is intentionally NOT re-based: break-even, trailing and the
   //    hedge R-money stay expressed in the ORIGINAL book R for consistency.
   return(true);
  }

//==================================================================
//  13. PER-TICK LIGHTWEIGHT PASS (guards, hedge lifecycle, stops)
//      Called from OnTick AND OnTimer. Never recomputes statistics.
//==================================================================
bool RunLightPass()
  {
   bool mutated=false;
   g_hedgeMgr.BeginCycle();
   g_risk.Update();                       // day rollover + peak-equity tracking
   RefreshBookCheap();                    // structural scan only (commissions cached)

   //--- realized P&L of the day, refreshed at most every 5 simulated seconds
   if(g_lastDailyScan==0 || (int)(TimeCurrent()-g_lastDailyScan)>=5)
     {
      g_realizedToday = g_risk.RealizedSinceDayStart();
      g_lastDailyScan = TimeCurrent();
     }

   double ddPct=0.0, dayPnL=0.0, limitMoney=0.0;
   bool floorHit = g_risk.EquityFloorBreached(ddPct);
   bool dailyHit = g_risk.DailyLossBreached(g_book.total_pnl,dayPnL,limitMoney);
   g_haltNewEntries = floorHit || dailyHit || g_killFired;
   if(dailyHit)
      VerboseT(StringFormat("GUARD daily-loss: day P&L %.2f <= limit %.2f (%.2f%% of %.2f) - new entries halted",
                            dayPnL,limitMoney,InpDailyLossLimitPct,g_risk.DayStartEquity()),120);
   if(floorHit)
      VerboseT(StringFormat("GUARD equity-floor: DD %.2f%% >= %.2f%% of peak %.2f - new entries halted",
                            ddPct,InpEquityFloorDDPct,g_risk.PeakEquity()),120);

   //--- kill switch (optional flattening), fired once per breach episode
   if(floorHit && InpKillSwitchCloseAll && !g_killFired)
     {
      g_killFired=true;
      Print("QGE KILL SWITCH: equity floor breached -> flattening hedge and book");
      g_pos.CloseSleeve(true ,"kill-switch-hedge");
      g_pos.CloseSleeve(false,"kill-switch-book");
      RefreshBookFull();
      mutated=true;
     }
   if(!floorHit && g_killFired) g_killFired=false;          // re-arm after recovery

   //--- hedge TRIGGER, drawdown leg only (the regime-flip leg needs the
   //    per-bar signal and is evaluated in OnTick Section C)
   if(InpEnableHedging && !g_hedge.active && !g_killFired && g_book.book_positions>0 && !g_haltNewEntries)
     {
      string reason=""; double sev=0.0;
      if(g_hedgeMgr.TriggerArmed(g_signal,g_book,ddPct,g_book.total_pnl,reason,sev,false))
        {
         if(g_hedgingAccount)
           {
            if(g_hedgeMgr.Open(g_book,CurrentATR(),sev,reason)) { RefreshBookFull(); mutated=true; }
           }
         else
           {
            double ratio=ClampD(InpHedgeBaseRatio+(InpHedgeMaxRatio-InpHedgeBaseRatio)*sev,0.0,1.0);
            g_hedgeMgr.Deleverage(g_book,ratio,reason);
            RefreshBookFull();
            mutated=true;
           }
        }
     }

   //--- hedge lifecycle: unwind ladder / take-profit / time stop / orphan
   if(g_hedge.active || g_book.hedge_positions>0)
      g_hedgeMgr.Manage(g_signal,g_book,ddPct,CurrentATR());

   //--- aggregate stop management (break-even + ATR trailing)
   if(g_book.book_positions>0 && !g_killFired)
      g_pos.ManageStops(g_book,CurrentATR());

   //--- flat book housekeeping: release the persisted R anchor
   if(g_book.book_positions==0 && g_book.hedge_positions==0 && g_bookRPrice>0.0)
     {
      g_bookRPrice=0.0;
      GVDel("RPRICE");
     }
   if(g_hedgeMgr.Mutated()) mutated=true;
   return(mutated);
  }

//--- closed-bar bookkeeping (heavy path only)
void OnClosedBar()
  {
   if(g_entryDay != g_risk.DayStart()) { g_entryDay=g_risk.DayStart(); g_entriesToday=0; }
   if(g_book.book_positions==0 && !g_hedge.active) g_idleBars++;
   else                                            g_idleBars=0;
   RefreshBookFull();                               // commission cache refresh, 1x per bar
   Verbose(StringFormat("closed bar %s | idle bars %d | book legs %d net %+.2f | hedge %s",
                        TimeToString(g_lastBarTime,TIME_DATE|TIME_MINUTES), g_idleBars,
                        g_book.book_positions, g_book.book_net_lots,
                        g_hedge.active ? "ACTIVE" : "none"));
  }

//==================================================================
//  14. DASHBOARD
//==================================================================
void UpdateDashboard()
  {
   if(!InpShowDashboard) return;
   datetime now=TimeCurrent();
   if(g_lastDash!=0 && (int)(now-g_lastDash)<1) return;      // 1 Hz throttle
   g_lastDash=now;
   double dd=0.0; g_risk.EquityFloorBreached(dd);
   double dayPnL=0.0, lim=0.0;
   g_risk.DailyLossBreached(g_book.total_pnl,dayPnL,lim);
   double openRisk=g_risk.OpenRiskPct(MathAbs(g_book.book_net_lots),g_bookRPrice);
   string txt="";
   double askNow=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bidNow=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spreadNow=(askNow>0.0 && bidNow>0.0) ? askNow-bidNow : 0.0;
   txt += "QGE_XAUUSD_Pro  "+EnumToString(InpSignalTF)
        + (g_goldSymbol    ? "" : "  [NON-GOLD SYMBOL]")
        + (g_hedgingAccount? "" : "  [NETTING -> delta-reduction mode]")
        + (g_act.FirstTickDone() ? "" : "  [FIRST-TICK ARMED]") + "\n";
   txt += StringFormat("signal : dir %+d  score %.3f (thr %.2f)  E %+.4f  %s  warmup %s\n",
                       g_signal.direction, g_signal.score, InpConfidenceThreshold, g_signal.evidence,
                       g_signal.valid ? TimeToString(g_signal.bar_time,TIME_DATE|TIME_MINUTES) : "n/a",
                       g_warmupReady ? "READY" : "pending");
   txt += StringFormat("pillars: vol %+.2f  trend %+.2f  mrev %+.2f  micro %+.2f | H %.3f  VR %.2f  volR %.2f\n",
                       g_signal.e_vol,g_signal.e_trend,g_signal.e_meanrev,g_signal.e_micro,
                       g_signal.hurst,g_signal.vr,g_signal.vol_ratio);
   txt += StringFormat("regime : %s  vol %s  weights[vol %.2f trend %.2f mrev %.2f micro %.2f]\n",
                       RegimeName(g_signal.regime),
                       (g_signal.vol_expanding?"EXPANDING":"contracting"),
                       g_signal.w_vol,g_signal.w_trend,g_signal.w_meanrev,g_signal.w_micro);
   txt += StringFormat("stats  : t %+.2f  R2 %.3f  z %+.2f  EF %.3f  RE %+.3f  ACC %+.2f  ATR %.5f\n",
                       g_signal.tstat,g_signal.r2,g_signal.zresid,
                       g_signal.efficiency,g_signal.range_exp,g_signal.accel,CurrentATR());
   txt += StringFormat("market : ask %.5f  bid %.5f  spread %.5f (%.1f pts, max %d pts / %.0f%% ATR)\n",
                       askNow,bidNow,spreadNow,SafeDiv(spreadNow,g_symbolPoint,0.0),
                       InpMaxSpreadPoints,InpMaxSpreadPctOfATR*100.0);
   txt += StringFormat("book   : %d legs (scale-ins %d/%d)  net %+.2f lots  wavg %.5f  pnl %.2f  R %.5f  age %.1fh\n",
                       g_book.book_positions,g_book.scale_ins,InpMaxScaleIns,
                       g_book.book_net_lots,g_book.book_wavg,g_book.book_pnl,g_bookRPrice,
                       (g_book.book_first_time>0)?(double)(TimeCurrent()-g_book.book_first_time)/3600.0:0.0);
   txt += StringFormat("delta  : book %+.2f  hedge %+.2f  => net %+.2f lots  margin %.2f  PnL ratio %.3f\n",
                       g_book.book_net_lots,g_book.hedge_signed,g_book.net_signed_lots,g_book.margin_used,
                       SafeDiv(g_book.book_pnl,MathMax(AccountEquityNow(),1.0e-9),0.0));
   txt += StringFormat("hedge  : %s\n", g_hedgeMgr.Status(g_book,dd));
   txt += StringFormat("account: eq %.2f  bal %.2f  peak %.2f  DD %.2f%%  dayPnL %.2f/%.2f\n",
                       AccountEquityNow(),AccountBalanceNow(),g_risk.PeakEquity(),dd,dayPnL,lim);
   txt += StringFormat("risk   : open %.2f%% / cap %.2f%%  lots %.2f/%.2f  entries %d/%d  idle %d/%d  halt %s\n",
                       openRisk,InpMaxTotalRiskPct,g_book.total_lots,InpMaxTotalLots,
                       g_entriesToday,InpMaxTradesPerDay,g_idleBars,InpForceEntryAfterIdleBars,
                       g_haltNewEntries?"YES":"no");
   Comment(txt);
  }

//==================================================================
//  15. INPUT VALIDATION  (inputs are read-only, so broken values must
//      fail the init instead of being silently clamped)
//==================================================================
bool ValidateInputs()
  {
   bool ok=true;
   if(InpYZFastWindow < 5)                        { Print("QGE INPUT ERROR: InpYZFastWindow must be >= 5"); ok=false; }
   if(InpYZSlowWindow < InpYZFastWindow+5)        { Print("QGE INPUT ERROR: InpYZSlowWindow must exceed InpYZFastWindow by >= 5"); ok=false; }
   if(InpOLSWindow < 6)                           { Print("QGE INPUT ERROR: InpOLSWindow must be >= 6"); ok=false; }
   if(InpZWindow < 6)                             { Print("QGE INPUT ERROR: InpZWindow must be >= 6"); ok=false; }
   if(InpVRLag < 2)                               { Print("QGE INPUT ERROR: InpVRLag must be >= 2"); ok=false; }
   if(InpVRWindow < InpVRLag+10)                  { Print("QGE INPUT ERROR: InpVRWindow must be >= InpVRLag+10"); ok=false; }
   if(InpHurstRSWindow < 32)                      { Print("QGE INPUT ERROR: InpHurstRSWindow must be >= 32"); ok=false; }
   if(InpEffWindow < 2)                           { Print("QGE INPUT ERROR: InpEffWindow must be >= 2"); ok=false; }
   if(InpMomFast < 1)                             { Print("QGE INPUT ERROR: InpMomFast must be >= 1"); ok=false; }
   if(InpMomSlow < InpMomFast+1)                  { Print("QGE INPUT ERROR: InpMomSlow must be >= InpMomFast+1"); ok=false; }
   if(InpRangeWindow < 2)                         { Print("QGE INPUT ERROR: InpRangeWindow must be >= 2"); ok=false; }
   if(InpSigmoidGain <= 0.0)                      { Print("QGE INPUT ERROR: InpSigmoidGain must be > 0"); ok=false; }
   if(InpConfidenceThreshold < 0.5 || InpConfidenceThreshold > 0.99)
     { Print("QGE INPUT ERROR: InpConfidenceThreshold must lie in [0.50, 0.99]"); ok=false; }
   if(InpWVol<0.0 || InpWTrend<0.0 || InpWMeanRev<0.0 || InpWMicro<0.0 ||
      (InpWVol+InpWTrend+InpWMeanRev+InpWMicro) <= 0.0)
     { Print("QGE INPUT ERROR: pillar weights must be >= 0 with a positive sum"); ok=false; }
   if((InpMicroWEff+InpMicroWAccel+InpMicroWExp) <= 0.0)
     { Print("QGE INPUT ERROR: microstructure sub-weights must sum to > 0"); ok=false; }
   if(InpATRPeriod < 2)                           { Print("QGE INPUT ERROR: InpATRPeriod must be >= 2"); ok=false; }
   if(InpSL_ATR_Mult <= 0.0)                      { Print("QGE INPUT ERROR: InpSL_ATR_Mult must be > 0"); ok=false; }
   if(InpRiskPctOfEquity <= 0.0 || InpRiskPctOfEquity > 100.0)
     { Print("QGE INPUT ERROR: InpRiskPctOfEquity must lie in (0, 100]"); ok=false; }
   if(InpSizeDecay < 0.0 || InpSizeDecay > 1.0)   { Print("QGE INPUT ERROR: InpSizeDecay must lie in [0, 1]"); ok=false; }
   if(InpMaxScaleIns < 0)                         { Print("QGE INPUT ERROR: InpMaxScaleIns must be >= 0"); ok=false; }
   if(InpKellyFraction < 0.0 || InpKellyFraction > 1.0)
     { Print("QGE INPUT ERROR: InpKellyFraction must lie in [0, 1]"); ok=false; }
   if(InpHedgeBaseRatio < 0.0 || InpHedgeBaseRatio > 1.0 ||
      InpHedgeMaxRatio  < InpHedgeBaseRatio || InpHedgeMaxRatio > 1.0)
     { Print("QGE INPUT ERROR: hedge ratios must satisfy 0 <= base <= max <= 1"); ok=false; }
   if(InpHedgeUnwindLadderSteps < 1)              { Print("QGE INPUT ERROR: InpHedgeUnwindLadderSteps must be >= 1"); ok=false; }
   if(InpHedgeUnwindATR <= 0.0)                   { Print("QGE INPUT ERROR: InpHedgeUnwindATR must be > 0"); ok=false; }
   if(InpTrendHurst <= InpMeanRevHurst || InpTrendHurst >= 1.0 || InpMeanRevHurst <= 0.0)
     { Print("QGE INPUT ERROR: need 0 < InpMeanRevHurst < InpTrendHurst < 1"); ok=false; }
   if(InpVolExpansionRatio <= 0.0)                { Print("QGE INPUT ERROR: InpVolExpansionRatio must be > 0"); ok=false; }
   if(InpMagicNumber <= 0)                        { Print("QGE INPUT ERROR: InpMagicNumber must be > 0"); ok=false; }
   if(InpUseTimer && InpTimerSeconds < 1)         { Print("QGE INPUT ERROR: InpTimerSeconds must be >= 1"); ok=false; }
   return(ok);
  }

//==================================================================
//  16. OnInit -- SMART IMMEDIATE ACTIVATION
//      validate -> cache symbol spec -> create the ONE indicator handle
//      -> anchor day/peak equity -> prime buffers -> compute the first
//      signal NOW so the very first OnTick can trade without waiting for
//      a bar close.
//==================================================================
int OnInit()
  {
   Print("================================================================================");
   Print("QGE_XAUUSD_Pro  v1.00  --  Quantitative Gold Edge (statistical microstructure EA)");
   Print("================================================================================");

   if(!ValidateInputs()) return(INIT_PARAMETERS_INCORRECT);

   //--- cache the broker symbol specification once (no repeated queries)
   g_digits       = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_symbolPoint  = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_volMin       = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_volMax       = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_volStep      = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_tickSize     = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   g_tickValue    = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   g_contractSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   g_stopsLevel   = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevel  = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   if(g_symbolPoint <= 0.0)  { Print("QGE FATAL: SYMBOL_POINT unavailable"); return(INIT_FAILED); }
   if(g_digits <= 0)          g_digits       = 2;
   if(g_volMin <= 0.0)        g_volMin       = 0.01;
   if(g_volMax <= 0.0)        g_volMax       = 100.0;
   if(g_volStep <= 0.0)       g_volStep      = 0.01;
   if(g_contractSize <= 0.0)  g_contractSize = 100.0;
   PrintFormat("QGE symbol spec: %s digits=%d point=%.5f vol[min=%.2f max=%.2f step=%.2f] "
               "tick[size=%.5f value=%.5f] contract=%.2f stops=%d freeze=%d",
               _Symbol,g_digits,g_symbolPoint,g_volMin,g_volMax,g_volStep,
               g_tickSize,g_tickValue,g_contractSize,(int)g_stopsLevel,(int)g_freezeLevel);

   //--- instrument validation (gold). Default is warn-only so a non-gold
   //    chart never becomes a "refuse to trade" failure mode.
   string up=_Symbol;
   StringToUpper(up);
   g_goldSymbol = (StringFind(up,"XAU")>=0 || StringFind(up,"GOLD")>=0 || StringFind(up,"GC=")>=0);
   if(!g_goldSymbol)
     {
      if(InpRequireGoldSymbol)
        {
         Print("QGE FATAL: symbol ",_Symbol," is not a gold instrument and InpRequireGoldSymbol=true");
         return(INIT_FAILED);
        }
      Print("QGE WARNING: symbol ",_Symbol," does not look like gold (XAU/GOLD). ",
            "Continuing - the model is scale free (log prices) but review InpBarsPerYear, ",
            "spread limits and the ATR multiples for this instrument.");
     }

   //--- account margin mode: hedging is required for a true two-sided hedge
   long mm = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_hedgingAccount = (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!g_hedgingAccount)
      Print("QGE WARNING: account margin mode is NOT retail-hedging. ",
            "The hedge sleeve is replaced by delta reduction (partial book close) ",
            "so no opposite position is ever mis-interpreted as a netting flip.");

   //--- trade object: magic isolation, deviation, filling policy
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetDeviationInPoints((ulong)MathMax(InpSlippagePoints,0));
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   //--- ONE indicator handle for the whole life of the EA
   if(!g_engine.Init()) return(INIT_FAILED);

   //--- risk anchors (day-start equity, peak equity)
   if(!g_risk.Init()) return(INIT_FAILED);

   //--- hedge lifecycle restore + first book snapshot
   g_hedgeMgr.Init();
   RefreshBookFull();
   g_bookRPrice = GVGet("RPRICE",0.0);
   if(g_book.book_positions==0)
     {
      if(g_bookRPrice>0.0) Print("QGE: stale R anchor discarded (book is flat)");
      g_bookRPrice=0.0;
      GVDel("RPRICE");
     }
   else
     {
      if(g_bookRPrice<=0.0)
        {
         g_bookRPrice = g_pos.InferRPrice();       // rebuild from the base leg's own stop
         if(g_bookRPrice>0.0)
           {
            GVSet("RPRICE",g_bookRPrice);
            PrintFormat("QGE: R anchor rebuilt from the oldest leg's stop: %.5f",g_bookRPrice);
           }
         else
            Print("QGE WARNING: no R anchor available for the existing book - break-even, "
                  "trailing and hedge R-math fall back to equity x risk% until the next entry");
        }
      PrintFormat("QGE: attached to an existing book: %d legs net %+.2f lots wavg %.5f R %.5f (scale-ins %d)",
                  g_book.book_positions,g_book.book_net_lots,g_book.book_wavg,g_bookRPrice,g_book.scale_ins);
     }

   //--- activation state
   g_signal.Reset();
   g_act.Init();
   g_lastBarTime        = 0;
   g_idleBars           = 0;
   g_haltNewEntries     = false;
   g_killFired          = false;
   g_lastComputeAttempt = 0;
   g_lastDash           = 0;
   g_lastLog            = 0;
   g_entryDay           = g_risk.DayStart();
   g_entriesToday       = 0;
   g_warmupReady        = false;
   g_forceFirstTick     = InpTradeOnFirstTick;

   //--- PRIME + PRE-COMPUTE now: this is what makes the first OnTick able to
   //    send a market order immediately instead of waiting for a bar close.
   if(g_engine.Prime(true))
     {
      g_warmupReady=true;
      SSignal s0;
      if(g_engine.Compute(s0))
        {
         g_signal      = s0;
         g_lastBarTime = s0.bar_time;
         Print("QGE PRE-COMPUTED SIGNAL @init ", SignalLine(s0));
         PrintFormat("QGE readiness: %d closed bars (need %d) -- first tick will %s",
                     g_engine.Have(), g_engine.RequiredBars(),
                     (s0.score>=InpConfidenceThreshold && s0.direction!=0)
                        ? "ATTEMPT AN ENTRY" : "evaluate again and stand by");
        }
      else
         Print("QGE: signal pre-computation failed at init (will retry on the first tick)");
     }
   else
      PrintFormat("QGE: warm-up pending at init -- %d/%d closed bars on %s. Re-checked every tick.",
                  iBars(_Symbol,InpSignalTF), g_engine.RequiredBars()+1, EnumToString(InpSignalTF));

   if(InpUseTimer) EventSetTimer((int)MathMax(InpTimerSeconds,1));

   PrintFormat("QGE config: risk=%.2f%%/trade cap=%.2f%% maxLots=%.2f conf>=%.2f gain=%.1f SL=%.1fxATR TP=%.1fR "
               "pyramid=%d decay=%.2f spacing=%.1fxATR hedge=%s trigger=%.2f%% ratio[%.2f..%.2f] T=%.2fR unwind=%.1fxATR",
               InpRiskPctOfEquity,InpMaxTotalRiskPct,InpMaxTotalLots,InpConfidenceThreshold,InpSigmoidGain,
               InpSL_ATR_Mult,InpTP_RR,InpMaxScaleIns,InpSizeDecay,InpSpacingATR,
               InpEnableHedging?"ON":"OFF",InpHedgeDDTriggerPct,InpHedgeBaseRatio,InpHedgeMaxRatio,
               InpHedgeTargetRecoveryR,InpHedgeUnwindATR);
   UpdateDashboard();
   return(INIT_SUCCEEDED);
  }

//==================================================================
//  17. OnDeinit -- release every resource
//==================================================================
void OnDeinit(const int reason)
  {
   if(InpUseTimer) EventKillTimer();
   GVSet("PEAK",g_risk.PeakEquity());
   if(g_book.book_positions>0 && g_bookRPrice>0.0) GVSet("RPRICE",g_bookRPrice);
   g_engine.Deinit();                       // releases the iATR handle
   Comment("");
   PrintFormat("QGE deinit reason=%d | equity=%.2f peak=%.2f | book legs=%d net=%+.2f | hedge=%s",
               reason,AccountEquityNow(),g_risk.PeakEquity(),
               g_book.book_positions,g_book.book_net_lots,
               g_hedge.active?"ACTIVE":"none");
  }

//==================================================================
//  18. OnTick
//      SECTION A -- per-tick lightweight: guards, hedge lifecycle, stops
//      SECTION B -- per-CLOSED-BAR heavy: priming + full signal recompute
//                  (plus the single forced computation on the first tick)
//      SECTION C -- decisions taken on the cached signal (entries/pyramiding)
//==================================================================
void OnTick()
  {
   //=========================== SECTION A =================================
   bool mutated = RunLightPass();
   if(mutated) RefreshBookCheap();          // a lifecycle action changed the sleeve

   //=========================== SECTION B =================================
   bool     newBar     = g_act.IsNewBar();
   bool     forced     = g_forceFirstTick;
   bool     canEnter   = newBar || forced;
   datetime lastClosed = iTime(_Symbol,InpSignalTF,1);
   bool     cacheFresh = (g_signal.valid && lastClosed>0 && g_signal.bar_time==lastClosed);

   bool freshSignal=false;                 // a signal that belongs to THIS closed bar
   if(canEnter)
     {
      //--- warm-up readiness: cheap probe first, real priming only when a
      //    heavy computation is actually due (never more than once per bar)
      if(!g_act.CheapWarmupOK())
        {
         g_warmupReady=false;
         VerboseT(StringFormat("warm-up pending: %d/%d closed bars on %s -- re-checking every tick",
                               iBars(_Symbol,InpSignalTF), g_engine.RequiredBars()+1,
                               EnumToString(InpSignalTF)),30);
         UpdateDashboard();
         return;                            // forced flag survives: retried next tick
        }

      //--- decide whether a heavy computation is due for this tick
      bool doCompute = !cacheFresh;
      if(doCompute && forced && !newBar)
         //--- first-tick retry path only: bounded to one attempt per second so
         //    a not-yet-calculated ATR buffer can never stall activation.
         doCompute = (g_lastComputeAttempt==0 || (int)(TimeCurrent()-g_lastComputeAttempt)>=1);

      if(doCompute)
        {
         g_lastComputeAttempt=TimeCurrent();
         if(g_engine.Prime(true))
           {
            g_warmupReady=true;
            SSignal fresh;
            if(g_engine.Compute(fresh))
              {
               g_signal      = fresh;       // cache: at most one heavy pass per bar
               g_lastBarTime = fresh.bar_time;
               freshSignal   = true;
               if(InpVerboseLog) Print("QGE SIGNAL ",SignalLine(fresh));
              }
            else
              {
               //--- degenerate/insufficient data for this bar: drop the cache so
               //    no decision can ever be taken on statistics from another bar.
               g_signal.Reset();
               VerboseT("signal computation rejected this bar (degenerate data) -- cache invalidated",60);
              }
           }
         else
           {
            g_warmupReady=false;
            g_signal.Reset();
           }
        }
      else if(cacheFresh)
        {
         //--- OnInit already computed THIS closed bar: reuse the cache.
         //    Heavy statistics are never recomputed twice for one bar.
         freshSignal=true;
         if(forced)
            Verbose("first tick: reusing the pre-computed signal for bar "+
                    TimeToString(g_signal.bar_time,TIME_DATE|TIME_MINUTES));
        }

      //--- the one-shot activation flag is released only once a usable signal
      //    exists (or a bar has rolled over, which takes over the scheduling)
      if(forced && (freshSignal || newBar))
        {
         g_forceFirstTick=false;
         g_act.SetFirstTickDone();
        }
      if(newBar) OnClosedBar();
     }

   //=========================== SECTION C =================================
   UpdateDashboard();
   if(!g_signal.valid || !freshSignal) return;   // never act on a stale/absent signal
   if(g_killFired)     return;

   //--- C1: regime-flip hedge trigger (needs the fresh per-bar signal)
   if(InpEnableHedging && !g_hedge.active && g_book.book_positions>0 && canEnter && !g_haltNewEntries)
     {
      double ddPct=0.0; g_risk.EquityFloorBreached(ddPct);
      string reason=""; double sev=0.0;
      if(g_hedgeMgr.TriggerArmed(g_signal,g_book,ddPct,g_book.total_pnl,reason,sev,true))
        {
         if(g_hedgingAccount)
           {
            if(g_hedgeMgr.Open(g_book,CurrentATR(),sev,reason)) RefreshBookFull();
           }
         else
           {
            double ratio=ClampD(InpHedgeBaseRatio+(InpHedgeMaxRatio-InpHedgeBaseRatio)*sev,0.0,1.0);
            g_hedgeMgr.Deleverage(g_book,ratio,reason);
            RefreshBookFull();
           }
        }
     }

   //--- while a hedge is alive the directional sleeve is frozen:
   //    no new entries and no pyramiding (capital preservation first).
   if(g_hedge.active) return;
   if(!canEnter)      return;                 // heavy decisions only on closed bars
   if(g_haltNewEntries)
     { VerboseT("entries halted by the risk-guard stack",120); return; }
   if(g_entryDay != g_risk.DayStart()) { g_entryDay=g_risk.DayStart(); g_entriesToday=0; }
   if(InpMaxTradesPerDay>0 && g_entriesToday>=InpMaxTradesPerDay)
     { VerboseT(StringFormat("daily entry cap reached (%d/%d)",g_entriesToday,InpMaxTradesPerDay),300); return; }

   int    dir      = g_signal.direction;
   bool   confident= (g_signal.score >= InpConfidenceThreshold);
   bool   idleForce= (InpForceEntryAfterIdleBars>0 && g_idleBars>=InpForceEntryAfterIdleBars);

   if(g_book.book_positions==0)
     {
      if(confident)
         AttemptBaseEntry(dir,false);
      else if(idleForce)
        {
         PrintFormat("QGE IDLE-GUARD: %d closed bars without a position (score %.3f < %.2f) -- forcing entry in direction %+d",
                     g_idleBars,g_signal.score,InpConfidenceThreshold,dir);
         AttemptBaseEntry(dir,true);
        }
      else
         VerboseT(StringFormat("standing by: score %.3f < threshold %.2f (E=%+.4f, idle %d/%d)",
                               g_signal.score,InpConfidenceThreshold,g_signal.evidence,
                               g_idleBars,InpForceEntryAfterIdleBars),30);
     }
   else if(confident)
      AttemptPyramid(dir);
  }

//==================================================================
//  19. OnTimer -- keeps the guard stack and the hedge lifecycle alive
//      even when the quote feed stalls (no entry logic here by design)
//==================================================================
void OnTimer()
  {
   if(!g_warmupReady && !g_act.CheapWarmupOK()) return;
   if(RunLightPass()) RefreshBookCheap();
   UpdateDashboard();
  }

//==================================================================
//  20. OnTester -- composite optimization objective
//      Rewards Profit Factor, Sharpe and Recovery Factor, penalizes
//      relative drawdown, and discounts degenerate (low trade count)
//      samples so the optimizer cannot win by trading once.
//==================================================================
double OnTester()
  {
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double sharpe = TesterStatistics(STAT_SHARPE_RATIO);
   double rf     = TesterStatistics(STAT_RECOVERY_FACTOR);
   double ddRel  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double trades = TesterStatistics(STAT_TRADES);
   double grossL = TesterStatistics(STAT_GROSS_LOSS);

   if(pf==DBL_MAX)     pf=4.0;         // no losing trade => clamp the ratio
   if(sharpe==DBL_MAX) sharpe=0.0;
   if(rf==DBL_MAX)     rf=10.0;
   double obj = 1.00*MathMin(MathMax(pf,0.0),4.0)
              + 1.00*MathMin(MathMax(sharpe,0.0),4.0)
              + 1.50*MathMin(MathMax(rf,0.0),10.0)
              - 0.05*MathMin(MathMax(ddRel,0.0),100.0);
   if(grossL <= 0.0) obj -= 0.5;                     // zero losers => suspicious sample
   if(trades < 30.0) obj *= trades/30.0;             // discount thin samples
   return(obj);
  }
//+------------------------------------------------------------------+
