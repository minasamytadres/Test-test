//+------------------------------------------------------------------+
//|                                              XAUUSD_HFT_Legal.mq5 |
//|   HFT-Legal microstructure liquidity-seeking execution engine     |
//|   MT5 build 5260 target | XAUUSD | IOC | async micro-orders       |
//+------------------------------------------------------------------+
#property strict
#property copyright "HFT-Legal Execution Engine"
#property link      "https://arena.ai"
#property version   "1.00"
#property description "Legal best-execution engine: async IOC micro-bullets, order-book aware"
#property description "midpoint pegging, probabilistic risk-compression hedge, telemetry and"
#property description "anti-manipulation compliance monitor. No spoofing, no layering, no"
#property description "quote stuffing: placement, cancellation and layering rates are measured"
#property description "and throttle the engine when they exceed configured legal thresholds."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==================================================================
//  DESIGN CONTRACT (activation condition -> mechanism -> metric)
//
//  LATENCY SEMANTICS: OrderSendAsync() returns immediately and fills
//  only MqlTradeResult.request_id; the server answer arrives later in
//  OnTradeTransaction() as TRADE_TRANSACTION_REQUEST. ExecutionTime_ms
//  is therefore measured as (transaction arrival - send tick) matched
//  by request id. Documented tester behaviour: OrderSendAsync works
//  like OrderSend inside the Strategy Tester, so latency metrics are
//  only meaningful on a live/demo feed.
//
//  NO NATIVE ICEBERG / PEG ORDER TYPES EXIST IN MQL5. "Iceberg" is
//  implemented as client-side slice sequencing (visible slice only),
//  "midpoint pegging" as a managed non-marketable limit order that is
//  re-priced at most once per InpPegMinRepriceSec and only when the
//  midpoint moved >= InpPegMinMoveTicks. Both are rate limited so the
//  cancellation rate stays below the compliance threshold BY DESIGN.
//
//  OWNERSHIP: every scan filters SYMBOL + MAGIC. Main cluster uses
//  InpMagicMain, the compression hedge uses InpMagicHedge. No account
//  wide action is ever taken.
//==================================================================

//==================================================================
//  0. INPUTS
//==================================================================
input group "0 -- Identity, sizing, activation"
input ulong            InpMagicMain             = 526001;  // Magic: main micro-order cluster
input ulong            InpMagicHedge            = 526002;  // Magic: risk-compression hedge
input double           InpTargetVolume          = 0.30;    // Target volume per entry decision (lots)
input int              InpMicroBullets          = 5;       // Micro-orders per batch N [3..9]
input double           InpMaxTotalLots          = 3.00;    // Hard cap, own positions (lots)
input double           InpMaxDailyVolume        = 20.00;   // Hard cap, own OPENED volume per day (lots)
input int              InpMinSecBetweenBatches  = 1;       // Min seconds between batch decisions
input bool             InpStartupIgnite         = true;    // One-time bootstrap batch when SessionTrades==0
input double           InpBootstrapVolumeFrac   = 0.20;    // Bootstrap volume fraction [0.10..0.30]

input group "1 -- Execution / latency"
input ulong            InpDeviationPoints       = 20;      // Max deviation (points) for IOC requests
input bool             InpRandomizeDeviation    = true;    // Randomize deviation 0..N (legal jitter)
input int              InpMaxJitterMs           = 40;      // Randomized inter-bullet delay (ms), 0 = off
input int              InpLatencyThresholdMs    = 150;     // Latency threshold -> de-escalate aggression
input double           InpP95EscalateFrac       = 1.20;    // P95 > frac x threshold -> escalate passive ratio
input double           InpMinBulletLots         = 0.01;    // Floor per micro-order (lots)
input int              InpOrphanAgeSec          = 6;       // Unanswered in-flight age before counted as orphan
input int              InpPegMaxAgeSec          = 30;      // Max resting age of one peg order (seconds)

input group "2 -- Order book / microstructure scanner"
input bool             InpUseOrderBook          = true;    // Use DOM when available (else tick-flow fallback)
input int              InpBookTopN              = 5;       // Top-N depth levels per side
input double           InpMinTopDepthLots       = 0.50;    // Min combined top-N volume (lots) else THIN
input double           InpImbalanceRef          = 0.35;    // Imbalance normalizer for the score
input int              InpTickVelocityWindow    = 30;      // Tick velocity window (seconds)
input double           InpTickVelocityRef       = 25.0;    // Ticks/second mapped to 100
input int              InpTickRuleWindow        = 40;      // Tick-rule (bid/ask lift) window (ticks)
input int              InpSpreadMomWindow       = 12;      // Spread momentum window (quotes)
input double           InpThinBookRatio         = 0.50;    // depth/minDepth below this -> thin book
input int              InpPegMinRepriceSec      = 3;       // Min seconds between peg re-prices (anti-churn)
input int              InpPegMinMoveTicks       = 2;       // Min midpoint move (ticks) that justifies a re-price

input group "3 -- Aggression balancer"
input double           InpW_LiquidityEdge       = 0.40;    // w3: LiquidityEdgeScore weight
input double           InpW_ExecutionHealth     = 0.30;    // w4: ExecutionHealth weight
input double           InpW_MarginFreePct       = 0.15;    // w1: MarginFreePct weight
input double           InpW_SessionWinRate      = 0.15;    // w2: SessionWinRate weight
input double           InpMaxAggression         = 0.80;    // Max aggression cap [0..1]
input double           InpMinAggression         = 0.20;    // Min aggression floor [0..1]
input double           InpPassiveRatioFloor     = 0.25;    // Minimum passive (peg) share of size
input double           InpMinEdgeToTrade        = 15.0;    // Min LiquidityEdgeScore to trade (no-DOM ceiling 65)

input group "4 -- Adaptive hedge (risk compression)"
input double           InpE_ThresholdUSD        = 25000.0; // E_threshold: toxic net notional (USD)
input double           InpDDvThresholdPerSec    = 60.0;    // Drawdown velocity trigger (USD/sec)
input double           InpDDvAccelFactor        = 1.50;    // DDv acceleration factor trigger
input double           InpHedgeStopATR_H1       = 3.00;    // Hedge catastrophe stop (x ATR H1)
input int              InpHedgeSlicePct         = 10;      // Self-dissolve slice (% of hedge volume)
input double           InpHedgeDecayReleasePct  = 40.0;    // Cluster loss decay (%) that releases slices
input double           InpHedgeMaxAgeMin        = 90.0;    // Anti-lock time stop (minutes)
input bool             InpHedgeUsePassive       = true;    // Hedge prefers passive pegging on thin books

input group "5 -- Telemetry / self-test"
input bool             InpEnableCSV             = true;    // Write CSV telemetry
input string           InpCSVFileName           = "XAUUSD_HFT_Legal_telemetry.csv";
input int              InpTelemetryPeriodSec    = 5;       // CSV + Comment period (seconds)
input int              InpSelfTestMode          = 0;       // 0=off 1=MicroImpulse 2=AdverseShock 3=ThinBook
input bool             InpVerboseLog            = true;    // Verbose mechanism logging

input group "6 -- Safety gates"
input int              InpMaxSpreadPoints       = 80;      // Spread gate (points)
input double           InpCriticalMarginLevel   = 250.0;   // Critical margin level (%) -> DEFENSIVE
input double           InpHealthyMarginLevel    = 900.0;   // Margin level mapped to 1.00
input double           InpDailyLossLimitPct     = 5.0;     // Daily loss guard (% of day-start equity)
input bool             InpRespectRollover       = true;    // Block new entries in the rollover window
input int              InpRolloverStartMin      = 1435;    // Rollover start (server minutes, 23:55)
input int              InpRolloverEndMin        = 65;      // Rollover end (server minutes, 01:05)

input group "7 -- Legal compliance monitor"
input double           InpMaxCancellationRate   = 0.80;    // Max cancellations / placements ratio
input int              InpComplianceWindowSec   = 60;      // Rolling compliance window (seconds)
input int              InpMinComplianceSamples  = 12;      // Min placements in window before judging
input int              InpMaxOwnLayersPerSide   = 1;       // Max resting own orders per side (anti-layering)
input double           InpMaxOrphanRate         = 0.10;    // Max orphaned requests / placements
input int              InpMaxComplianceStrikes  = 3;       // Strikes before hard shutdown
input bool             InpShutdownOnFlag        = true;    // Hard shutdown (cancel all + stop) on strikes
input int              InpThrottleFactorPct     = 50;      // Throttle: keep this % of target volume

input group "8 -- Risk protection (0 = disabled; XAUUSD 1 point = 0.01 price)"
input double           InpStopLossPoints        = 0.0;     // SL distance from entry (points) attached per order
input double           InpTakeProfitPoints      = 0.0;     // TP distance from entry (points) attached per order
input double           InpMaxMarginUsePct       = 20.0;    // Max position margin as % of equity (capacity brake)
input double           InpMaxRiskPerEntryPct    = 0.0;     // Max equity risk per entry vs the SL (needs SL > 0)

//==================================================================
//  1. ENUMS / SMALL STRUCTS
//==================================================================
enum ENUM_AGGR_MODE
  {
   AGGR_DEFENSIVE = 0,   // score < 40  : no new entries, unwind focus
   AGGR_NORMAL    = 1,   // 40 .. 59    : mixed passive / active
   AGGR_HIGH      = 2,   // 60 .. 84    : micro-bullets + partial passive
   AGGR_MAX       = 3    // >= 85       : micro-bullets + active sniping
  };

//--- one in-flight asynchronous request (matched by request id)
struct SInFlight
  {
   ulong             id;          // MqlTradeRequest.id echoed by the server
   bool              used;        // slot occupied
   bool              answered;    // TRADE_TRANSACTION_REQUEST received
   bool              hedge;       // belongs to the compression hedge
   bool              peg;         // passive limit (peg) request
   int               side;        // +1 buy, -1 sell
   ulong             send_ms;     // GetTickCount64() at OrderSendAsync()
   ulong             done_ms;     // GetTickCount64() at server answer
   double            req_volume;  // requested volume (lots)
   double            req_price;   // requested price (peg adoption key)
   double            filled;      // executed volume observed via DEAL_ADD
   ENUM_ORDER_TYPE   otype;       // request order type
   datetime          sent_time;   // server time at send (auditing)
   void              Clear()
     {
      id=0; used=false; answered=false; hedge=false; peg=false; side=0;
      send_ms=0; done_ms=0; req_volume=0.0; req_price=0.0; filled=0.0;
      otype=ORDER_TYPE_BUY; sent_time=0;
     }
  };

//--- one managed passive peg (midpoint-pegged limit) order
struct SPeg
  {
   ulong             ticket;      // 0 = empty, 1 = provisional (awaiting ORDER_ADD)
   int               side;        // +1 buy limit, -1 sell limit
   bool              hedge;       // belongs to the compression hedge sleeve
   double            price;       // current resting price
   double            volume;      // resting volume (lots)
   datetime          placed;      // server time of placement
   ulong             last_reprice_ms; // wall clock of the last re-price
   void              Clear()
     {
      ticket=0; side=0; hedge=false; price=0.0; volume=0.0; placed=0; last_reprice_ms=0;
     }
  };

//==================================================================
//  2. GLOBAL STATE (value instances: no heap allocation, no pointers
//     to user objects, therefore no delete/leak surface at all)
//==================================================================
int      g_digits        = 2;
double   g_point         = 0.01;
double   g_tickSize      = 0.01;
double   g_volMin        = 0.01;
double   g_volMax        = 100.0;
double   g_volStep       = 0.01;
long     g_stopsLevel    = 0;
long     g_freezeLevel   = 0;
double   g_slPoints      = 0.0;    // validated copy of InpStopLossPoints (0 = no stop attached)
double   g_tpPoints      = 0.0;    // validated copy of InpTakeProfitPoints
double   g_contractSize  = 100.0;  // SYMBOL_TRADE_CONTRACT_SIZE (XAUUSD: 100 oz per 1.00 lot)
uint     g_fillFlags     = 0;
ENUM_ORDER_TYPE_FILLING g_fillPolicy = ORDER_FILLING_IOC;
int      g_hATR_H1       = INVALID_HANDLE;
int      g_hATR_D1       = INVALID_HANDLE;
ulong    g_requestSeq    = 0;      // unique client request id source
datetime g_lastDecision  = 0;      // batch decision throttle
datetime g_lastDayKey    = 0;      // day anchor for the daily guards
double   g_dayStartEquity= 0.0;    // equity at server day start
double   g_dayVolume     = 0.0;    // own filled volume today (lots)
bool     g_igniteUsed    = false;  // StartupIgnite consumed
bool     g_ready         = false;  // init completed successfully
int      g_lastCommentSec= -1;     // Comment() throttle
string   g_lastGateReason= "";     // why the last entry attempt was blocked (chart + log)

//==================================================================
//  3. MATH / NORMALIZATION PRIMITIVES
//==================================================================
double ClampD(const double v, const double lo, const double hi)
  {
   if(v < lo) return(lo);
   if(v > hi) return(hi);
   return(v);
  }
double SafeDiv(const double a, const double b, const double fallback)
  {
   if(MathAbs(b) < 1.0e-12) return(fallback);
   return(a/b);
  }
bool IsFiniteD(const double v) { return(MathIsValidNumber(v)); }

//--- decimal places implied by the broker volume step
int VolumeDigits()
  {
   double s = g_volStep;
   if(s <= 0.0) return(2);
   int d = 0;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1.0e-10) { s *= 10.0; d++; }
   return(d);
  }

//--- volume: floor to VOLUME_STEP, reject below VOLUME_MIN, cap to VOLUME_MAX
double NormVolume(const double raw, bool &ok)
  {
   ok = false;
   if(!IsFiniteD(raw) || raw <= 0.0) return(0.0);
   double v = raw;
   if(g_volStep > 0.0)
      v = MathFloor(v/g_volStep + 1.0e-8)*g_volStep;
   v = NormalizeDouble(v, VolumeDigits());
   if(v < g_volMin - 1.0e-9) return(0.0);          // reject, never bump
   if(v > g_volMax)
     {
      v = MathFloor(g_volMax/g_volStep + 1.0e-8)*g_volStep;
      v = NormalizeDouble(v, VolumeDigits());
      if(v < g_volMin - 1.0e-9) return(0.0);
     }
   ok = true;
   return(v);
  }

//--- price: tick-size alignment THEN _Digits normalization (two concerns)
double NormPrice(const double p)
  {
   if(!IsFiniteD(p) || p <= 0.0) return(0.0);
   double a = p;
   if(g_tickSize > 0.0) a = MathRound(p/g_tickSize)*g_tickSize;
   return(NormalizeDouble(a, g_digits));
  }

//--- minimum legal distance from market for a resting limit order
double StopsDistance()
  {
   double pts = (double)g_stopsLevel + 1.0;
   return(NormPrice(pts*g_point));
  }

//--- ATR scalar with full handle / buffer validation
double AtrValue(const int handle)
  {
   if(handle == INVALID_HANDLE) return(0.0);
   if(BarsCalculated(handle) <= 0) return(0.0);
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 1, 1, buf) != 1) return(0.0);
   if(!IsFiniteD(buf[0]) || buf[0] <= 0.0) return(0.0);
   return(buf[0]);
  }

//==================================================================
//  4. FORWARD DECLARATIONS (value globals, referenced by the classes)
//==================================================================
class C_Telemetry;
class C_OrderBookScanner;
class C_HFTExecution;
class C_SafetyManager;
class C_AggressionBalancer;
class C_AdaptiveHedge;

C_Telemetry          g_telem;
C_OrderBookScanner   g_scan;
C_HFTExecution       g_exec;
C_SafetyManager      g_safe;
C_AggressionBalancer g_bal;
C_AdaptiveHedge      g_hedge;

//==================================================================
//  5. C_Telemetry -- metrics, latency percentiles, CSV, compliance
//     activation: every execution / transaction event
//     mechanism : rolling windows + fixed-size rings (no heap growth)
//     metric    : MicroFillRate, IOC_FillRatio, Avg/P95 latency,
//                 HedgeEfficiency, CancellationRate, LegalComplianceFlag
//==================================================================
#define TEL_MAX_LATENCY   512
#define TEL_MAX_REQWINDOW 256
#define TEL_MAX_DEALS     512

class C_Telemetry
  {
private:
   int               m_file;                 // CSV handle (INVALID_HANDLE = closed)
   datetime          m_lastRow;              // CSV row throttle

   double            m_lat[TEL_MAX_LATENCY]; // request->answer latency ring (ms)
   int               m_latN;
   int               m_latIdx;

   ulong             m_reqT[TEL_MAX_REQWINDOW]; // placement timestamps (seconds)
   ulong             m_canT[TEL_MAX_REQWINDOW]; // cancellation timestamps (seconds)
   int               m_reqN;
   int               m_reqIdx;
   int               m_canN;
   int               m_canIdx;

   ulong             m_sentOrders;           // accepted async requests
   ulong             m_rejectedRequests;     // requests refused by the server
   ulong             m_iocResponses;         // IOC/market answers received
   ulong             m_iocFilled;            // IOC answers with volume > 0
   ulong             m_pegResponses;         // passive peg answers received
   ulong             m_pegFilled;            // passive peg answers that rested/filled
   ulong             m_cancellations;        // own orders deleted (total)
   ulong             m_orphans;              // unanswered / expired own requests
   ulong             m_strikeCount;          // compliance strikes (session)
   double            m_reqVolume;            // requested lots (cumulative)
   double            m_fillVolume;           // executed lots (cumulative)
   double            m_hedgeReqVolume;       // hedge requested lots
   double            m_hedgeFillVolume;      // hedge executed lots

   double            m_dealT[TEL_MAX_DEALS]; // own out-deal timestamps (today)
   double            m_dealP[TEL_MAX_DEALS]; // own out-deal net P&L
   int               m_dealN;
   datetime          m_dealScan;             // win-rate cache anchor
   double            m_winRate;              // cached session win rate [0..1]

   datetime          m_ddStart;              // drawdown episode start
   double            m_ddPeakLoss;           // deepest loss of the episode (USD)
   double            m_lastRecoverySec;      // last measured recovery time (sec)

   bool              m_flag;                 // LegalComplianceFlag (latched)
   string            m_flagReason;
   datetime          m_flagTime;
   bool              m_throttled;            // auto-throttle active
   bool              m_shutdown;             // hard shutdown active

   void              ResetFileHandle(int &h) { if(h != INVALID_HANDLE) { FileClose(h); h = INVALID_HANDLE; } }

   int               CountInWindow(const ulong &ring[], const int n,
                                   const ulong nowSec, const ulong windowSec) const
     {
      int c = 0;
      for(int i=0;i<n;i++)
        {
         ulong t = ring[i];
         if(t > 0 && (nowSec - t) <= windowSec) c++;
        }
      return(c);
     }

   void              PushRing(ulong &ring[], int &n, int &idx, const ulong value)
     {
      ring[idx] = value;
      idx = (idx + 1) % TEL_MAX_REQWINDOW;
      if(n < TEL_MAX_REQWINDOW) n++;
     }

public:
                     C_Telemetry()
     {
      m_file=INVALID_HANDLE; m_lastRow=0;
      m_latN=0; m_latIdx=0;
      m_reqN=0; m_reqIdx=0; m_canN=0; m_canIdx=0;
      m_sentOrders=0; m_rejectedRequests=0; m_iocResponses=0; m_iocFilled=0;
      m_pegResponses=0; m_pegFilled=0; m_cancellations=0; m_orphans=0; m_strikeCount=0;
      m_reqVolume=0.0; m_fillVolume=0.0; m_hedgeReqVolume=0.0; m_hedgeFillVolume=0.0;
      m_dealN=0; m_dealScan=0; m_winRate=0.5;
      m_ddStart=0; m_ddPeakLoss=0.0; m_lastRecoverySec=0.0;
      m_flag=false; m_flagReason=""; m_flagTime=0; m_throttled=false; m_shutdown=false;
      ArrayInitialize(m_lat,0.0);
      ArrayInitialize(m_reqT,0);
      ArrayInitialize(m_canT,0);
      ArrayInitialize(m_dealT,0.0);
      ArrayInitialize(m_dealP,0.0);
     }

   //--- CSV lifecycle
   bool              OpenLog(const string fname)
     {
      if(!InpEnableCSV) return(true);
      ResetFileHandle(m_file);
      m_file = FileOpen(fname, FILE_WRITE|FILE_CSV|FILE_SHARE_READ, ',');
      if(m_file == INVALID_HANDLE)
        {
         PrintFormat("TELEM WARNING: FileOpen(%s) failed err=%d -> CSV disabled, engine continues",
                     fname, _LastError);
         return(false);
        }
      FileWrite(m_file,"Timestamp","Symbol","ExecutionSpeed_ms","MicroFillRate",
                "HedgeEfficiency","Drawdown_Recovery_Time","CancellationRate","LegalComplianceFlag");
      return(true);
     }
   void              CloseLog()
     {
      if(m_file != INVALID_HANDLE) { FileFlush(m_file); FileClose(m_file); m_file = INVALID_HANDLE; }
     }

   //--- latency ring
   void              AddLatencyMs(const double ms)
     {
      if(!IsFiniteD(ms) || ms < 0.0) return;
      m_lat[m_latIdx] = ms;
      m_latIdx = (m_latIdx + 1) % TEL_MAX_LATENCY;
      if(m_latN < TEL_MAX_LATENCY) m_latN++;
     }
   double            AvgLatency() const
     {
      if(m_latN <= 0) return(0.0);
      double s=0.0;
      for(int i=0;i<m_latN;i++) s += m_lat[i];
      return(s/(double)m_latN);
     }
   double            P95Latency()
     {
      if(m_latN <= 0) return(0.0);
      double tmp[];
      if(ArrayResize(tmp, m_latN) != m_latN) return(0.0);
      for(int i=0;i<m_latN;i++) tmp[i] = m_lat[i];
      ArraySort(tmp);                                   // ascending insertion sort
      int idx = (int)MathFloor(0.95*(double)(m_latN-1) + 0.5);
      idx = (int)ClampD((double)idx, 0.0, (double)(m_latN-1));
      return(tmp[idx]);
     }

   //--- request / cancellation windows (compliance denominators)
   //--- test-only: clears the rolling compliance windows so a synthetic
   //    scenario can be verified deterministically (never called live)
   void              ResetCounters()
     {
      ArrayInitialize(m_reqT,0); ArrayInitialize(m_canT,0);
      m_reqN=0; m_reqIdx=0; m_canN=0; m_canIdx=0;
      m_sentOrders=0; m_cancellations=0; m_orphans=0; m_rejectedRequests=0;
      m_iocResponses=0; m_iocFilled=0; m_pegResponses=0; m_pegFilled=0;
      m_reqVolume=0.0; m_fillVolume=0.0; m_hedgeReqVolume=0.0; m_hedgeFillVolume=0.0;
      m_latN=0; m_latIdx=0; ArrayInitialize(m_lat,0.0);
     }
   void              NotePlacement()
     {
      m_sentOrders++;
      PushRing(m_reqT, m_reqN, m_reqIdx, (ulong)TimeCurrent());
     }
   void              NoteCancellation()
     {
      m_cancellations++;
      PushRing(m_canT, m_canN, m_canIdx, (ulong)TimeCurrent());
     }
   void              NoteOrphan()      { m_orphans++;            }
   void              NoteRejection()   { m_rejectedRequests++;   }
   void              NoteVolume(const double req, const double fill, const bool hedge)
     {
      if(IsFiniteD(req))  m_reqVolume  += MathMax(req,0.0);
      if(IsFiniteD(fill)) m_fillVolume += MathMax(fill,0.0);
      if(hedge)
        {
         if(IsFiniteD(req))  m_hedgeReqVolume  += MathMax(req,0.0);
         if(IsFiniteD(fill)) m_hedgeFillVolume += MathMax(fill,0.0);
        }
     }
   void              NoteIOC(const bool filled)
     {
      m_iocResponses++;
      if(filled) m_iocFilled++;
     }
   void              NotePeg(const bool filled)
     {
      m_pegResponses++;
      if(filled) m_pegFilled++;
     }

   //--- derived metrics
   double            MicroFillRate() const { return(ClampD(SafeDiv(m_fillVolume,m_reqVolume,0.0),0.0,1.0)); }
   double            IOCFillRatio()  const { return(ClampD(SafeDiv((double)m_iocFilled,(double)m_iocResponses,0.0),0.0,1.0)); }
   double            CancellationRate()
     {
      ulong nowSec = (ulong)TimeCurrent();
      ulong win    = (ulong)MathMax(InpComplianceWindowSec,1);
      int p = CountInWindow(m_reqT, m_reqN, nowSec, win);
      int c = CountInWindow(m_canT, m_canN, nowSec, win);
      if(p <= 0) return(0.0);
      return(ClampD((double)c/(double)p, 0.0, 10.0));
     }
   double            OrphanRate()    const { return(ClampD(SafeDiv((double)m_orphans,(double)m_sentOrders,0.0),0.0,1.0)); }
   double            HedgeEfficiency() const
     {
      //--- executed hedge volume per unit of requested hedge volume
      return(ClampD(SafeDiv(m_hedgeFillVolume,m_hedgeReqVolume,0.0),0.0,1.0));
     }
   double            ExecutionHealth()
     {
      //--- activation: every aggression evaluation
      //--- mechanism: latency vs threshold, fill quality, rejection rate
      //--- metric   : ExecutionHealth in [0,100]
      if(m_sentOrders == 0) return(50.0);            // no evidence yet: neutral
      double thr  = (double)MathMax(InpLatencyThresholdMs,1);
      double avgN = ClampD(SafeDiv(AvgLatency(),thr,1.0), 0.0, 2.0);
      double p95N = ClampD(SafeDiv(P95Latency(),thr,1.0), 0.0, 2.0);
      double latH = ClampD(1.0 - (0.60*avgN + 0.40*p95N), 0.0, 1.0);
      double fillH= ClampD(0.5*MicroFillRate() + 0.5*IOCFillRatio(), 0.0, 1.0);
      double rejH = ClampD(1.0 - SafeDiv((double)m_rejectedRequests,(double)m_sentOrders,0.0), 0.0, 1.0);
      return(ClampD((0.40*latH + 0.40*fillH + 0.20*rejH)*100.0, 0.0, 100.0));
     }

   //--- session win rate from own closed deals (history, magic+symbol scoped)
   double            SessionWinRate()
     {
      datetime now = TimeCurrent();
      if(m_dealScan != 0 && (int)(now - m_dealScan) < 5) return(m_winRate);
      m_dealScan = now;
      if(g_lastDayKey == 0) return(m_winRate);
      if(!HistorySelect(g_lastDayKey, now + 120)) return(m_winRate);
      m_dealN = 0;
      int deals = HistoryDealsTotal();
      for(int i=0;i<deals && m_dealN<TEL_MAX_DEALS;i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0) continue;
         if(HistoryDealGetInteger(dt,DEAL_MAGIC) != (long)InpMagicMain) continue;
         if(HistoryDealGetString(dt,DEAL_SYMBOL) != _Symbol)            continue;
         long ent = HistoryDealGetInteger(dt,DEAL_ENTRY);
         if(ent != DEAL_ENTRY_OUT && ent != DEAL_ENTRY_INOUT && ent != DEAL_ENTRY_OUT_BY) continue;
         double net = HistoryDealGetDouble(dt,DEAL_PROFIT)
                    + HistoryDealGetDouble(dt,DEAL_SWAP)
                    + HistoryDealGetDouble(dt,DEAL_COMMISSION)
                    + HistoryDealGetDouble(dt,DEAL_FEE);
         m_dealT[m_dealN] = (double)(long)HistoryDealGetInteger(dt,DEAL_TIME);
         m_dealP[m_dealN] = net;
         m_dealN++;
        }
      if(m_dealN == 0) { m_winRate = 0.5; return(m_winRate); }   // no sample: neutral
      int wins = 0;
      for(int i=0;i<m_dealN;i++) if(m_dealP[i] > 0.0) wins++;
      m_winRate = ClampD((double)wins/(double)m_dealN, 0.0, 1.0);
      return(m_winRate);
     }

   //--- drawdown episode tracking -> Drawdown_Recovery_Time
   void              UpdateDrawdownRecovery(const double floatingPnL)
     {
      if(floatingPnL < 0.0)
        {
         if(m_ddStart == 0) m_ddStart = TimeCurrent();
         if(-floatingPnL > m_ddPeakLoss) m_ddPeakLoss = -floatingPnL;
         return;
        }
      if(m_ddStart != 0 && m_ddPeakLoss > 0.0)
        {
         m_lastRecoverySec = (double)(TimeCurrent() - m_ddStart);
         PrintFormat("TELEM: drawdown recovered in %.0f s (peak loss %.2f)",
                     m_lastRecoverySec, m_ddPeakLoss);
         m_ddStart=0; m_ddPeakLoss=0.0;
        }
     }
   double            LastDealTime()    const { return(m_dealN>0 ? m_dealT[m_dealN-1] : 0.0); }
   int               DealSamples()     const { return(m_dealN); }

   //--- LegalComplianceFlag: latch, audit log, throttle/shutdown escalation
   void              RaiseFlag(const string reason)
     {
      m_strikeCount++;
      if(!m_flag)
        {
         m_flag=true; m_flagReason=reason; m_flagTime=TimeCurrent();
        }
      else
         m_flagReason = reason;
      PrintFormat("AUDIT LEGAL-COMPLIANCE FLAG #%I64u at %s : %s | cancelRate=%.2f orphanRate=%.2f",
                  m_strikeCount, TimeToString(m_flagTime,TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                  reason, CancellationRate(), OrphanRate());
      if(InpShutdownOnFlag && m_strikeCount >= (ulong)MathMax(InpMaxComplianceStrikes,1))
        {
         m_shutdown = true;
         Print("AUDIT: strike limit reached -> HARD SHUTDOWN (cancel own pegs, no new placement)");
        }
      else
        {
         m_throttled = true;
         PrintFormat("AUDIT: auto-throttle engaged -> target volume reduced to %d%%",
                     (int)ClampD((double)InpThrottleFactorPct,0.0,100.0));
        }
     }
   void              ClearTransientFlag()
     {
      //--- the flag itself stays latched for the audit trail; only the
      //    throttle is released once the measured rate is back in range
      if(m_throttled && !m_shutdown) m_throttled = false;
     }
   bool              Flag()      const { return(m_flag);      }
   bool              Throttled() const { return(m_throttled); }
   bool              Shutdown()  const { return(m_shutdown);  }
   void              ReleaseShutdown() { m_shutdown=false; m_throttled=false; m_strikeCount=0; m_flag=false; m_flagReason="released"; }
   string            FlagReason()const { return(m_flagReason);}
   ulong             Strikes()   const { return(m_strikeCount);}
   ulong             SentOrders()const { return(m_sentOrders);}

   //--- CSV row + chart overlay
   void              LogPeriodic()
     {
      datetime now = TimeCurrent();
      if(m_lastRow != 0 && (int)(now - m_lastRow) < MathMax(InpTelemetryPeriodSec,1)) return;
      m_lastRow = now;
      if(m_file != INVALID_HANDLE)
        {
         FileWrite(m_file,
                   TimeToString(now,TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                   _Symbol,
                   DoubleToString(AvgLatency(),2),
                   DoubleToString(MicroFillRate(),4),
                   DoubleToString(HedgeEfficiency(),4),
                   DoubleToString(m_lastRecoverySec,1),
                   DoubleToString(CancellationRate(),4),
                   m_flag ? ("FLAG:"+m_flagReason) : "OK");
         FileFlush(m_file);
        }
     }
   string            SummaryLine()
     {
      return(StringFormat("fill=%.1f%% ioc=%.1f%% avg=%.0fms p95=%.0fms cancel=%.2f orphan=%.2f%% hedgeEff=%.1f%% flag=%s%s",
                          MicroFillRate()*100.0, IOCFillRatio()*100.0, AvgLatency(), P95Latency(),
                          CancellationRate(), OrphanRate()*100.0, HedgeEfficiency()*100.0,
                          m_flag ? "RAISED" : "clear",
                          m_shutdown ? " [SHUTDOWN]" : (m_throttled ? " [THROTTLED]" : "")));
     }
  };

//==================================================================
//  6. C_OrderBookScanner -- legal microstructure signal engine
//     activation: OnBookEvent / OnTick / OnTimer
//     mechanism : DOM imbalance + top-N depth + tick velocity + spread
//                 momentum; FALLBACK to tick-flow when DOM is unusable
//     metric    : LiquidityEdgeScore in [0,100], BookDir in {-1,0,+1}
//==================================================================
#define SCAN_MAX_TICKS  512

class C_OrderBookScanner
  {
private:
   bool              m_subscribed;
   bool              m_bookValid;
   datetime          m_bookTime;
   MqlBookInfo       m_book[];

   double            m_imbalance;       // (bidVol-askVol)/(bidVol+askVol) top-N
   double            m_topBidVol;
   double            m_topAskVol;
   int               m_levels;
   bool              m_thin;
   double            m_depthRatio;      // topDepth / InpMinTopDepthLots

   datetime          m_tickT[SCAN_MAX_TICKS];
   double            m_tickP[SCAN_MAX_TICKS];
   int               m_tickFlags[SCAN_MAX_TICKS];
   int               m_tickN;
   int               m_tickIdx;
   double            m_tickVelocity;    // ticks per second in the window
   double            m_tickRule;        // net lift in [-1,1]

   double            m_sprT[SCAN_MAX_TICKS];
   int               m_sprN;
   int               m_sprIdx;
   double            m_spreadMom;       // normalized spread slope

   double            m_edge;            // LiquidityEdgeScore [0,100]
   int               m_dir;             // BookDir

   void              PushTick(const datetime t, const double p, const int flags)
     {
      m_tickT[m_tickIdx]     = t;
      m_tickP[m_tickIdx]     = p;
      m_tickFlags[m_tickIdx] = flags;
      m_tickIdx = (m_tickIdx + 1) % SCAN_MAX_TICKS;
      if(m_tickN < SCAN_MAX_TICKS) m_tickN++;
     }
   void              PushSpread(const double s)
     {
      m_sprT[m_sprIdx]    = s;
      m_sprIdx = (m_sprIdx + 1) % SCAN_MAX_TICKS;
      if(m_sprN < SCAN_MAX_TICKS) m_sprN++;
     }

public:
                     C_OrderBookScanner()
     {
      m_subscribed=false; m_bookValid=false; m_bookTime=0;
      m_imbalance=0.0; m_topBidVol=0.0; m_topAskVol=0.0; m_levels=0;
      m_thin=true; m_depthRatio=0.0;
      m_tickN=0; m_tickIdx=0; m_tickVelocity=0.0; m_tickRule=0.0;
      m_sprN=0; m_sprIdx=0; m_spreadMom=0.0;
      m_edge=0.0; m_dir=0;
      ArrayInitialize(m_tickT,0); ArrayInitialize(m_tickP,0.0); ArrayInitialize(m_tickFlags,0);
      ArrayInitialize(m_sprT,0.0);
     }

   bool              Subscribe()
     {
      if(!InpUseOrderBook) { m_subscribed=false; return(false); }
      m_subscribed = MarketBookAdd(_Symbol);
      if(!m_subscribed)
         PrintFormat("SCAN: MarketBookAdd(%s) unavailable err=%d -> tick-flow fallback active",
                     _Symbol, _LastError);
      return(m_subscribed);
     }
   void              Unsubscribe()
     {
      if(m_subscribed) { MarketBookRelease(_Symbol); m_subscribed=false; }
      m_bookValid=false;
     }

   void              OnBook(const string &symbol)
     {
      if(symbol != _Symbol) return;
      MqlBookInfo tmp[];
      if(!MarketBookGet(_Symbol, tmp)) { m_bookValid=false; return; }
      int n = ArraySize(tmp);
      if(n <= 0) { m_bookValid=false; return; }
      if(ArrayResize(m_book, n) != n) { m_bookValid=false; return; }
      for(int i=0;i<n;i++) m_book[i] = tmp[i];
      m_bookValid = true;
      m_bookTime  = TimeCurrent();
      RecomputeBook();
     }

   void              RecomputeBook()
     {
      m_topBidVol=0.0; m_topAskVol=0.0; m_levels=0;
      int n = ArraySize(m_book);
      for(int i=0;i<n && m_levels<InpBookTopN*2;i++)
        {
         ENUM_BOOK_TYPE t = m_book[i].type;
         if(t == BOOK_TYPE_BUY || t == BOOK_TYPE_BUY_MARKET)
           {
            m_topBidVol += (double)m_book[i].volume;
            m_levels++;
           }
         else if(t == BOOK_TYPE_SELL || t == BOOK_TYPE_SELL_MARKET)
           {
            m_topAskVol += (double)m_book[i].volume;
            m_levels++;
           }
        }
      double tot = m_topBidVol + m_topAskVol;
      m_imbalance = (tot > 1.0e-9) ? ClampD((m_topBidVol - m_topAskVol)/tot, -1.0, 1.0) : 0.0;
      double minDepth = MathMax(InpMinTopDepthLots, g_volMin);
      double topDepth = MathMin(m_topBidVol, m_topAskVol);
      m_depthRatio = SafeDiv(topDepth, minDepth, 0.0);
      m_thin = (m_levels < 2) || (m_depthRatio < InpThinBookRatio);
     }

   //--- per-quote update: velocity, tick rule, spread momentum
   void              OnQuote(const MqlTick &tick)
     {
      if(tick.bid <= 0.0 || tick.ask <= 0.0) return;
      PushTick(tick.time, tick.bid, (int)tick.flags);
      PushSpread(tick.ask - tick.bid);
      ComputeVelocity();
      ComputeTickRule();
      ComputeSpreadMom();
     }

   void              ComputeVelocity()
     {
      if(m_tickN < 2) { m_tickVelocity=0.0; return; }
      datetime newest=0;
      int cnt=0;
      for(int i=0;i<m_tickN;i++)
        {
         datetime t = m_tickT[i];
         if(t == 0) continue;
         if(newest == 0 || t > newest) newest = t;
         cnt++;
        }
      if(newest == 0 || cnt < 2) { m_tickVelocity=0.0; return; }
      int win = MathMax(InpTickVelocityWindow,1);
      datetime cut = newest - (datetime)win;
      int inWin=0;
      for(int i=0;i<m_tickN;i++) if(m_tickT[i] != 0 && m_tickT[i] > cut) inWin++;
      double secs = (double)(newest - cut);
      m_tickVelocity = (secs > 0.0) ? ClampD((double)inWin/secs, 0.0, 100000.0) : 0.0;
     }

   void              ComputeTickRule()
     {
      int n = MathMin(m_tickN, MathMax(InpTickRuleWindow,2));
      if(n < 2) { m_tickRule=0.0; return; }
      //--- walk the ring backwards from the newest element
      int up=0, dn=0, idx = (m_tickIdx - 1 + SCAN_MAX_TICKS) % SCAN_MAX_TICKS;
      double prev = m_tickP[idx];
      for(int k=1;k<n;k++)
        {
         int j = (idx - k + SCAN_MAX_TICKS) % SCAN_MAX_TICKS;
         double p = m_tickP[j];
         if(p <= 0.0) continue;
         if(prev > p)      up++;         // newer price above older => lift
         else if(prev < p) dn++;
         prev = p;
        }
      int tot = up + dn;
      m_tickRule = (tot > 0) ? ClampD((double)(up - dn)/(double)tot, -1.0, 1.0) : 0.0;
     }

   void              ComputeSpreadMom()
     {
      int n = MathMin(m_sprN, MathMax(InpSpreadMomWindow,3));
      if(n < 3) { m_spreadMom=0.0; return; }
      //--- least squares slope of the last n spread samples on index x
      double sx=0.0, sy=0.0, sxy=0.0, sxx=0.0;
      int idx = (m_sprIdx - 1 + SCAN_MAX_TICKS) % SCAN_MAX_TICKS;
      for(int k=0;k<n;k++)
        {
         int j = (idx - k + SCAN_MAX_TICKS) % SCAN_MAX_TICKS;
         double x = (double)(n-1-k);                 // oldest -> newest
         double y = m_sprT[j];
         sx += x; sy += y; sxy += x*y; sxx += x*x;
        }
      double den = (double)n*sxx - sx*sx;
      if(MathAbs(den) < 1.0e-12) { m_spreadMom=0.0; return; }
      double slope = ((double)n*sxy - sx*sy)/den;    // price units per sample
      double mean  = SafeDiv(sy,(double)n,0.0);
      m_spreadMom  = ClampD(SafeDiv(slope, MathMax(mean,1.0e-9), 0.0), -1.0, 1.0);
     }

   //--- DOM usable? (subscribed, fresh, enough levels)
   bool              BookUsable() const
     {
      if(!m_subscribed || !m_bookValid) return(false);
      return(m_levels >= 2);
     }

   //--- injectable edge computation (pure => deterministically testable)
   double            EdgeFromInputs(const double imbalance, const double depthRatio,
                                    const double tickVelocity, const double tickRule,
                                    const double spreadMom, const bool bookUsable,
                                    int &dirOut) const
     {
      //--- activation: every scan refresh
      //--- mechanism : weighted evidence fusion, sign-consistency requirement
      //--- metric    : LiquidityEdgeScore [0,100], dirOut in {-1,0,+1}
      double imbN = ClampD(SafeDiv(MathAbs(imbalance), MathMax(InpImbalanceRef,1.0e-6), 0.0), 0.0, 1.0);
      double depN = ClampD(depthRatio, 0.0, 1.0);
      double velN = ClampD(SafeDiv(tickVelocity, MathMax(InpTickVelocityRef,1.0e-6), 0.0), 0.0, 1.0);
      double ruleN= ClampD(MathAbs(tickRule), 0.0, 1.0);
      double sprN = ClampD(1.0 - MathAbs(spreadMom), 0.0, 1.0);   // widening spread = worse
      //--- evidence-weighted renormalization: depth has NO meaning without a
      //    DOM, so its weight is redistributed over the components that do
      //    carry evidence. Scoring a missing DOM as "zero depth" would cap
      //    the edge at 52/100 and make entries mathematically impossible on
      //    brokers that do not publish a book -- i.e. the engine would sit
      //    idle forever. With a DOM the weights sum to 1.00 and the value is
      //    unchanged (0.35+0.20+0.15+0.20+0.10).
      double wImb, wDep, wVel, wRule, wSpr;
      if(bookUsable)                                      // full DOM evidence
        {
         wImb=0.35; wDep=0.20; wVel=0.15; wRule=0.20; wSpr=0.10;
        }
      else                                                // tick-flow fallback: no depth evidence
        {
         wImb=0.00; wDep=0.00; wVel=0.35; wRule=0.40; wSpr=0.25;
        }
      double wSum  = wImb + wDep + wVel + wRule + wSpr;   // = 1.00 in both schemes
      double raw   = (wImb*imbN + wDep*depN + wVel*velN + wRule*ruleN + wSpr*sprN)/MathMax(wSum,1.0e-9);
      double conf  = bookUsable ? 1.00 : 0.65;            // DOM evidence is worth more than ticks
      double score = conf * raw * 100.0;

      int dImb  = (imbalance >  1.0e-9) ?  1 : ((imbalance < -1.0e-9) ? -1 : 0);
      int dRule = (tickRule    >  1.0e-9) ?  1 : ((tickRule    < -1.0e-9) ? -1 : 0);
      int dir   = 0;
      if(bookUsable)
        {
         if(dImb != 0 && (dRule == 0 || dRule == dImb)) dir = dImb;   // DOM leads, ticks confirm
         else if(dRule != 0)                            dir = dRule;
        }
      else
         dir = dRule;                                                  // tick-flow fallback
      if(MathAbs(spreadMom) > 0.60) dir = 0;                           // spread blowing out: stand down
      dirOut = dir;
      if(dir == 0) score *= 0.40;                                      // no direction: heavily discounted
      return(ClampD(score, 0.0, 100.0));
     }

   //--- injectable passive-preference decision (pure => testable)
   bool              PreferPassiveFromInputs(const bool bookUsable, const double depthRatio,
                                             const double spreadMom) const
     {
      if(!bookUsable)                    return(true);   // no DOM evidence -> passive
      if(depthRatio < InpThinBookRatio)  return(true);   // thin book -> passive
      if(spreadMom > 0.50)               return(true);   // spread widening -> passive
      return(false);
     }

   void              Refresh()
     {
      bool usable = BookUsable();
      if(usable && m_bookTime != 0 && (int)(TimeCurrent() - m_bookTime) > 5)
         usable = false;                                  // stale DOM: fall back
      int dir = 0;
      m_edge = EdgeFromInputs(m_imbalance, m_depthRatio, m_tickVelocity, m_tickRule,
                              m_spreadMom, usable, dir);
      m_dir  = dir;
     }

   //--- test injection hooks (used by SelfTest only, never by live flow)
   void              InjectTickFlow(const double velocity, const double rule, const double spreadMom)
     {
      m_tickVelocity=velocity; m_tickRule=rule; m_spreadMom=spreadMom;
     }
   void              InjectBook(const double imbalance, const double depthRatio, const bool valid)
     {
      m_imbalance=imbalance; m_depthRatio=depthRatio; m_bookValid=valid; m_levels = valid ? 4 : 0;
      m_thin = (!valid) || (depthRatio < InpThinBookRatio);
     }
   void              ResetInjections()
     {
      m_imbalance=0.0; m_depthRatio=0.0; m_tickVelocity=0.0; m_tickRule=0.0; m_spreadMom=0.0;
      m_levels=0; m_thin=true; m_edge=0.0; m_dir=0;
     }

   double            Edge()        const { return(m_edge);        }
   int               Dir()         const { return(m_dir);         }
   bool              Thin()        const { return(m_thin);        }
   bool              PreferPassive() const
     {
      return(PreferPassiveFromInputs(BookUsable(), m_depthRatio, m_spreadMom));
     }
   double            Imbalance()   const { return(m_imbalance);   }
   double            DepthRatio()  const { return(m_depthRatio);  }
   double            TickVelocity()const { return(m_tickVelocity);}
   double            TickRule()    const { return(m_tickRule);    }
   double            SpreadMom()   const { return(m_spreadMom);   }
   int               Levels()      const { return(m_levels);      }
  };

//==================================================================
//  7. C_HFTExecution -- ultra-low-latency execution manager
//     activation: aggression decision / hedge decision / timer
//     mechanism : OrderSendAsync() micro-batches (IOC) + managed
//                 non-marketable midpoint pegs (client-side iceberg)
//     metric    : ExecutionTime_ms per micro-order, AvgLatency, P95,
//                 MicroFillRate, CancellationRate (via C_Telemetry)
//==================================================================
#define EXEC_INFLIGHT_SLOTS 128
#define EXEC_MAX_PEGS        8

class C_HFTExecution
  {
private:
   C_Telemetry        *m_tel;

   SInFlight          m_inflight[EXEC_INFLIGHT_SLOTS];
   SPeg               m_pegs[EXEC_MAX_PEGS];
   CPositionInfo      m_pi;

   ulong              m_lastDealTicket;   // dedupe DEAL_ADD notifications

   //--- net exposure cache
   double             m_netLots;
   double             m_grossLots;
   double             m_floatPnL;
   ulong              m_ownTrades;
   datetime           m_posScan;

   int               FindFreeInflight()
     {
      int oldest = 0; ulong oldestMs = ULONG_MAX;
      for(int i=0;i<EXEC_INFLIGHT_SLOTS;i++)
        {
         if(!m_inflight[i].used) return(i);
         if(m_inflight[i].send_ms < oldestMs) { oldestMs = m_inflight[i].send_ms; oldest = i; }
        }
      return(oldest);                                  // ring overwrite: bounded memory
     }
   int               FindInflightById(const ulong id)
     {
      if(id == 0) return(-1);
      for(int i=0;i<EXEC_INFLIGHT_SLOTS;i++)
         if(m_inflight[i].used && m_inflight[i].id == id) return(i);
      return(-1);
     }
   int               FindPegByTicket(const ulong ticket)
     {
      if(ticket == 0) return(-1);
      for(int i=0;i<EXEC_MAX_PEGS;i++)
         if(m_pegs[i].ticket == ticket) return(i);
      return(-1);
     }
   int               FindFreePeg()
     {
      for(int i=0;i<EXEC_MAX_PEGS;i++) if(m_pegs[i].ticket == 0) return(i);
      return(-1);
     }
   int               CountAlivePegsSide(const int side) const
     {
      int c=0;
      for(int i=0;i<EXEC_MAX_PEGS;i++) if(m_pegs[i].ticket != 0 && m_pegs[i].side == side) c++;
      return(c);
     }
   int               CountAlivePegs() const
     {
      int c=0;
      for(int i=0;i<EXEC_MAX_PEGS;i++) if(m_pegs[i].ticket != 0) c++;
      return(c);
     }

   //---------------------------------------------------------------
   //  PEG ADOPTION -- TRADE_TRANSACTION_ORDER_ADD carries no request id,
   //  so a resting limit is matched to its provisional peg slot by
   //  side + exact requested price, preferring the in-flight record.
   //---------------------------------------------------------------
   void              AdoptPegOrder(const ulong ticket, const int side, const double price)
     {
      if(ticket == 0) return;
      if(FindPegByTicket(ticket) >= 0) return;               // already tracked
      int    best    = -1;
      bool   isHedge = false;
      double reqVol  = 0.0;
      for(int i=0;i<EXEC_INFLIGHT_SLOTS;i++)
        {
         if(!m_inflight[i].used || !m_inflight[i].peg) continue;
         if(m_inflight[i].side != side) continue;
         if(MathAbs(m_inflight[i].req_price - price) < g_tickSize*0.5) { best = i; break; }
         if(best < 0) best = i;
        }
      int slot = -1;
      if(best >= 0)
        {
         isHedge = m_inflight[best].hedge;          // captured BEFORE the slot is freed
         reqVol  = m_inflight[best].req_volume;
         for(int i=0;i<EXEC_MAX_PEGS;i++)
            if(m_pegs[i].ticket == 1 && m_pegs[i].side == side) { slot = i; break; }
         m_inflight[best].used = false;
        }
      else
        {
         for(int i=0;i<EXEC_MAX_PEGS;i++)
            if(m_pegs[i].ticket == 0) { slot = i; break; }
        }
      if(slot < 0)
        {
         //--- no slot: remove the order instead of leaving an untracked quote
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = ticket;
         if(OrderSendAsync(req, res)) m_tel.NoteCancellation();
         PrintFormat("EXEC: no peg slot for order %I64u -> removed (bounded peg book)", ticket);
         return;
        }
      m_pegs[slot].ticket          = ticket;
      m_pegs[slot].side            = side;
      m_pegs[slot].hedge           = isHedge;
      m_pegs[slot].price           = NormPrice(price);
      m_pegs[slot].volume          = reqVol;
      m_pegs[slot].placed          = TimeCurrent();
      m_pegs[slot].last_reprice_ms = GetTickCount64();
      //--- authoritative resting volume from the server when it is available
      if(OrderSelect(ticket))
        {
         double v = OrderGetDouble(ORDER_VOLUME_CURRENT);
         if(v > 0.0) m_pegs[slot].volume = v;
        }
     }

   ulong             NextRequestId()
     {
      g_requestSeq++;
      if(g_requestSeq == 0) g_requestSeq = 1;          // 0 means "unset"
      return(g_requestSeq);
     }

   double            JitteredDeviation() const
     {
      if(InpDeviationPoints == 0) return(0.0);
      if(!InpRandomizeDeviation)  return((double)InpDeviationPoints);
      int span = (int)MathMin(InpDeviationPoints, (ulong)INT_MAX);
      if(span <= 1) return((double)InpDeviationPoints);
      return((double)(MathRand() % span));             // legal: bounded by own max deviation
     }

   //--- raw async send; registers the in-flight record BEFORE sending so a
   //    fast TRADE_TRANSACTION_REQUEST answer can always be matched.
   bool              SendAsync(MqlTradeRequest &req, MqlTradeResult &res,
                               const double reqVolume, const bool hedge, const bool peg)
     {
      if(m_tel.Shutdown())
        {
         if(InpVerboseLog) Print("EXEC: placement refused - LegalComplianceFlag shutdown latched");
         return(false);
        }
      req.id = NextRequestId();
      int slot = FindFreeInflight();
      m_inflight[slot].Clear();
      m_inflight[slot].used       = true;
      m_inflight[slot].id         = req.id;
      m_inflight[slot].send_ms    = GetTickCount64();
      m_inflight[slot].req_volume = reqVolume;
      m_inflight[slot].req_price  = req.price;
      m_inflight[slot].hedge      = hedge;
      m_inflight[slot].peg        = peg;
      m_inflight[slot].otype      = req.type;
      m_inflight[slot].sent_time  = TimeCurrent();
      m_inflight[slot].side       = (req.type==ORDER_TYPE_BUY || req.type==ORDER_TYPE_BUY_LIMIT) ? 1 : -1;

      if(!OrderSendAsync(req, res))
        {
         m_inflight[slot].used = false;                // never left the terminal
         m_tel.NoteRejection();
         PrintFormat("EXEC: OrderSendAsync failed err=%d type=%d vol=%.2f",
                     _LastError, (int)req.type, reqVolume);
         return(false);
        }
      if(res.request_id != 0) m_inflight[slot].id = res.request_id;   // server-echoed id wins
      m_tel.NotePlacement();
      return(true);
     }

public:
                     C_HFTExecution()
     {
      m_tel=NULL; m_lastDealTicket=0;
      m_netLots=0.0; m_grossLots=0.0; m_floatPnL=0.0; m_ownTrades=0; m_posScan=0;
      for(int i=0;i<EXEC_INFLIGHT_SLOTS;i++) m_inflight[i].Clear();
      for(int i=0;i<EXEC_MAX_PEGS;i++)       m_pegs[i].Clear();
     }

   void              Init(C_Telemetry &tel) { m_tel = &tel; }

   //---------------------------------------------------------------
   //  MICRO-ORDER BATCH SPLITTING (client-side iceberg)
   //  activation: an entry / hedge decision with target volume V
   //  mechanism : N = clamp(InpMicroBullets,3,9) slices; each slice is
   //              floored to VOLUME_STEP and rejected below VOLUME_MIN;
   //              the remainder is folded into the last legal slice so
   //              Sum(slices) == normalized V exactly (no volume leak)
   //  metric    : number of accepted micro-orders
   //---------------------------------------------------------------
   int               SplitVolumes(const double total, double &out[], const int maxOut)
     {
      int n = (int)ClampD((double)InpMicroBullets, 3.0, 9.0);
      if(n > maxOut) n = maxOut;
      ArrayInitialize(out, 0.0);
      bool okt=false;
      double T = NormVolume(total, okt);
      if(!okt || T <= 0.0 || n <= 0) return(0);
      double base = MathFloor(T/(double)n/g_volStep + 1.0e-9)*g_volStep;
      base = NormalizeDouble(base, VolumeDigits());
      if(base < g_volMin - 1.0e-9)
        {
         //--- slices would be sub-minimum: collapse into fewer legal slices
         int k = (int)MathFloor(T/g_volMin + 1.0e-9);
         if(k < 1) return(0);
         if(k > n) k = n;
         base = NormalizeDouble(MathFloor(T/(double)k/g_volStep + 1.0e-9)*g_volStep, VolumeDigits());
         if(base < g_volMin - 1.0e-9) return(0);
         n = k;
        }
      double placed = 0.0;
      for(int i=0;i<n;i++)
        {
         double add = base;
         if(i == n-1)
           {
            add = NormalizeDouble(T - placed, VolumeDigits());   // absorb remainder
            if(add < g_volMin - 1.0e-9)
              {
               //--- remainder is not broker-legal: fold it into the previous slice
               if(i > 0) out[i-1] = NormalizeDouble(out[i-1] + T - placed, VolumeDigits());
               n = i;
               break;
              }
           }
         out[i] = add;
         placed = NormalizeDouble(placed + add, VolumeDigits());
        }
      return(n);
     }

   //---------------------------------------------------------------
   //  IOC MICRO-BULLETS (aggressive liquidity taking)
   //---------------------------------------------------------------
   bool              FireOneIOC(const int dir, const double volume, const bool hedge)
     {
      if(dir == 0) return(false);
      bool ok=false;
      double v = NormVolume(volume, ok);
      double bulletFloor = MathMax(g_volMin, InpMinBulletLots);
      if(!ok || v <= 0.0 || v < bulletFloor - 1.0e-9)
        {
         PrintFormat("EXEC REJECT: micro-order %.5f lots below floor %.2f (broker min %.2f step %.2f) - not bumped",
                     volume, bulletFloor, g_volMin, g_volStep);
         return(false);
        }
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return(false);
      double px = (dir > 0) ? tick.ask : tick.bid;
      if(px <= 0.0) return(false);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = v;
      req.price        = NormPrice(px);
      req.deviation    = (ulong)MathMax((double)0.0, JitteredDeviation());
      req.type         = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      req.type_filling = g_fillPolicy;
      req.type_time    = ORDER_TIME_GTC;
      req.magic        = hedge ? InpMagicHedge : InpMagicMain;
      req.comment      = hedge ? "HFT-H" : "HFT-M";
      //--- protective levels are attached only to the main sleeve: the hedge
      //    sleeve owns its catastrophe stop (TRADE_ACTION_SLTP) and must not
      //    be closed early by an entry-distance stop.
      if(!hedge && g_slPoints > 0.0)
        {
         double sl = NormPrice((dir > 0) ? px - g_slPoints*g_point : px + g_slPoints*g_point);
         if(sl > 0.0) req.sl = sl;
        }
      if(!hedge && g_tpPoints > 0.0)
        {
         double tp = NormPrice((dir > 0) ? px + g_tpPoints*g_point : px - g_tpPoints*g_point);
         if(tp > 0.0) req.tp = tp;
        }

      return(SendAsync(req, res, v, hedge, false));
     }

   int               FireIOC(const int dir, const double total, const bool hedge)
     {
      double slices[16];
      int n = SplitVolumes(total, slices, 16);
      if(n <= 0) return(0);
      int sent = 0;
      for(int i=0;i<n;i++)
        {
         if(slices[i] <= 0.0) continue;
         if(FireOneIOC(dir, slices[i], hedge)) sent++;
         if(InpMaxJitterMs > 0 && i < n-1 && !MQLInfoInteger(MQL_TESTER))
           {
            //--- legal micro-timing jitter: bounded, non-deterministic spacing.
            //    Busy-wait in milliseconds only (no Sleep() in event handlers).
            ulong t0 = GetTickCount64();
            int   ms = MathRand() % (InpMaxJitterMs + 1);
            while((int)(GetTickCount64() - t0) < ms) { /* spin: sub-50ms, bounded */ }
           }
        }
      if(InpVerboseLog)
         PrintFormat("EXEC: IOC batch dir=%+d slices=%d sent=%d total=%.2f hedge=%d",
                     dir, n, sent, total, (int)hedge);
      return(sent);
     }

   //---------------------------------------------------------------
   //  PASSIVE MIDPOINT PEG (legal substitute for aggressive tactics)
   //  activation: thin book / latency escalation / passive ratio
   //  mechanism : one non-marketable limit per side at
   //              buy  : min(mid - max(1 tick, stopsLevel), bid - 1 tick)
   //              sell : max(mid + max(1 tick, stopsLevel), ask + 1 tick)
   //              => never crosses the spread, never prints as a
   //                 marketable order, one level per side (anti-layering)
   //  metric    : PegsResting, CancellationRate (re-price = 1 cancel + 1 place)
   //---------------------------------------------------------------
   bool              PlacePassivePeg(const int dir, const double volume, const bool hedge)
     {
      if(dir == 0) return(false);
      int maxLayers = (int)MathMax(InpMaxOwnLayersPerSide,1);
      if(CountAlivePegsSide(dir) >= maxLayers) return(false);      // anti-layering cap
      int slot = FindFreePeg();
      if(slot < 0) return(false);
      bool ok=false;
      double v = NormVolume(volume, ok);
      if(!ok || v <= 0.0) return(false);

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return(false);
      if(tick.bid <= 0.0 || tick.ask <= 0.0) return(false);
      double mid   = 0.5*(tick.bid + tick.ask);
      double minOff= MathMax(g_tickSize, StopsDistance());
      double price;
      if(dir > 0)
        {
         price = NormPrice(MathMin(mid - minOff, tick.bid - g_tickSize));   // non-marketable
         if(price >= tick.bid) price = NormPrice(tick.bid - g_tickSize);
        }
      else
        {
         price = NormPrice(MathMax(mid + minOff, tick.ask + g_tickSize));
         if(price <= tick.ask) price = NormPrice(tick.ask + g_tickSize);
        }
      if(price <= 0.0) return(false);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = _Symbol;
      req.volume       = v;
      req.price        = price;
      req.type         = (dir > 0) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      req.type_filling = g_fillPolicy;
      req.type_time    = ORDER_TIME_GTC;
      req.magic        = hedge ? InpMagicHedge : InpMagicMain;
      req.comment      = hedge ? "HFT-HP" : "HFT-P";
      //--- a resting limit is a real order: it carries the same protection
      if(!hedge && g_slPoints > 0.0)
        {
         double sl = NormPrice((dir > 0) ? price - g_slPoints*g_point : price + g_slPoints*g_point);
         if(sl > 0.0) req.sl = sl;
        }
      if(!hedge && g_tpPoints > 0.0)
        {
         double tp = NormPrice((dir > 0) ? price + g_tpPoints*g_point : price - g_tpPoints*g_point);
         if(tp > 0.0) req.tp = tp;
        }
      if(!SendAsync(req, res, v, hedge, true)) return(false);

      m_pegs[slot].ticket           = 1;             // provisional until ORDER_ADD
      m_pegs[slot].side             = dir;
      m_pegs[slot].hedge            = hedge;
      m_pegs[slot].price            = price;
      m_pegs[slot].volume           = v;
      m_pegs[slot].placed           = TimeCurrent();
      m_pegs[slot].last_reprice_ms  = GetTickCount64();
      return(true);
     }

   //--- cancel one resting order (async) and release the peg slot
   bool              CancelPegIndex(const int idx, const string reason)
     {
      if(idx < 0 || idx >= EXEC_MAX_PEGS) return(false);
      ulong ticket = m_pegs[idx].ticket;
      if(ticket == 0 || ticket == 1) { m_pegs[idx].Clear(); return(false); }
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      if(!OrderSendAsync(req, res))
        {
         PrintFormat("EXEC: peg cancel send failed ticket=%I64u err=%d", ticket, _LastError);
         m_pegs[idx].Clear();
         m_tel.NoteCancellation();
         return(false);
        }
      m_pegs[idx].Clear();
      m_tel.NoteCancellation();
      if(InpVerboseLog)
         PrintFormat("EXEC: peg cancelled ticket=%I64u (%s)", ticket, reason);
      return(true);
     }

   void              CancelAllPegs(const string reason)
     {
      for(int i=0;i<EXEC_MAX_PEGS;i++)
         if(m_pegs[i].ticket != 0) CancelPegIndex(i, reason);
     }

   //---------------------------------------------------------------
   //  PEG MAINTENANCE -- rate limited re-pricing (anti quote-churn)
   //---------------------------------------------------------------
   void              RepricePegs()
     {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return;
      if(tick.bid <= 0.0 || tick.ask <= 0.0) return;
      ulong nowMs = GetTickCount64();
      for(int i=0;i<EXEC_MAX_PEGS;i++)
        {
         if(m_pegs[i].ticket == 0) continue;
         if(m_pegs[i].ticket == 1) continue;          // not yet confirmed by ORDER_ADD
         int  side = m_pegs[i].side;
         double mid = 0.5*(tick.bid + tick.ask);
         double minOff = MathMax(g_tickSize, StopsDistance());
         double target = (side > 0) ? NormPrice(MathMin(mid - minOff, tick.bid - g_tickSize))
                                    : NormPrice(MathMax(mid + minOff, tick.ask + g_tickSize));
         if(target <= 0.0) continue;
         double moveTicks = SafeDiv(MathAbs(target - m_pegs[i].price), g_tickSize, 0.0);
         bool   aged      = (InpPegMaxAgeSec > 0 &&
                             (int)(TimeCurrent() - m_pegs[i].placed) >= InpPegMaxAgeSec);
         //--- spec-named execution-speed metrics are read from C_Telemetry
         bool   due       = ((int)(nowMs - m_pegs[i].last_reprice_ms) >=
                             1000*MathMax(InpPegMinRepriceSec,1));
         if(!aged && !(due && moveTicks >= (double)MathMax(InpPegMinMoveTicks,1))) continue;

         double vol  = m_pegs[i].volume;
         bool   slot_hedge = m_pegs[i].hedge;          // sleeve identity survives the re-price
         CancelPegIndex(i, aged ? "peg-max-resting-age" : "peg-reprice");
         PlacePassivePeg(side, vol, slot_hedge);
        }
     }

   //---------------------------------------------------------------
   //  ORPHAN / STALE SWEEP -- keeps CancellationRate honest and
   //  guarantees no resting order outlives its legal purpose
   //---------------------------------------------------------------
   void              Sweep()
     {
      ulong nowMs = GetTickCount64();
      //--- unanswered in-flight requests
      for(int i=0;i<EXEC_INFLIGHT_SLOTS;i++)
        {
         if(!m_inflight[i].used || m_inflight[i].answered) continue;
         if((int)(nowMs - m_inflight[i].send_ms) >= 1000*MathMax(InpOrphanAgeSec,1))
           {
            m_tel.NoteOrphan();
            m_inflight[i].used = false;
            if(InpVerboseLog)
               PrintFormat("EXEC: orphan request id=%I64u age>%ds -> released (metric only)",
                           m_inflight[i].id, (int)InpOrphanAgeSec);
           }
        }
      //--- provisional peg slots whose request was never answered = ORPHAN
      for(int i=0;i<EXEC_MAX_PEGS;i++)
        {
         if(m_pegs[i].ticket != 1) continue;
         if((int)(nowMs - m_pegs[i].last_reprice_ms) >= 1000*MathMax(InpOrphanAgeSec,1))
           {
            m_tel.NoteOrphan();
            m_pegs[i].Clear();
           }
        }
      //--- resting orders older than their max age: deliberate recycling,
      //    counted as a cancellation only (never as an orphan)
      for(int i=0;i<EXEC_MAX_PEGS;i++)
        {
         if(m_pegs[i].ticket <= 1) continue;
         if(InpPegMaxAgeSec > 0 &&
            (int)(TimeCurrent() - m_pegs[i].placed) >= InpPegMaxAgeSec)
           {
            //--- FREEZE LEVEL: a resting order inside the freeze distance cannot
            //    be deleted; the attempt is skipped instead of being rejected
            MqlTick tk;
            if(g_freezeLevel > 0 && SymbolInfoTick(_Symbol, tk) && tk.bid > 0.0)
              {
               double distPts = MathAbs(tk.bid - m_pegs[i].price)/g_point;
               if(distPts < (double)g_freezeLevel) continue;
              }
            CancelPegIndex(i, "peg-max-resting-age");
           }
        }
      //--- server-side orphans: own pending orders not tracked locally
      int total = OrdersTotal();
      for(int i=total-1;i>=0;i--)
        {
         ulong tk = OrderGetTicket(i);
         if(tk == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         long mg = OrderGetInteger(ORDER_MAGIC);
         if(mg != (long)InpMagicMain && mg != (long)InpMagicHedge) continue;
         if(FindPegByTicket(tk) >= 0) continue;                    // tracked
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = tk;
         if(OrderSendAsync(req, res))
           {
            m_tel.NoteCancellation();
            m_tel.NoteOrphan();
            PrintFormat("EXEC: untracked own order %I64u removed (orphan protection)", tk);
           }
        }
     }

   //---------------------------------------------------------------
   //  TRANSACTION HANDLING -- latency + fill accounting
   //---------------------------------------------------------------
   void              OnTransaction(const MqlTradeTransaction &trans,
                                   const MqlTradeRequest &request,
                                   const MqlTradeResult &result)
     {
      if(trans.type == TRADE_TRANSACTION_REQUEST)
        {
         ulong id = result.request_id;
         if(id == 0) id = request.id;
         int idx = FindInflightById(id);
         if(idx < 0) return;                            // not ours (or already released)
         SInFlight rec = m_inflight[idx];
         m_inflight[idx].answered = true;
         m_inflight[idx].done_ms  = GetTickCount64();
         double ms = (double)(m_inflight[idx].done_ms - rec.send_ms);
         m_tel.AddLatencyMs(ms);                         // ExecutionTime_ms of this micro-order

         uint rc = result.retcode;
         bool accepted = (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
                          rc == TRADE_RETCODE_DONE_PARTIAL);
         if(!accepted)
           {
            m_tel.NoteRejection();
            m_inflight[idx].used = false;
            PrintFormat("EXEC ANSWER: request id=%I64u rejected rc=%u (%s) latency=%.0fms",
                        id, rc, RetcodeName(rc), ms);
            return;
           }
         if(rec.peg)
           {
            m_tel.NotePeg(true);
            //--- for TRADE_TRANSACTION_REQUEST only trans.type is filled, so the
            //    resting order ticket is taken from MqlTradeResult.order
            ulong resting = result.order;
            if(resting != 0)
              {
               int p = -1;
               for(int i=0;i<EXEC_MAX_PEGS;i++)
                  if(m_pegs[i].ticket == 1 && m_pegs[i].side == rec.side) { p = i; break; }
               if(p >= 0)
                 {
                  m_pegs[p].ticket = resting;
                  if(result.volume > 0.0) m_pegs[p].volume = result.volume;
                 }
               else AdoptPegOrder(resting, rec.side, rec.req_price);
              }
            m_inflight[idx].used = false;
            return;
           }
         bool filled = (result.volume > 0.0);
         if(filled) m_inflight[idx].filled += result.volume;
         if(rec.hedge || rec.otype == ORDER_TYPE_BUY || rec.otype == ORDER_TYPE_SELL)
            m_tel.NoteIOC(filled);
         if(InpVerboseLog)
            PrintFormat("EXEC ANSWER: id=%I64u rc=%u (%s) vol=%.2f/%.2f latency=%.0fms hedge=%d",
                        id, rc, RetcodeName(rc), result.volume, rec.req_volume, ms, (int)rec.hedge);
         if(rc != TRADE_RETCODE_DONE_PARTIAL) m_inflight[idx].used = false;
         return;
        }

      if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
        {
         ulong dealTicket = trans.deal;
         if(dealTicket == 0 || dealTicket == m_lastDealTicket) return;   // dedupe
         m_lastDealTicket = dealTicket;
         //--- MqlTradeTransaction carries no magic/entry fields: the deal is
         //    resolved from history and filtered by SYMBOL + MAGIC + ENTRY
         if(!HistoryDealSelect(dealTicket)) return;
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) return;
         long mg = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         if(mg != (long)InpMagicMain && mg != (long)InpMagicHedge) return;
         long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT) return;  // opening volume only
         double vol = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
         if(vol <= 0.0) return;
         bool hedge = (mg == (long)InpMagicHedge);
         m_tel.NoteVolume(vol, vol, hedge);
         if(!hedge) g_dayVolume += vol;                    // own opened volume today
         if(InpVerboseLog)
            PrintFormat("EXEC DEAL: ticket=%I64u vol=%.2f hedge=%d dayVolume=%.2f",
                        dealTicket, vol, (int)hedge, g_dayVolume);
         return;
        }

      if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
        {
         int side = (trans.order_type == ORDER_TYPE_BUY_LIMIT) ? 1 :
                    ((trans.order_type == ORDER_TYPE_SELL_LIMIT) ? -1 : 0);
         if(side == 0 || trans.order == 0) return;
         //--- OWNERSHIP: adopt only orders carrying one of our two magics, so a
         //    manual or third-party limit order can never be re-priced or cancelled
         if(!OrderSelect(trans.order)) return;
         long mg = OrderGetInteger(ORDER_MAGIC);
         if(mg != (long)InpMagicMain && mg != (long)InpMagicHedge) return;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) return;
         AdoptPegOrder(trans.order, side, trans.price);
         return;
        }

      if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
        {
         int p = FindPegByTicket(trans.order);
         if(p >= 0) m_pegs[p].Clear();                   // server-side removal: free the slot
        }
     }

   string            RetcodeName(const uint rc)
     {
      switch(rc)
        {
         case TRADE_RETCODE_DONE:             return("DONE");
         case TRADE_RETCODE_DONE_PARTIAL:     return("DONE_PARTIAL");
         case TRADE_RETCODE_PLACED:           return("PLACED");
         case TRADE_RETCODE_REQUOTE:          return("REQUOTE");
         case TRADE_RETCODE_REJECT:           return("REJECT");
         case TRADE_RETCODE_CANCEL:           return("CANCELLED");
         case TRADE_RETCODE_ERROR:            return("COMMON_ERROR");
         case TRADE_RETCODE_TIMEOUT:          return("TIMEOUT");
         case TRADE_RETCODE_INVALID:          return("INVALID_REQUEST");
         case TRADE_RETCODE_INVALID_VOLUME:   return("INVALID_VOLUME");
         case TRADE_RETCODE_INVALID_PRICE:    return("INVALID_PRICE");
         case TRADE_RETCODE_INVALID_STOPS:    return("INVALID_STOPS");
         case TRADE_RETCODE_TRADE_DISABLED:   return("TRADE_DISABLED");
         case TRADE_RETCODE_MARKET_CLOSED:    return("MARKET_CLOSED");
         case TRADE_RETCODE_NO_MONEY:         return("NO_MONEY");
         case TRADE_RETCODE_PRICE_CHANGED:    return("PRICE_CHANGED");
         case TRADE_RETCODE_PRICE_OFF:        return("PRICE_OFF");
         case TRADE_RETCODE_INVALID_FILL:     return("INVALID_FILL");
         case TRADE_RETCODE_CONNECTION:       return("CONNECTION");
         case TRADE_RETCODE_TOO_MANY_REQUESTS:return("TOO_MANY_REQUESTS");
         case TRADE_RETCODE_NO_CHANGES:       return("NO_CHANGES");
         case TRADE_RETCODE_LOCKED:           return("LOCKED");
         case TRADE_RETCODE_FROZEN:           return("FROZEN");
         case TRADE_RETCODE_LIMIT_VOLUME:     return("LIMIT_VOLUME");
         case TRADE_RETCODE_POSITION_CLOSED:  return("POSITION_CLOSED");
        }
      return("RC_"+IntegerToString((long)rc));
     }

   //---------------------------------------------------------------
   //  OWN POSITION AGGREGATION (symbol + magic scoped, never global)
   //---------------------------------------------------------------
   void              RefreshPositions(const bool force)
     {
      datetime now = TimeCurrent();
      if(!force && m_posScan != 0 && (int)(now - m_posScan) < 1) return;
      m_posScan = now;
      double net=0.0, gross=0.0, pnl=0.0; ulong trades=0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         if(!m_pi.SelectByIndex(i)) continue;
         if(m_pi.Symbol() != _Symbol) continue;
         ulong mg = m_pi.Magic();
         if(mg != InpMagicMain && mg != InpMagicHedge) continue;
         double v = m_pi.Volume();
         gross += v;
         net   += (m_pi.PositionType() == POSITION_TYPE_BUY) ? v : -v;
         pnl   += m_pi.Profit() + m_pi.Swap();
         trades++;
        }
      m_netLots=net; m_grossLots=gross; m_floatPnL=pnl; m_ownTrades=trades;
     }
   double            NetLots()    { RefreshPositions(false); return(m_netLots);    }
   double            GrossLots()  { RefreshPositions(false); return(m_grossLots);  }
   double            FloatPnL()   { RefreshPositions(false); return(m_floatPnL);   }
   ulong             OwnTrades()  { RefreshPositions(false); return(m_ownTrades);  }
   double            NetNotionalUSD()
     {
      RefreshPositions(false);
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return(0.0);
      double px = (m_netLots >= 0.0) ? tick.bid : tick.ask;
      if(px <= 0.0) return(0.0);
      return(MathAbs(m_netLots)*px);
     }

   //---------------------------------------------------------------
   //  RISK COMPRESSION CLOSES (explicit position field, own magic only)
   //---------------------------------------------------------------
   bool              ClosePartialSideMagic(const ulong magic, const int posDir, double lots)
     {
      if(posDir == 0 || lots <= 0.0) return(false);
      bool did=false;
      int total = PositionsTotal();
      for(int i=total-1;i>=0 && lots > g_volMin*0.5;i--)
        {
         if(!m_pi.SelectByIndex(i)) continue;
         if(m_pi.Symbol() != _Symbol) continue;
         if(m_pi.Magic() != magic) continue;
         int sd = (m_pi.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
         if(sd != posDir) continue;
         ulong ticket = m_pi.Ticket();
         double have  = m_pi.Volume();
         double take  = MathMin(lots, have);
         bool   ok=false;
         double v     = NormVolume(take, ok);
         if(!ok || v <= 0.0)
           {
            if(take >= have*0.75) v = have;             // full leg close is broker-legal
            else continue;                              // sub-minimum: skip, never bump
           }
         if(v >= have - 1.0e-9)
           {
            if(ClosePosition(ticket, have)) { lots -= have; did=true; }
            else break;
           }
         else
           {
            if(ClosePosition(ticket, v)) { lots -= v; did=true; }
            else break;
           }
        }
      return(did);
     }

   bool              ClosePosition(const ulong ticket, const double volume)
     {
      if(ticket == 0 || volume <= 0.0) return(false);
      if(!PositionSelectByTicket(ticket)) return(false);
      long type = PositionGetInteger(POSITION_TYPE);
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return(false);
      bool isBuy = (type == POSITION_TYPE_BUY);
      double px  = isBuy ? tick.bid : tick.ask;
      if(px <= 0.0) return(false);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = _Symbol;
      req.volume       = volume;
      req.price        = NormPrice(px);
      req.deviation    = InpDeviationPoints;
      req.type         = isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.type_filling = g_fillPolicy;
      req.magic        = (ulong)PositionGetInteger(POSITION_MAGIC);
      req.comment      = "HFT-C";

      //--- closes are risk-reducing: synchronous OrderSend() is used so the
      //    result is known before the next slice (no unwind race).
      if(!OrderSend(req, res))
        {
         PrintFormat("EXEC: close send failed ticket=%I64u err=%d", ticket, _LastError);
         m_tel.NoteRejection();
         return(false);
        }
      uint rc = res.retcode;
      if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED)
        {
         if(InpVerboseLog)
            PrintFormat("EXEC: closed ticket=%I64u vol=%.2f rc=%s", ticket, volume, RetcodeName(rc));
         return(true);
        }
      m_tel.NoteRejection();
      PrintFormat("EXEC: close rejected ticket=%I64u rc=%u (%s)", ticket, rc, RetcodeName(rc));
      return(false);
     }

   //--- catastrophe stop placement on the hedge sleeve (broker-side protection)
   void              ArmHedgeStops(const double atrH1)
     {
      if(atrH1 <= 0.0 || InpHedgeStopATR_H1 <= 0.0) return;
      double dist = NormPrice(InpHedgeStopATR_H1*atrH1);
      if(dist <= 0.0) return;
      double minStop = StopsDistance();
      if(dist < minStop) dist = minStop;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         if(!m_pi.SelectByIndex(i)) continue;
         if(m_pi.Symbol() != _Symbol) continue;
         if(m_pi.Magic() != InpMagicHedge) continue;
         if(m_pi.StopLoss() > 0.0) continue;                 // already armed
         ulong  ticket = m_pi.Ticket();
         double open   = m_pi.PriceOpen();
         bool   isBuy  = (m_pi.PositionType() == POSITION_TYPE_BUY);
         double sl     = NormPrice(isBuy ? open - dist : open + dist);
         if(sl <= 0.0) continue;
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = sl;
         req.tp       = m_pi.TakeProfit();
         if(!OrderSend(req, res))
           {
            PrintFormat("EXEC: hedge SL arm failed ticket=%I64u err=%d", ticket, _LastError);
            continue;
           }
         if(res.retcode != TRADE_RETCODE_DONE)
            PrintFormat("EXEC: hedge SL arm rejected ticket=%I64u rc=%u (%s)",
                        ticket, res.retcode, RetcodeName(res.retcode));
        }
     }

   int               PegsResting() const { return(CountAlivePegs()); }
  };

//==================================================================
//  8. C_SafetyManager -- gates + legal-compliance monitor
//     activation: every decision attempt and every timer cycle
//     mechanism : spread / margin / rollover / daily-loss gates plus a
//                 rolling cancellation, orphan and layering monitor that
//                 raises LegalComplianceFlag and throttles or shuts down
//     metric    : CancellationRate, OrphanRate, LegalComplianceFlag
//==================================================================
class C_SafetyManager
  {
private:
   datetime          m_lastAudit;
   datetime          m_lastWarn;

public:
                     C_SafetyManager() { m_lastAudit=0; m_lastWarn=0; }

   //--- server day anchor: daily guards and the CSV day window
   void              AnchorDay()
     {
      datetime k = iTime(_Symbol, PERIOD_D1, 0);
      if(k == 0)
        {
         datetime t = TimeCurrent();
         k = t - (datetime)(t % 86400);                 // UTC midnight fallback
        }
      if(k != g_lastDayKey)
        {
         g_lastDayKey     = k;
         g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         g_dayVolume      = 0.0;
         PrintFormat("SAFE: new server day %s anchored equity=%.2f",
                     TimeToString(k,TIME_DATE), g_dayStartEquity);
        }
     }

   //--- rollover / low-liquidity window (default 23:55 -> 01:05 server)
   bool              InRollover() const
     {
      if(!InpRespectRollover) return(false);
      MqlDateTime st;
      TimeToStruct(TimeCurrent(), st);
      int mins = st.hour*60 + st.min;
      int a = (int)ClampD((double)InpRolloverStartMin, 0.0, 1439.0);
      int b = (int)ClampD((double)InpRolloverEndMin,   0.0, 1439.0);
      if(a == b) return(false);
      return (a < b) ? (mins >= a && mins < b) : (mins >= a || mins < b);
     }

   double            SpreadPoints() const
     {
      double sp = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(sp > 0.0) return(sp);
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return(0.0);
      if(tick.ask <= 0.0 || tick.bid <= 0.0 || g_point <= 0.0) return(0.0);
      return((tick.ask - tick.bid)/g_point);
     }
   bool              SpreadOK() const
     {
      if(InpMaxSpreadPoints <= 0) return(true);
      return(SpreadPoints() <= (double)InpMaxSpreadPoints);
     }

   bool              MarginOK(string &why)
     {
      why = "";
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double margin = AccountInfoDouble(ACCOUNT_MARGIN);
      if(equity <= 0.0) { why = "no equity"; return(false); }
      if(margin <= 0.0) return(true);                       // flat: no margin used
      double level = equity/margin*100.0;
      if(InpCriticalMarginLevel > 0.0 && level < InpCriticalMarginLevel)
        {
         why = StringFormat("margin level %.1f%% < critical %.1f%%", level, InpCriticalMarginLevel);
         return(false);
        }
      return(true);
     }
   double            MarginFreePct()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double margin = AccountInfoDouble(ACCOUNT_MARGIN);
      if(equity <= 0.0) return(0.0);
      if(margin <= 0.0) return(1.0);                        // nothing committed
      double freePct = (equity - margin)/equity;
      return(ClampD(freePct, 0.0, 1.0));
     }
   //--- normalized margin headroom used by the aggression score
   double            MarginHealth()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double margin = AccountInfoDouble(ACCOUNT_MARGIN);
      if(equity <= 0.0) return(0.0);
      if(margin <= 0.0) return(1.0);
      double level = equity/margin*100.0;
      double crit  = MathMax(InpCriticalMarginLevel, 1.0);
      double healthy = MathMax(InpHealthyMarginLevel, crit + 1.0);
      return(ClampD((level - crit)/(healthy - crit), 0.0, 1.0));
     }

   bool              DailyLossBreached(string &why, double &dayPnL)
     {
      why = "";
      dayPnL = 0.0;
      if(InpDailyLossLimitPct <= 0.0) return(false);
      if(g_dayStartEquity <= 0.0)     return(false);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      dayPnL = equity - g_dayStartEquity;                  // realized + floating vs day start
      double limit = -InpDailyLossLimitPct/100.0*g_dayStartEquity;
      if(dayPnL <= limit)
        {
         why = StringFormat("daily P&L %.2f <= limit %.2f", dayPnL, limit);
         return(true);
        }
      return(false);
     }

   //---------------------------------------------------------------
   //  CAPACITY BRAKE (money, not lots)
   //  activation: every entry attempt
   //  mechanism : the margin the broker would reserve for this order is
   //              computed with OrderCalcMargin() and must fit under
   //              InpMaxMarginUsePct of equity. Lots are a poor proxy for
   //              risk when leverage and price move.
   //  metric    : used margin vs cap (also shown on the chart)
   //---------------------------------------------------------------
   bool              MarginCapacityOK(const double volume, const int dir, string &why)
     {
      why = "";
      if(InpMaxMarginUsePct <= 0.0) return(true);            // brake disabled by the user
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq <= 0.0) { why = "no equity"; return(false); }
      MqlTick tk;
      if(!SymbolInfoTick(_Symbol, tk)) return(true);          // no quote: never invent a refusal
      double px = (dir > 0) ? tk.ask : tk.bid;
      if(px <= 0.0) return(true);
      double need = 0.0;
      ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcMargin(ot, _Symbol, volume, px, need)) return(true);
      if(!IsFiniteD(need) || need <= 0.0) return(true);
      double used = AccountInfoDouble(ACCOUNT_MARGIN);
      double cap  = InpMaxMarginUsePct/100.0*eq;
      if(used + need > cap + 1.0e-9)
        {
         why = StringFormat("margin capacity: used %.2f + needed %.2f > cap %.2f (%.0f%% of equity %.2f)",
                            used, need, cap, InpMaxMarginUsePct, eq);
         return(false);
        }
      return(true);
     }

   //---------------------------------------------------------------
   //  RISK BUDGET (opt-in, needs InpStopLossPoints > 0)
   //  activation: every entry attempt with a stop attached
   //  mechanism : budget = InpMaxRiskPerEntryPct% of equity; lots that the
   //              stop distance can carry = budget / lossPerLot(SL), where
   //              lossPerLot comes from OrderCalcProfit() (broker exact)
   //              with the tick-value / contract-size formulas as fallbacks
   //  metric    : volume that is never bigger than the risk budget allows;
   //              a budget that cannot carry one legal lot REFUSES the entry
   //              (reject, never bump - the volume is never rounded up)
   //---------------------------------------------------------------
   double            RiskCappedVolume(const double intended, const int dir,
                                      const double refPrice, string &why)
     {
      why = "";
      if(InpMaxRiskPerEntryPct <= 0.0 || g_slPoints <= 0.0) return(intended);  // disabled
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq <= 0.0 || refPrice <= 0.0) return(intended);
      double budget = InpMaxRiskPerEntryPct/100.0*eq;
      double slDist = g_slPoints*g_point;
      double slPrice = (dir > 0) ? refPrice - slDist : refPrice + slDist;
      if(slPrice <= 0.0 || slDist <= 0.0) return(intended);
      ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double lossPerLot = 0.0, p = 0.0;
      if(OrderCalcProfit(ot, _Symbol, 1.0, refPrice, slPrice, p) && p < 0.0) lossPerLot = -p;
      if(lossPerLot <= 1.0e-9 && g_contractSize > 0.0) lossPerLot = slDist*g_contractSize;
      if(lossPerLot <= 1.0e-9) return(intended);              // cannot price it: do not block
      double raw = budget/lossPerLot;
      bool ok = false;
      double v = NormVolume(raw, ok);
      if(!ok || v <= 0.0)
        {
         why = StringFormat("risk budget %.2f USD cannot carry one legal lot (raw %.5f lots at SL %.0f pts) - rejected, not bumped",
                            budget, raw, g_slPoints);
         return(0.0);
        }
      return(MathMin(intended, v));
     }

   bool              VolumeRoomOK(const double intended, string &why)
     {
      why = "";
      double gross = g_exec.GrossLots();
      if(InpMaxTotalLots > 0.0 && gross + intended > InpMaxTotalLots + 1.0e-9)
        {
         why = StringFormat("lot cap: open %.2f + %.2f > %.2f", gross, intended, InpMaxTotalLots);
         return(false);
        }
      if(InpMaxDailyVolume > 0.0 && g_dayVolume + intended > InpMaxDailyVolume + 1.0e-9)
        {
         why = StringFormat("daily volume cap: %.2f + %.2f > %.2f",
                            g_dayVolume, intended, InpMaxDailyVolume);
         return(false);
        }
      return(true);
     }

   bool              TradePermitted(string &why)
     {
      why = "";
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { why = "MQL trade disabled";      return(false); }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { why = "terminal trading off";    return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   { why = "account trading off";     return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    { why = "EA trading off";          return(false); }
      long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
      if(mode == SYMBOL_TRADE_MODE_DISABLED)           { why = "symbol disabled";         return(false); }
      if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)          { why = "symbol close-only";       return(false); }
      return(true);
     }

   //---------------------------------------------------------------
   //  LEGAL COMPLIANCE AUDIT (anti-manipulation safeguard)
   //  Detects only OWN behaviour patterns that could be misread as
   //  abusive and throttles/stops the engine before a human or a
   //  broker rule engine has to intervene:
   //    1) cancellation rate  > InpMaxCancellationRate
   //    2) orphaned quote rate> InpMaxOrphanRate
   //    3) own layering       > InpMaxOwnLayersPerSide resting per side
   //    4) hard shutdown latch
   //---------------------------------------------------------------
   void              AuditCompliance()
     {
      datetime now = TimeCurrent();
      if(m_lastAudit != 0 && (int)(now - m_lastAudit) < 5) return;
      m_lastAudit = now;
      if(g_telem.Shutdown()) return;                       // already latched

      double cancelRate = g_telem.CancellationRate();
      double orphanRate = g_telem.OrphanRate();
      int    layers     = g_exec.PegsResting();
      int    maxLayers  = 2*(int)MathMax(InpMaxOwnLayersPerSide,1);

      if(InpMaxCancellationRate > 0.0 && cancelRate > InpMaxCancellationRate &&
         g_telem.SentOrders() >= (ulong)MathMax(InpMinComplianceSamples,1))
        {
         g_telem.RaiseFlag(StringFormat("cancellation rate %.2f > %.2f (window %ds)",
                                        cancelRate, InpMaxCancellationRate,
                                        (int)InpComplianceWindowSec));
         return;
        }
      if(InpMaxOrphanRate > 0.0 && orphanRate > InpMaxOrphanRate &&
         g_telem.SentOrders() >= (ulong)MathMax(InpMinComplianceSamples,1))
        {
         g_telem.RaiseFlag(StringFormat("orphan rate %.2f > %.2f", orphanRate, InpMaxOrphanRate));
         return;
        }
      if(layers > maxLayers)
        {
         g_telem.RaiseFlag(StringFormat("own resting layers %d > %d (layering guard)",
                                        layers, maxLayers));
         g_exec.CancelAllPegs("layering-guard");
         return;
        }
      //--- rates back inside the legal envelope: release the throttle only
      if(g_telem.Throttled() && cancelRate <= InpMaxCancellationRate && orphanRate <= InpMaxOrphanRate)
         g_telem.ClearTransientFlag();
     }

   //---------------------------------------------------------------
   //  MASTER GATE for new entries
   //---------------------------------------------------------------
   bool              AllowNewEntry(string &why)
     {
      why = "";
      if(g_telem.Shutdown())  { why = "compliance shutdown latched"; return(false); }
      if(InRollover())        { why = "rollover window";             return(false); }
      if(!SpreadOK())
        { why = StringFormat("spread %.1f pts > %d pts", SpreadPoints(), (int)InpMaxSpreadPoints); return(false); }
      if(!MarginOK(why))      return(false);
      double dayPnL=0.0;
      if(DailyLossBreached(why, dayPnL)) return(false);
      if(!TradePermitted(why)) return(false);
      return(true);
     }
  };

//==================================================================
//  9. C_AggressionBalancer -- decision brain
//     activation: every tick (and every self-test injection)
//     mechanism : Score = w1*MarginFreePct + w2*SessionWinRate
//                       + w3*LiquidityEdgeScore + w4*ExecutionHealth
//                 mapped onto DEFENSIVE / NORMAL / HIGH / MAX plus a
//                 one-time StartupIgnite bootstrap batch
//     metric    : AggressionScore [0,100], Mode, PassiveRatio
//==================================================================
class C_AggressionBalancer
  {
private:
   double            m_score;
   ENUM_AGGR_MODE    m_mode;
   double            m_passiveRatio;
   bool              m_igniteArmed;
   bool              m_igniteLogged;

public:
                     C_AggressionBalancer()
     {
      m_score=0.0; m_mode=AGGR_DEFENSIVE; m_passiveRatio=1.0;
      m_igniteArmed=false; m_igniteLogged=false;
     }

   //--- injectable, therefore deterministically testable
   double            ScoreFromInputs(const double liquidityEdge, const double executionHealth,
                                     const double marginHealth, const double winRate) const
     {
      double wSum = InpW_LiquidityEdge + InpW_ExecutionHealth + InpW_MarginFreePct + InpW_SessionWinRate;
      if(wSum <= 1.0e-9) return(0.0);
      double s = ( InpW_LiquidityEdge   * ClampD(liquidityEdge,0.0,100.0)
                 + InpW_ExecutionHealth * ClampD(executionHealth,0.0,100.0)
                 + InpW_MarginFreePct   * ClampD(marginHealth,0.0,1.0)*100.0
                 + InpW_SessionWinRate  * ClampD(winRate,0.0,1.0)*100.0 ) / wSum;
      return(ClampD(s, 0.0, 100.0));
     }

   ENUM_AGGR_MODE    ModeFromScore(const double score) const
     {
      if(score >= 85.0) return(AGGR_MAX);
      if(score >= 60.0) return(AGGR_HIGH);
      if(score >= 40.0) return(AGGR_NORMAL);
      return(AGGR_DEFENSIVE);
     }

   //--- passive (peg) share of the intended size
   double            PassiveRatioFromInputs(const ENUM_AGGR_MODE mode, const bool preferPassive,
                                            const double p95LatencyMs) const
     {
      double base;
      switch(mode)
        {
         case AGGR_MAX:       base = 0.10; break;   // mostly aggressive sniping
         case AGGR_HIGH:      base = 0.35; break;   // micro-bullets + partial passive
         case AGGR_NORMAL:    base = 0.55; break;   // mixed
         default:             base = 1.00; break;   // defensive: passive / unwind only
        }
      if(preferPassive) base = MathMax(base, 0.70);                  // thin book or no DOM
      double thr = (double)MathMax(InpLatencyThresholdMs,1);
      if(p95LatencyMs > InpP95EscalateFrac*thr) base = MathMax(base, 0.60);   // latency escalation
      return(ClampD(base, InpPassiveRatioFloor, 1.0));
     }

   void              Compute(C_OrderBookScanner &sc, C_HFTExecution &ex, C_Telemetry &tl,
                             C_SafetyManager &sf)
     {
      double edge   = sc.Edge();
      double health = tl.ExecutionHealth();
      double mh     = sf.MarginHealth();
      double wr     = tl.SessionWinRate();
      m_score = ScoreFromInputs(edge, health, mh, wr);
      m_mode  = ModeFromScore(m_score);
      m_passiveRatio = PassiveRatioFromInputs(m_mode, sc.PreferPassive(), tl.P95Latency());
     }

   //---------------------------------------------------------------
   //  StartupIgnite -- one-time bootstrap so the engine is never idle
   //  activation: SessionTrades == 0 and gates pass
   //  mechanism : single micro-batch at InpBootstrapVolumeFrac of the
   //              normal target volume, regardless of a low score
   //  metric    : bootstrap logged once, m_igniteArmed consumed once
   //---------------------------------------------------------------
   bool              UpdateIgnite(const ulong sessionTrades)
     {
      if(!InpStartupIgnite)     { m_igniteArmed=false; return(false); }
      if(g_igniteUsed)          { m_igniteArmed=false; return(false); }
      if(sessionTrades > 0)     { m_igniteArmed=false; return(false); }
      if(!m_igniteArmed)
        {
         m_igniteArmed = true;
         if(!m_igniteLogged)
           {
            m_igniteLogged = true;
            PrintFormat("IGNITE: StartupIgnite armed - SessionTrades=0, bootstrap volume fraction %.2f",
                        ClampD(InpBootstrapVolumeFrac,0.10,0.30));
           }
        }
      return(true);
     }
   void              ConsumeIgnite() { m_igniteArmed=false; g_igniteUsed=true; }

   //--- aggression clamp applied to the intended size:
   //    scale = clamp(score/100, InpMinAggression, InpMaxAggression)
   double            VolumeScale()  const { return(ClampD(m_score/100.0, InpMinAggression, InpMaxAggression)); }
   double            Score()        const { return(m_score);        }
   ENUM_AGGR_MODE    Mode()         const { return(m_mode);         }
   double            PassiveRatio() const { return(m_passiveRatio); }
   string            ModeName()     const
     {
      switch(m_mode)
        {
         case AGGR_MAX:    return("MAX");
         case AGGR_HIGH:   return("HIGH");
         case AGGR_NORMAL: return("NORMAL");
         default:          return("DEFENSIVE");
        }
     }
  };

//==================================================================
//  10. C_AdaptiveHedge -- probabilistic risk compression (defense)
//     activation: (a) net notional exposure > E_threshold, or
//                 (b) accelerating drawdown velocity DDv where
//                     DDv = dEquityLoss/dt_sec x (1 + MarginUsed/Equity)
//     mechanism : V_hedge = clip( (E_toxic x ATR_H1/ATR_D1) x K_aggression,
//                                 min = 0, max = 0.9 x E_toxic )
//                 K_aggression = 0.4 + (0.9-0.4) x LiquidityEdgeScore/100
//                 executed as micro-orders (passive first on thin books),
//                 then self-dissolved in InpHedgeSlicePct slices
//     metric    : HedgeEfficiency, hedge volume/age, recovery time
//==================================================================
class C_AdaptiveHedge
  {
private:
   bool              m_active;
   datetime          m_bornTime;
   double            m_bornLots;
   double            m_closedLots;
   int               m_slicesDone;
   int               m_hedgeSide;          // +1 long hedge, -1 short hedge

   datetime          m_lastDDSample;
   double            m_lastEquity;
   double            m_prevDDv;
   double            m_mainPeakLoss;
   datetime          m_lastLog;            // throttle for deferred-hedge notices

public:
                     C_AdaptiveHedge()
     {
      m_active=false; m_bornTime=0; m_bornLots=0.0; m_closedLots=0.0;
      m_slicesDone=0; m_hedgeSide=0;
      m_lastDDSample=0; m_lastEquity=0.0; m_prevDDv=0.0;
      m_mainPeakLoss=0.0; m_lastLog=0;
     }

   void              Init()
     {
      m_lastEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
      m_lastDDSample = TimeCurrent();
      m_prevDDv      = 0.0;
     }

   //--- money -> lots using a broker-exact SL price (OrderCalcProfit first)
   double            LotForMoney(const double money, const double atrH1, const int side, string &why)
     {
      why = "";
      if(money <= 0.0 || atrH1 <= 0.0 || side == 0) { why = "invalid hedge inputs"; return(0.0); }
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) { why = "no quote"; return(0.0); }
      double entry = (side > 0) ? tick.ask : tick.bid;
      if(entry <= 0.0) { why = "invalid quote"; return(0.0); }
      double slDist = NormPrice(InpHedgeStopATR_H1*atrH1);
      double minStop= StopsDistance();
      if(slDist < minStop) slDist = minStop;
      if(slDist <= 0.0) { why = "invalid stop distance"; return(0.0); }
      double slPrice = NormPrice((side > 0) ? entry - slDist : entry + slDist);
      if(slPrice <= 0.0) { why = "invalid stop price"; return(0.0); }

      ENUM_ORDER_TYPE ot = (side > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double lossPerLot = 0.0, p = 0.0;
      if(OrderCalcProfit(ot, _Symbol, 1.0, entry, slPrice, p) && p < 0.0) lossPerLot = -p;
      if(lossPerLot <= 1.0e-9 && g_tickSize > 0.0)
        {
         double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         if(tv > 0.0) lossPerLot = (slDist/g_tickSize)*tv;
        }
      if(lossPerLot <= 1.0e-9) { why = "cannot price the hedge stop"; return(0.0); }
      bool ok=false;
      double v = NormVolume(money/lossPerLot, ok);
      if(!ok || v <= 0.0)
        {
         why = StringFormat("hedge volume for %.2f USD rejected by the volume grid (min %.2f)",
                            money, g_volMin);
         return(0.0);
        }
      return(v);
     }

   //--- DDv with the mandated margin amplifier:
   //    DDv = dEquityLoss/dt_sec x (1 + MarginUsed/Equity)
   double            DrawdownVelocity(const double equityPrev, const double equityNow,
                                      const double marginUsed, const double dtSec) const
     {
      if(dtSec <= 0.0) return(0.0);
      double lossRate = MathMax(0.0, (equityPrev - equityNow)/dtSec);
      double amp = 1.0 + SafeDiv(MathMax(marginUsed,0.0), MathMax(equityNow,1.0e-9), 0.0);
      return(lossRate*amp);
     }

   //--- exact spec formula, injectable => deterministically testable
   double            HedgeVolumeUSD(const double eToxicUSD, const double atrH1, const double atrD1,
                                    const double edge) const
     {
      double ratio = SafeDiv(atrH1, atrD1, 1.0);
      ratio = ClampD(ratio, 0.05, 5.0);                        // guard degenerate ATR pairs
      double kAggr = ClampD(0.40 + (0.90 - 0.40)*ClampD(edge,0.0,100.0)/100.0, 0.40, 0.90);
      double raw   = eToxicUSD*ratio*kAggr;
      double cap   = 0.90*eToxicUSD;
      return(ClampD(raw, 0.0, MathMax(cap,0.0)));
     }

   void              Update(C_OrderBookScanner &sc, C_HFTExecution &ex,
                            C_Telemetry &tl, C_SafetyManager &sf)
     {
      datetime now = TimeCurrent();
      double   equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double   margin = AccountInfoDouble(ACCOUNT_MARGIN);

      double atrH1 = AtrValue(g_hATR_H1);
      double atrD1 = AtrValue(g_hATR_D1);
      double netLots = ex.NetLots();
      double netNotional = ex.NetNotionalUSD();
      double mainPnL = MainClusterPnL(ex);

      if(!m_active)
        {
         //--- one DDv sample per second keeps the derivative meaningful
         double ddv = 0.0;
         if(m_lastDDSample != 0 && (int)(now - m_lastDDSample) >= 1)
           {
            ddv = DrawdownVelocity(m_lastEquity, equity, margin, (double)(now - m_lastDDSample));
            m_lastDDSample = now;
            m_lastEquity   = equity;
           }
         if(mainPnL < 0.0 && -mainPnL > m_mainPeakLoss) m_mainPeakLoss = -mainPnL;

         bool trigA = (InpE_ThresholdUSD > 0.0 && netNotional > InpE_ThresholdUSD);
         bool trigB = (InpDDvThresholdPerSec > 0.0 && ddv > InpDDvThresholdPerSec) ||
                      (InpDDvAccelFactor > 0.0 && m_prevDDv > 1.0e-9 &&
                       ddv > InpDDvAccelFactor*m_prevDDv && ddv > 0.5*InpDDvThresholdPerSec);
         m_prevDDv = ddv;
         if(!trigA && !trigB) return;
         if(netLots == 0.0)  return;                          // nothing to compress

         string why = "";
         if(!sf.TradePermitted(why)) { LogThrottled("hedge blocked: "+why); return; }
         if(!sf.MarginOK(why))       { LogThrottled("hedge blocked: "+why); return; }
         if(atrH1 <= 0.0 || atrD1 <= 0.0)
           { LogThrottled("hedge deferred: ATR H1/D1 not ready"); return; }

         double eToxic = netNotional;
         double vUSD   = HedgeVolumeUSD(eToxic, atrH1, atrD1, sc.Edge());
         int    side   = (netLots > 0.0) ? -1 : 1;             // opposite the toxic exposure
         double lots   = LotForMoney(vUSD, atrH1, side, why);
         if(lots <= 0.0) { LogThrottled("hedge skipped: "+why); return; }
         if(!sf.VolumeRoomOK(lots, why)) { LogThrottled("hedge blocked: "+why); return; }

         int sent = ExecuteHedge(side, lots, sc, ex);
         if(sent <= 0) { LogThrottled("hedge execution sent 0 micro-orders"); return; }

         m_active     = true;
         m_bornTime   = now;
         m_bornLots   = lots;
         m_closedLots = 0.0;
         m_slicesDone = 0;
         m_hedgeSide  = side;
         m_mainPeakLoss = MathMax(m_mainPeakLoss, -mainPnL);
         ex.ArmHedgeStops(atrH1);
         PrintFormat("HEDGE OPEN: side=%+d target=%.2f lots E_toxic=%.2fUSD ATR(H1/D1)=%.5f/%.5f K=%.2f V=%.2fUSD trigger=%s%s",
                     side, lots, eToxic, atrH1, atrD1,
                     ClampD(0.40+0.50*sc.Edge()/100.0, 0.40, 0.90), vUSD,
                     trigA ? "E>threshold" : "", trigB ? " DDv" : "");
         return;
        }

      //==================== ACTIVE: self-dissolve ====================
      double ageMin = (double)(now - m_bornTime)/60.0;
      if(InpHedgeMaxAgeMin > 0.0 && ageMin >= InpHedgeMaxAgeMin)
        {
         PrintFormat("HEDGE DISSOLVE (time stop): age %.1f min >= %.1f min", ageMin, InpHedgeMaxAgeMin);
         CloseAllHedge(ex);
         return;
        }
      if(mainPnL >= 0.0)
        {
         Print("HEDGE DISSOLVE (main cluster back to non-negative P&L)");
         CloseAllHedge(ex);
         return;
        }
      //--- signal flip: DOM/tick evidence now points WITH the toxic side,
      //    i.e. the hedge is fighting the fresh microstructure -> release it
      int toxicSide = (netLots > 0.0) ? 1 : -1;
      if(sc.Edge() >= 55.0 && sc.Dir() == toxicSide)
        {
         PrintFormat("HEDGE DISSOLVE (LiquidityEdgeScore flipped: edge %.1f dir %+d with the cluster)",
                     sc.Edge(), sc.Dir());
         CloseAllHedge(ex);
         return;
        }
      //--- loss-decay slices: release InpHedgeSlicePct per qualifying step
      if(m_mainPeakLoss > 0.0 && InpHedgeDecayReleasePct > 0.0)
        {
         double decayPct = (m_mainPeakLoss - (-mainPnL))/m_mainPeakLoss*100.0;
         double needPct  = (double)(m_slicesDone+1)*ClampD((double)InpHedgeSlicePct,1.0,100.0);
         if(decayPct >= needPct) CloseOneSlice(ex, decayPct, needPct);
        }
     }

   //--- hedge execution through the HFT layer (passive first when required)
   int               ExecuteHedge(const int side, const double lots,
                                  C_OrderBookScanner &sc, C_HFTExecution &ex)
     {
      int sent = 0;
      bool passive = InpHedgeUsePassive && sc.PreferPassive();
      if(passive)
        {
         double pegVol = NormalizeDouble(lots*0.50, VolumeDigits());
         if(ex.PlacePassivePeg(side, pegVol, true)) sent++;
        }
      sent += ex.FireIOC(side, lots, true);
      return(sent);
     }

   double            MainClusterPnL(C_HFTExecution &ex)
     {
      double all = ex.FloatPnL();
      double hedge = HedgePnL();
      return(all - hedge);
     }
   double            HedgePnL()
     {
      CPositionInfo pi;
      double pnl=0.0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         if(!pi.SelectByIndex(i)) continue;
         if(pi.Symbol() != _Symbol) continue;
         if(pi.Magic() != InpMagicHedge) continue;
         pnl += pi.Profit() + pi.Swap();
        }
      return(pnl);
     }
   double            HedgeLots()
     {
      CPositionInfo pi;
      double v=0.0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         if(!pi.SelectByIndex(i)) continue;
         if(pi.Symbol() != _Symbol) continue;
         if(pi.Magic() != InpMagicHedge) continue;
         v += pi.Volume();
        }
      return(v);
     }

   void              CloseOneSlice(C_HFTExecution &ex, const double decayPct, const double needPct)
     {
      double slicePct = ClampD((double)InpHedgeSlicePct,1.0,100.0)/100.0;
      double target   = m_bornLots*slicePct;
      if(target <= 0.0) return;
      int side = (m_hedgeSide > 0) ? 1 : -1;                 // close the hedge's own side
      if(!ex.ClosePartialSideMagic(InpMagicHedge, side, target))
        {
         LogThrottled(StringFormat("hedge slice close failed (decay %.1f%% >= %.1f%%)", decayPct, needPct));
         return;
        }
      m_slicesDone++;
      m_closedLots += target;
      PrintFormat("HEDGE SLICE %d closed: %.2f lots (loss decay %.1f%% >= %.1f%%)",
                  m_slicesDone, target, decayPct, needPct);
      if(HedgeLots() <= g_volMin*0.5) Finalize("slices exhausted");
     }

   void              CloseAllHedge(C_HFTExecution &ex)
     {
      double v = HedgeLots();
      if(v > 0.0)
        {
         int side = (m_hedgeSide > 0) ? 1 : -1;
         ex.ClosePartialSideMagic(InpMagicHedge, side, v + g_volStep);
        }
      Finalize("full dissolve");
     }

   void              Finalize(const string reason)
     {
      PrintFormat("HEDGE CLOSED (%s): born %.2f lots, slices %d, age %.1f min, efficiency %.1f%%",
                  reason, m_bornLots, m_slicesDone,
                  (double)(TimeCurrent()-m_bornTime)/60.0,
                  g_telem.HedgeEfficiency()*100.0);
      m_active=false; m_bornTime=0; m_bornLots=0.0; m_closedLots=0.0;
      m_slicesDone=0; m_hedgeSide=0; m_mainPeakLoss=0.0; m_prevDDv=0.0;
     }

   void              LogThrottled(const string msg)
     {
      datetime now = TimeCurrent();
      if(m_lastLog != 0 && (int)(now - m_lastLog) < 30) return;
      m_lastLog = now;
      if(InpVerboseLog) Print("HEDGE: ", msg);
     }

   bool              Active()     const { return(m_active);     }
   double            BornLots()   const { return(m_bornLots);   }
   int               Slices()     const { return(m_slicesDone); }
   double            AgeMinutes() const
     {
      return(m_bornTime>0 ? (double)(TimeCurrent()-m_bornTime)/60.0 : 0.0);
     }
  };

//==================================================================
//  11. ORCHESTRATION
//==================================================================
void  SelfTest(const int mode);           // prototype: body follows the classes
void  NoteGate(const string why);
void  TryEntry(const int dir, double intendedVolume, const bool ignite);
void  MakeDecision();
void  UpdateDashboard();

//---------------------------------------------------------------
//  GATE REASON SURFACE
//  activation: every blocked entry attempt
//  mechanism : the reason is stored for the chart overlay and logged at
//              most once per 30s (a silent "no trade" is indistinguishable
//              from a broken install, so it is never silent)
//  metric    : last block reason, printed with the full gate snapshot
//---------------------------------------------------------------
void NoteGate(const string why)
  {
   g_lastGateReason = why;
   static datetime lastGateLog = 0;
   datetime nowT = TimeCurrent();
   if(lastGateLog != 0 && (int)(nowT - lastGateLog) < 30) return;
   lastGateLog = nowT;
   PrintFormat("ENTRY blocked: %s | edge=%.1f (min %.1f) mode=%s score=%.1f dir=%+d book=%d spread=%.1fpts pegs=%d hedged=%d",
               why, g_scan.Edge(), InpMinEdgeToTrade, g_bal.ModeName(), g_bal.Score(),
               g_scan.Dir(), (int)g_scan.BookUsable(), g_safe.SpreadPoints(),
               g_exec.PegsResting(), (int)g_hedge.Active());
  }

//---------------------------------------------------------------
//  ENTRY DECISION
//  activation: score gate passed (or StartupIgnite) and all safety
//              gates green
//  mechanism : the intended volume is split by PassiveRatio into one
//              non-marketable midpoint peg and an IOC micro-bullet
//              batch (client-side iceberg, N in [3..9], VOLUME_STEP
//              aligned, sub-minimum slices rejected never bumped)
//  metric    : sent micro-orders, requested vs filled volume
//---------------------------------------------------------------
void TryEntry(const int dir, double intendedVolume, const bool ignite)
  {
   if(dir == 0 || intendedVolume <= 0.0) return;
   bool ok=false;
   double T = NormVolume(intendedVolume, ok);
   if(!ok || T <= 0.0)
     {
      PrintFormat("ENTRY REJECT: intended %.5f lots not broker-legal (min %.2f step %.2f) - not bumped",
                  intendedVolume, g_volMin, g_volStep);
      return;
     }
   //--- money-level brakes: risk budget (needs a stop) and margin capacity.
   //    Both can only SHRINK or REFUSE the entry, never enlarge it.
   MqlTick tkRef;
   double refPx = 0.0;
   if(SymbolInfoTick(_Symbol, tkRef)) refPx = (dir > 0) ? tkRef.ask : tkRef.bid;
   if(refPx > 0.0)
     {
      string whyR = "";
      double capped = g_safe.RiskCappedVolume(T, dir, refPx, whyR);
      if(capped <= 0.0) { NoteGate(whyR); return; }
      T = capped;
     }
   string whyM = "";
   if(!g_safe.MarginCapacityOK(T, dir, whyM)) { NoteGate(whyM); return; }

   double passiveRatio = g_bal.PassiveRatio();
   //--- both sleeves go through NormVolume(): VOLUME_STEP aligned and
   //    REJECTED (never bumped) when below SYMBOL_VOLUME_MIN
   bool okP=false, okI=false;
   double pegVol = (passiveRatio > 0.0) ? NormVolume(T*passiveRatio, okP) : 0.0;
   if(!okP) pegVol = 0.0;                          // sub-minimum passive slice: dropped, not bumped
   double iocVol = NormVolume(NormalizeDouble(T - pegVol, VolumeDigits()), okI);
   if(!okI)
     {
      //--- the aggressive remainder would be sub-minimum: drop the passive
      //    sleeve instead of leaving a batch that can only rest passively
      //    (the engine must be able to take liquidity, not only quote it)
      pegVol = 0.0;
      iocVol = T;
     }

   int sent = 0;
   if(pegVol >= g_volMin - 1.0e-9)
     {
      if(g_exec.PlacePassivePeg(dir, pegVol, false)) sent++;
      else iocVol = T;                                     // peg refused -> all aggressive
     }
   //--- StartupIgnite is the anti-idle bootstrap: it snipes with a real
   //    market order even in DEFENSIVE mode (it is a one-time 0.1..0.3x
   //    batch and it is what makes the EA act on the first qualifying tick)
   if(iocVol >= g_volMin - 1.0e-9 && (ignite || g_bal.Mode() != AGGR_DEFENSIVE))
      sent += g_exec.FireIOC(dir, iocVol, false);

   if(sent > 0)
     {
      g_lastDecision = TimeCurrent();
      g_lastGateReason = "none - entry sent";
      if(ignite) g_bal.ConsumeIgnite();
      PrintFormat("ENTRY: dir=%+d T=%.2f peg=%.2f ioc=%.2f passive=%.0f%% mode=%s score=%.1f ignite=%d sent=%d",
                  dir, T, pegVol, iocVol, passiveRatio*100.0, g_bal.ModeName(),
                  g_bal.Score(), (int)ignite, sent);
     }
   else
     {
      g_lastGateReason = "micro-order refused by broker volume grid / peg cap";
      PrintFormat("ENTRY: no micro-order accepted (dir=%+d T=%.2f) - volume grid or peg cap refused", dir, T);
     }
  }

//---------------------------------------------------------------
//  PER-TICK DECISION SEQUENCE
//---------------------------------------------------------------
void MakeDecision()
  {
   double edge = g_scan.Edge();
   int    dir  = g_scan.Dir();

   //--- StartupIgnite: one bootstrap batch even at a low score
   if(g_bal.UpdateIgnite(g_exec.OwnTrades()) && dir != 0)
     {
      string why="";
      if(g_safe.AllowNewEntry(why))
        {
         double frac = ClampD(InpBootstrapVolumeFrac, 0.10, 0.30);
         double vol  = InpTargetVolume*frac;
         if(g_telem.Throttled()) vol *= ClampD((double)InpThrottleFactorPct,0.0,100.0)/100.0;
         if(!g_safe.VolumeRoomOK(vol, why))
           {
            NoteGate("IGNITE blocked: "+why);
            return;
           }
         PrintFormat("IGNITE: bootstrap micro-batch dir=%+d vol=%.2f (%.0f%% of target) score=%.1f",
                     dir, vol, frac*100.0, g_bal.Score());
         TryEntry(dir, vol, true);
         return;
        }
      NoteGate("IGNITE deferred: "+why);
     }

   //--- every block is explained (overlay + throttled log)
   if(g_bal.Mode() == AGGR_DEFENSIVE)
     {
      NoteGate(StringFormat("score %.1f < 40 -> DEFENSIVE (no new entries by contract)", g_bal.Score()));
      return;
     }
   if(edge < InpMinEdgeToTrade)                             // permissive, tunable gate
     {
      NoteGate(StringFormat("edge %.1f < %.1f (InpMinEdgeToTrade)", edge, InpMinEdgeToTrade));
      return;
     }
   if(dir == 0)
     {
      NoteGate("no directional signal yet (tick rule / DOM neutral)");
      return;
     }

   int minGap = MathMax(InpMinSecBetweenBatches, 1);
   if(g_lastDecision != 0 && (int)(TimeCurrent() - g_lastDecision) < minGap) return;

   string why2="";
   if(!g_safe.AllowNewEntry(why2))
     {
      NoteGate(why2);
      return;
     }
   double vol = InpTargetVolume*g_bal.VolumeScale();       // aggression clamp
   if(vol < g_volMin) vol = g_volMin;                      // never shrink below one legal lot
   if(g_telem.Throttled()) vol *= ClampD((double)InpThrottleFactorPct,0.0,100.0)/100.0;
   if(!g_safe.VolumeRoomOK(vol, why2))
     {
      NoteGate(why2);
      return;
     }
   TryEntry(dir, vol, false);
  }

//---------------------------------------------------------------
//  LIGHTWEIGHT CHART OVERLAY
//---------------------------------------------------------------
void UpdateDashboard()
  {
   datetime now = TimeCurrent();
   if(g_lastCommentSec >= 0 && (int)(now - (datetime)g_lastCommentSec) < MathMax(InpTelemetryPeriodSec,1))
      return;
   g_lastCommentSec = (int)now;
   g_exec.RefreshPositions(true);
   string txt = "";
   txt += StringFormat("XAUUSD HFT-LEGAL | mode=%s score=%.1f | edge=%.1f dir=%+d thin=%d passive=%.0f%%\n",
                       g_bal.ModeName(), g_bal.Score(), g_scan.Edge(), g_scan.Dir(),
                       (int)g_scan.Thin(), g_bal.PassiveRatio()*100.0);
   txt += StringFormat("book: usable=%d levels=%d imb=%+.2f depthR=%.2f | vel=%.1f/s rule=%+.2f sprdMom=%+.2f\n",
                       (int)g_scan.BookUsable(), g_scan.Levels(), g_scan.Imbalance(),
                       g_scan.DepthRatio(), g_scan.TickVelocity(), g_scan.TickRule(), g_scan.SpreadMom());
   txt += StringFormat("pos: net=%+.2f lots gross=%.2f pnl=%.2f | hedge=%s born=%.2f slices=%d age=%.1fm\n",
                       g_exec.NetLots(), g_exec.GrossLots(), g_exec.FloatPnL(),
                       g_hedge.Active() ? "ACTIVE" : "flat", g_hedge.BornLots(),
                       g_hedge.Slices(), g_hedge.AgeMinutes());
   txt += StringFormat("exec: avg=%.0fms p95=%.0fms pegs=%d sent=%I64u | %s\n",
                       g_telem.AvgLatency(), g_telem.P95Latency(), g_exec.PegsResting(),
                       g_telem.SentOrders(), g_telem.SummaryLine());
   txt += StringFormat("safe: spread=%.1fpts marginFree=%.2f marginHealth=%.2f dayVol=%.2f/%.2f rollover=%d winRate=%.2f (%d deals, last %s)\n",
                       g_safe.SpreadPoints(), g_safe.MarginFreePct(), g_safe.MarginHealth(),
                       g_dayVolume, InpMaxDailyVolume,
                       (int)g_safe.InRollover(), g_telem.SessionWinRate(), g_telem.DealSamples(),
                       g_telem.LastDealTime() > 0.0
                          ? TimeToString((datetime)(long)g_telem.LastDealTime(), TIME_DATE|TIME_MINUTES)
                          : "n/a");
   double eqD = AccountInfoDouble(ACCOUNT_EQUITY);
   double mgD = AccountInfoDouble(ACCOUNT_MARGIN);
   txt += StringFormat("risk: SL=%s TP=%s | margin used %.1f%% of the %.0f%% cap | 1 lot XAUUSD = %.0f oz\n",
                       g_slPoints > 0.0 ? (DoubleToString(g_slPoints,0)+" pts") : "OFF (unbounded)",
                       g_tpPoints > 0.0 ? (DoubleToString(g_tpPoints,0)+" pts") : "OFF",
                       (eqD > 0.0) ? (mgD/eqD*100.0) : 0.0, InpMaxMarginUsePct, g_contractSize);
   string gateWhy="";
   bool   gateOpen = g_safe.AllowNewEntry(gateWhy);      // pure probe: reads state, no side effect
   txt += StringFormat("gate: %s | decisionBlock=%s\n",
                       gateOpen ? "OPEN - safety gates clear" : ("BLOCKED: "+gateWhy),
                       g_lastGateReason);
   Comment(txt);
  }

//---------------------------------------------------------------
//  SELF-TEST -- deterministic, market-independent verification of the
//  decision and compliance mathematics. Sends NO order and touches NO
//  live state except the telemetry placement counter.
//    A) mode 1 Micro-Impulse Stream  -> score/edge/mode/fill accounting
//    B) mode 2 Fast Adverse Shock    -> hedge formula + clip bounds
//    C) mode 3 Thin Book Sniper      -> passive fallback + cancel rate
//---------------------------------------------------------------
void SelfTest(const int mode)
  {
   if(mode <= 0 || mode > 3) return;
   Print("==================================================================");
   PrintFormat("SELFTEST mode=%d (%s) -- deterministic, no orders are sent", mode,
               mode==1 ? "A Micro-Impulse Stream" : (mode==2 ? "B Fast Adverse Shock" : "C Thin Book Sniper"));

   if(mode == 1)
     {
      //--- A: many small impulses -> strong tick rule, thick usable book
      g_scan.InjectBook(0.45, 2.00, true);
      g_scan.InjectTickFlow(30.0, 0.60, -0.10);
      int dirA = 0;
      double edgeA = g_scan.EdgeFromInputs(0.45, 2.00, 30.0, 0.60, -0.10, true, dirA);
      double healthA = 80.0;
      double scoreA = g_bal.ScoreFromInputs(edgeA, healthA, 0.90, 0.55);
      ENUM_AGGR_MODE modeA = g_bal.ModeFromScore(scoreA);
      double passiveA = g_bal.PassiveRatioFromInputs(modeA, false, 0.0);
      PrintFormat("SELFTEST A: edge expected>=55 actual=%.1f | dir expected=+1 actual=%+d", edgeA, dirA);
      PrintFormat("SELFTEST A: score expected>=60 actual=%.1f | mode=%s passiveRatio=%.2f (expected<=0.40)",
                  scoreA, EnumToString(modeA), passiveA);

      //--- fill accounting: 3 requests, 2 filled => MicroFillRate = 2/3
      g_telem.NotePlacement(); g_telem.NoteVolume(0.01, 0.01, false); g_telem.NoteIOC(true);
      g_telem.NotePlacement(); g_telem.NoteVolume(0.01, 0.01, false); g_telem.NoteIOC(true);
      g_telem.NotePlacement(); g_telem.NoteVolume(0.01, 0.00, false); g_telem.NoteIOC(false);
      double mfr = g_telem.MicroFillRate();
      PrintFormat("SELFTEST A: MicroFillRate expected=0.6667 actual=%.4f | IOC_FillRatio=%.4f",
                  mfr, g_telem.IOCFillRatio());
      bool passA = (edgeA >= 55.0 && dirA == 1 && scoreA >= 60.0 &&
                    modeA != AGGR_DEFENSIVE && mfr >= 0.60 - 1.0e-9 && passiveA <= 0.40 + 1.0e-9);
      Print("SELFTEST A RESULT: ", passA ? "PASS" : "REVIEW");
     }

   if(mode == 2)
     {
      //--- B: 200-point adverse shock -> verify the compression formula
      double atrH1 = 2.50, atrD1 = 12.00, eToxic = 60000.0, edgeB = 20.0;
      double ratio = ClampD(SafeDiv(atrH1, atrD1, 1.0), 0.05, 5.0);
      double kA    = ClampD(0.40 + 0.50*edgeB/100.0, 0.40, 0.90);
      double vUSD  = g_hedge.HedgeVolumeUSD(eToxic, atrH1, atrD1, edgeB);
      double cap   = 0.90*eToxic;
      PrintFormat("SELFTEST B: V_hedge expected=%.2f actual=%.2f USD (E_toxic=%.0f ratio=%.4f K=%.2f cap=%.0f)",
                  eToxic*ratio*kA, vUSD, eToxic, ratio, kA, cap);
      double vClip = g_hedge.HedgeVolumeUSD(100000.0, 10.0, 5.0, 100.0);
      PrintFormat("SELFTEST B: clip-at-cap expected=%.2f actual=%.2f", 0.90*100000.0, vClip);
      double ddv = g_hedge.DrawdownVelocity(100000.0, 99000.0, 20000.0, 1.0);
      PrintFormat("SELFTEST B: DDv expected=1200.00 actual=%.2f (lossRate=1000/s, marginAmp=1.2)", ddv);
      bool passB = (MathAbs(vUSD - eToxic*ratio*kA) < 1.0 &&
                    MathAbs(vClip - 0.90*100000.0) < 1.0 &&
                    MathAbs(ddv - 1200.0) < 1.0);
      Print("SELFTEST B RESULT: ", passB ? "PASS" : "REVIEW");
      Print("SELFTEST B NOTE: survival of a real 200-point shock requires a live/demo run; ");
      Print("               this static check verifies the compression mathematics only.");
     }

   if(mode == 3)
     {
      //--- C: sparse book -> passive pegging instead of aggressive tactics
      g_scan.InjectBook(0.00, 0.10, false);
      g_scan.InjectTickFlow(2.0, 0.00, 0.00);
      int dirC = 0;
      double edgeC = g_scan.EdgeFromInputs(0.00, 0.10, 2.0, 0.00, 0.00, false, dirC);
      bool prefC = g_scan.PreferPassiveFromInputs(false, 0.10, 0.00);
      ENUM_AGGR_MODE modeC = g_bal.ModeFromScore(30.0);
      double passiveC = g_bal.PassiveRatioFromInputs(modeC, prefC, 0.0);
      PrintFormat("SELFTEST C: preferPassive expected=1 actual=%d | passiveRatio=%.2f (expected>=0.70)",
                  (int)prefC, passiveC);
      //--- compliance: isolated window with 1 placement + 1 cancel => 1.00
      g_telem.ResetCounters();
      g_telem.NotePlacement();
      g_telem.NoteCancellation();
      double cr = g_telem.CancellationRate();
      PrintFormat("SELFTEST C: CancellationRate expected=1.00 actual=%.2f (threshold %.2f)",
                  cr, InpMaxCancellationRate);
      g_telem.RaiseFlag("SELFTEST-C synthetic cancellation-rate breach");
      bool passC = (prefC && passiveC >= 0.70 - 1.0e-9 && cr >= 1.0 - 1.0e-9 &&
                    g_telem.Flag() && edgeC < 55.0);
      Print("SELFTEST C RESULT: ", passC ? "PASS" : "REVIEW");
      Print("SELFTEST C: releasing the synthetic flag and clearing synthetic counters");
      g_telem.ReleaseShutdown();
      g_telem.ResetCounters();
      g_scan.ResetInjections();
     }
   Print("SELFTEST complete -- live trading state untouched");
   Print("==================================================================");
  }

//==================================================================
//  12. OnInit
//==================================================================
int OnInit()
  {
   Print("==================================================================");
   Print("XAUUSD_HFT_Legal v1.00 -- legal microstructure execution engine");
   Print("==================================================================");

   //--- symbol specification (runtime values always win over the anchors
   //    Digits=2 / TickSize=0.01 / VolumeStep=0.01)
   g_digits      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_volMin      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   g_contractSize= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_contractSize <= 0.0) g_contractSize = 100.0;        // XAUUSD: 100 oz per 1.00 lot
   g_fillFlags   = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if(g_digits <= 0)    g_digits  = 2;
   if(g_point <= 0.0)   g_point   = 0.01;
   if(g_tickSize <= 0.0)
     {
      g_tickSize = g_point;
      Print("INIT WARNING: SYMBOL_TRADE_TICK_SIZE unavailable -> falling back to POINT");
     }
   if(g_volMin  <= 0.0) g_volMin  = 0.01;
   if(g_volMax  <= 0.0) g_volMax  = 100.0;
   if(g_volStep <= 0.0) g_volStep = 0.01;

   //--- IOC is the requested policy; it is only used when the symbol
   //    advertises it. No unsupported filling mode is ever invented.
   if((g_fillFlags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_fillPolicy = ORDER_FILLING_IOC;
   else if((g_fillFlags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
     {
      g_fillPolicy = ORDER_FILLING_FOK;
      Print("INIT WARNING: IOC not advertised by this symbol -> FOK selected and logged");
     }
   else
     {
      g_fillPolicy = ORDER_FILLING_RETURN;
      Print("INIT WARNING: neither IOC nor FOK advertised -> RETURN policy selected and logged");
     }
   PrintFormat("INIT symbol spec: %s digits=%d point=%.5f tickSize=%.5f vol[min=%.2f max=%.2f step=%.2f] stops=%d freeze=%d fillFlags=%u policy=%s",
               _Symbol, g_digits, g_point, g_tickSize, g_volMin, g_volMax, g_volStep,
               (int)g_stopsLevel, (int)g_freezeLevel, g_fillFlags,
               EnumToString(g_fillPolicy));

   //--- input validation (inputs are read-only: fail init, never clamp silently)
   if(InpTargetVolume < g_volMin)
     {
      PrintFormat("INIT INPUT ERROR: InpTargetVolume %.2f < SYMBOL_VOLUME_MIN %.2f", InpTargetVolume, g_volMin);
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpBootstrapVolumeFrac < 0.10 || InpBootstrapVolumeFrac > 0.30)
     {
      Print("INIT INPUT ERROR: InpBootstrapVolumeFrac must lie in [0.10, 0.30]");
      return(INIT_PARAMETERS_INCORRECT);
     }
   double wSum = InpW_LiquidityEdge + InpW_ExecutionHealth + InpW_MarginFreePct + InpW_SessionWinRate;
   if(wSum <= 0.0)
     {
      Print("INIT INPUT ERROR: aggression weights must sum to > 0");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpHedgeSlicePct < 1 || InpHedgeSlicePct > 100)
     {
      Print("INIT INPUT ERROR: InpHedgeSlicePct must lie in [1, 100]");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMicroBullets < 3 || InpMicroBullets > 9)
      PrintFormat("INIT WARNING: InpMicroBullets %d outside [3..9] -> clamped at runtime",
                  (int)InpMicroBullets);
   if(InpMagicMain == InpMagicHedge)
     {
      Print("INIT INPUT ERROR: InpMagicMain and InpMagicHedge must differ (ownership isolation)");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- protective levels: a stop that the symbol cannot accept is reported
   //    and disabled instead of being sent and rejected by the server
   g_slPoints = InpStopLossPoints;
   g_tpPoints = InpTakeProfitPoints;
   double minStopPts = (double)g_stopsLevel + 1.0;
   if(g_slPoints > 0.0 && g_slPoints < minStopPts)
     {
      PrintFormat("INIT WARNING: InpStopLossPoints %.0f < stops level %d -> SL disabled (use >= %.0f points, or 0)",
                  g_slPoints, (int)g_stopsLevel, minStopPts);
      g_slPoints = 0.0;
     }
   if(g_tpPoints > 0.0 && g_tpPoints < minStopPts)
     {
      PrintFormat("INIT WARNING: InpTakeProfitPoints %.0f < stops level %d -> TP disabled (use >= %.0f points, or 0)",
                  g_tpPoints, (int)g_stopsLevel, minStopPts);
      g_tpPoints = 0.0;
     }

   //--- wiring, ATR handles, telemetry, DOM subscription
   g_exec.Init(g_telem);
   g_telem.OpenLog(InpCSVFileName);
   g_scan.Subscribe();

   ResetLastError();
   g_hATR_H1 = iATR(_Symbol, PERIOD_H1, 14);
   g_hATR_D1 = iATR(_Symbol, PERIOD_D1, 14);
   if(g_hATR_H1 == INVALID_HANDLE || g_hATR_D1 == INVALID_HANDLE)
     {
      PrintFormat("INIT FATAL: iATR handle creation failed err=%d", _LastError);
      return(INIT_FAILED);
     }

   MathSrand((int)(GetTickCount64() & 0x7FFFFFFF));
   g_safe.AnchorDay();
   g_hedge.Init();
   g_lastDecision = 0;
   g_igniteUsed   = false;
   g_lastCommentSec = -1;

   if(InpSelfTestMode > 0) SelfTest(InpSelfTestMode);

   if(!EventSetTimer(1))
     {
      PrintFormat("INIT WARNING: EventSetTimer failed err=%d -> maintenance runs on ticks only", _LastError);
     }

   g_ready = true;
   PrintFormat("INIT ready: bullets=%d target=%.2f maxLots=%.2f dailyVol=%.2f latencyThr=%dms cancelMax=%.2f layers/side=%d critMargin=%.0f%%",
               (int)ClampD((double)InpMicroBullets,3.0,9.0), InpTargetVolume, InpMaxTotalLots,
               InpMaxDailyVolume, (int)InpLatencyThresholdMs, InpMaxCancellationRate,
               (int)InpMaxOwnLayersPerSide, InpCriticalMarginLevel);
   //--- HONEST RISK LABEL: on XAUUSD 1.00 lot = g_contractSize ounces, so a
   //    0.01 lot position moves g_contractSize*0.01*0.01 = 0.01*contract USD
   //    per point. The engine is TOLD how much money one point costs, so the
   //    stop distance and the position size can be chosen for the account.
   if(g_slPoints > 0.0)
      PrintFormat("INIT RISK LABEL: SL=%.0f points (%.2f USD price distance). 0.01 lot XAUUSD loses ~%.2f USD at that stop; 1.00 lot loses ~%.2f USD.",
                  g_slPoints, g_slPoints*g_point, g_slPoints*g_point*g_contractSize*0.01,
                  g_slPoints*g_point*g_contractSize);
   else
      PrintFormat("INIT RISK WARNING: no stop loss attached (InpStopLossPoints=0). Losses are bounded only by InpMaxTotalLots=%.2f, InpMaxMarginUsePct=%.0f%% and the hedge. 1.00 lot XAUUSD loses ~%.2f USD per 1.00 price move.",
                  InpMaxTotalLots, InpMaxMarginUsePct, g_contractSize);
   PrintFormat("INIT CAPACITY BRAKE: new entries stop when used margin would exceed %.0f%% of equity; the broker reports %.2f USD initial margin per 1.00 lot (%.2f USD per 0.01 lot).",
               InpMaxMarginUsePct, SymbolInfoDouble(_Symbol,SYMBOL_MARGIN_INITIAL),
               SymbolInfoDouble(_Symbol,SYMBOL_MARGIN_INITIAL)*0.01);
   if(MQLInfoInteger(MQL_TESTER))
     {
      Print("INIT NOTE: inside the Strategy Tester OrderSendAsync behaves like OrderSend,");
      Print("           so ExecutionTime_ms / P95 latency are only meaningful on a live feed.");
     }
   return(INIT_SUCCEEDED);
  }

//==================================================================
//  13. OnDeinit -- release every resource
//==================================================================
void OnDeinit(const int reason)
  {
   g_ready = false;
   EventKillTimer();
   g_exec.CancelAllPegs("deinit");                 // never leave own quotes behind
   g_scan.Unsubscribe();
   if(g_hATR_H1 != INVALID_HANDLE) { IndicatorRelease(g_hATR_H1); g_hATR_H1 = INVALID_HANDLE; }
   if(g_hATR_D1 != INVALID_HANDLE) { IndicatorRelease(g_hATR_D1); g_hATR_D1 = INVALID_HANDLE; }
   Comment("");
   PrintFormat("DEINIT reason=%d | %s | net=%+.2f lots | hedge=%s | compliance flag=%s strikes=%I64u",
               reason, g_telem.SummaryLine(), g_exec.NetLots(),
               g_hedge.Active() ? "ACTIVE" : "flat",
               g_telem.Flag() ? g_telem.FlagReason() : "clear", g_telem.Strikes());
   g_telem.CloseLog();
  }

//==================================================================
//  14. OnTick
//==================================================================
void OnTick()
  {
   if(!g_ready) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.bid <= 0.0 || tick.ask <= 0.0) return;      // invalid/stale quote guard

   g_scan.OnQuote(tick);
   g_scan.OnBook(_Symbol);                             // refresh DOM if subscribed
   g_scan.Refresh();
   g_exec.RefreshPositions(false);

   g_bal.Compute(g_scan, g_exec, g_telem, g_safe);
   g_telem.UpdateDrawdownRecovery(g_exec.FloatPnL());
   g_hedge.Update(g_scan, g_exec, g_telem, g_safe);

   MakeDecision();
   UpdateDashboard();
  }

//==================================================================
//  15. OnTimer -- maintenance that must run even without ticks
//==================================================================
void OnTimer()
  {
   if(!g_ready) return;
   g_safe.AnchorDay();
   g_safe.AuditCompliance();
   g_exec.RepricePegs();
   g_exec.Sweep();
   g_exec.RefreshPositions(true);
   g_hedge.Update(g_scan, g_exec, g_telem, g_safe);
   g_telem.LogPeriodic();
   UpdateDashboard();
  }

//==================================================================
//  16. OnTradeTransaction -- async result handling (request id match)
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!g_ready) return;
   g_exec.OnTransaction(trans, request, result);
  }

//==================================================================
//  17. OnBookEvent -- DOM driven microstructure refresh
//==================================================================
void OnBookEvent(const string &symbol)
  {
   if(!g_ready) return;
   g_scan.OnBook(symbol);
  }
//+------------------------------------------------------------------+





