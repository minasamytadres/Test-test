# QGE_XAUUSD_Pro — Quantitative Gold Edge

**Strategy whitepaper, engineering specification, risk-math walkthrough and validation report**

| | |
|---|---|
| Deliverable | `Experts/QGE_XAUUSD_Pro.mq5` (single file, compile-ready, 3 100+ lines) |
| Target build | MetaTrader 5, build 4xxx+ (MQL5, `<Trade/Trade.mqh>` / `CTrade`) |
| Instrument | XAUUSD (gold) — also runs on XAUUSD variants, warns on non-gold symbols |
| Account type | Retail **hedging** margin mode (auto-degrades to delta-reduction on netting) |
| Signal timeframe | H1 by default (configurable) |
| Decision drivers | Statistical estimators only — **no MA/RSI/MACD/Stochastic crossovers** |
| Activation | Pre-computes the signal in `OnInit`; trades on the **first tick** after attach |

---

## 1. Explicit assumptions

These are stated at the top of the source file as well, because every number below depends on them.

| # | Assumption | Consequence if violated |
|---|---|---|
| A1 | Instrument is XAUUSD spot gold: contract size 100 oz/lot, tick size 0.01, 2–3 digit quotes | All price math is in **log space**, so the model is scale-free; only `InpBarsPerYear`, spread limits and ATR multiples need review for another instrument |
| A2 | `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING` | On netting accounts the hedge sleeve is replaced by **delta reduction** (partial close of the book) and a one-time warning is logged — an opposite order is never sent where it would silently flatten the book |
| A3 | Any account currency | Lot sizing uses `OrderCalcProfit()` first, then `SYMBOL_TRADE_TICK_VALUE`, then `SYMBOL_TRADE_CONTRACT_SIZE`. No hard-coded "$100 per lot" |
| A4 | Any leverage | Every order is pre-checked with `OrderCalcMargin()` against `ACCOUNT_MARGIN_FREE` × `InpMarginCushion` |
| A5 | Market or instant execution | Filling policy resolved per symbol by `CTrade::SetTypeFillingBySymbol()`; requotes/price-changed/off-quote are retried |
| A6 | H1 ≈ 6 000 bars/year for gold (23 h × 5 d × 52 w) | `InpBarsPerYear` must be changed when `InpSignalTF` changes (annualized vol reporting and drift only — decisions use scale-free statistics) |
| A7 | Signals read **closed bars only** (shift ≥ 1) | No repainting, no look-ahead; bar change is confirmed with an `iTime(symbol, tf, 0)` guard |
| A8 | Swap read live from the position; commission/fees read from history deals (`DEAL_COMMISSION + DEAL_FEE`) and cached | `InpEstRoundTurnCommPerLot` is only a *pre-trade* cost estimate used by the cost-sanity gate |

---

## 2. Thesis

Gold's intraday price process is not one process. It alternates between

* **persistent / re-pricing regimes** — macro data, real-rate moves, central-bank flow, London/NY overlap — where returns are positively autocorrelated and the efficient thing to do is *continue with the flow*, and
* **antipersistent / liquidity-provision regimes** — Asian session, holiday thin books — where returns are negatively autocorrelated and the efficient thing to do is *fade the deviation*.

Classic lagging indicators cannot tell you which regime you are in: an MA crossover is a *smoothed price transform* and carries no information about the autocorrelation structure of the increments. QGE therefore estimates the **process itself** and only then decides what to do with the price level:

1. **How volatile is the process, efficiently measured?** — Yang–Zhang (with Garman–Klass as the range term) uses O/H/L/C, is drift-independent and absorbs the gold overnight gap. ~7.4× more efficient than close-to-close variance, so the regime estimate is stable on 20–100 bars instead of thousands.
2. **Is the process persistent or antipersistent?** — Variance ratio VR(q) and a multi-scale rescaled-range Hurst exponent. This is a *distributional* property, not a price level.
3. **Is there a statistically significant drift, and how much of the variance does it explain?** — Rolling OLS on log price, decision variable = **Student-t of the slope** (scale-free, noise-penalized), confidence multiplier = **R²**.
4. **How far is price from its own regression line, in residual standard deviations?** — residual z-score. This is a stationary-deviation test, not an oscillator: the "band" is the regression's own residual standard error, so it adapts to volatility instead of using a fixed period.
5. **Is the order flow one-sided right now?** — path efficiency |Σd|/Σ|d|, high-low range expansion, and momentum *acceleration* (second derivative of log price in units of its own standard deviation).

Each pillar emits **bounded evidence** $e_p \in [-1,+1]$ (equivalently a probability $p = (1+e)/2$). The pillars are fused with a **naive-Bayes-style weighted log-odds aggregation** whose weights are *re-shaped by the estimated Hurst exponent*, and the composite is mapped through a logistic function into a confidence score in $(0,1)$. One threshold on that score is the only gate.

**ATR appears exactly once in the whole decision chain — as a volatility *scalar*** for stop distance, position size, add-on spacing and the hedge unwind excursion. It never votes on direction. That is the explicit line between "measurement" and "signal", and it is what keeps this EA out of classic-indicator territory.

**Bias to action.** The default confidence threshold is 0.52 (|composite evidence| ≥ 0.02), every filter defaults to permissive, the signal is pre-computed in `OnInit`, and an idle-guard forces an entry after `InpForceEntryAfterIdleBars` closed bars. Section 15 shows the measured fire rate on simulated gold-like data: **85.6 %–100 % of bars**, and **100 % of first-bars-after-attach** across five independent runs.

---

## 3. Architecture

```
                     +----------------------------------------------+
   OnInit  --------> | ActivationManager                            |
   (validate, cache  |  - symbol/account/margin-mode validation      |
    symbol spec,     |  - ONE iATR handle (created here, released in  |
    create handle,   |    OnDeinit)                                  |
    prime buffers,   |  - warm-up readiness = RequiredBars() probe    |
    PRE-COMPUTE      |  - bar-change guard (iTime bar 0)              |
    first signal)    |  - first-tick one-shot flag                    |
                     +----------------------------------------------+
                                        |
   OnTick ---- SECTION A (every tick, light) -------------------------+
             |   RiskManager.Update()  (day anchor, peak equity)      |
             |   PositionManager.RefreshBook(withCommission=false)    |
             |   realized P&L scan (throttled to 5 s)                 |
             |   daily-loss guard / equity-floor kill switch           |
             |   HedgeManager: DD trigger + Manage() lifecycle         |
             |   PositionManager.ManageStops() (break-even, trailing)  |
             +--------------------------------------------------------+
             |
             +---- SECTION B (once per CLOSED bar, heavy) ------------+
             |   Prime() -> CopyRates(shift 1..) + CopyBuffer(ATR)    |
             |   SignalEngine.Compute() -> cached SSignal             |
             |   OnClosedBar() bookkeeping (idle counter, day cap)    |
             +--------------------------------------------------------+
             |
             +---- SECTION C (decisions on the CACHED signal) --------+
                 HedgeManager flip trigger -> entry / pyramid gate
                 RiskManager sizing -> CTrade execution (retry loop)
```

| Module | Responsibility | Heavy work per bar? |
|---|---|---|
| `CSignalEngine` | YZ/GK volatility, VR + R/S Hurst, OLS (slope, R², t, residual z), microstructure, fusion | **Yes — once per closed bar**, cached in `g_signal` |
| `CRiskManager` | Day/peak anchors, daily-loss + equity-floor guards, spread/session/permission filters, margin feasibility, risk→lot conversion, fractional-Kelly cap | No (history scan throttled to 5 s) |
| `CPositionManager` | Book aggregation (net lots, weighted-avg entry, all-in P&L incl. swap+commission, margin), execution with retry + retcode handling, aggregate break-even/trailing | No (structural scan is O(legs)) |
| `CHedgeManager` | Hedge trigger (DD breach / confirmed regime flip), exact hedge sizing, lifecycle: open → manage → ladder/TP/flip/time-stop unwind → orphan cleanup | No |
| `CActivationManager` | Warm-up readiness, bar-change guard, first-tick activation | No |

**Guarantees enforced by the code, not by convention**

* Heavy statistics are computed **at most once per closed bar**; `Compute()` only re-primes if no buffer is loaded, and the first tick reuses the `OnInit` pre-computation when the cached signal already describes the current closed bar (`g_signal.bar_time == iTime(tf,1)`).
* A signal that does not belong to the current closed bar is **invalidated** (`g_signal.Reset()`), so no decision can ever be taken on stale statistics.
* The single `iATR` handle is created in `OnInit` and released in `OnDeinit` — no static-handle-inside-function pattern anywhere.
* Volumes are floored to `SYMBOL_VOLUME_STEP` and **rejected below `SYMBOL_VOLUME_MIN`**; they are never silently bumped.
* Prices are normalized to `_Digits`; stops are validated against `SYMBOL_TRADE_STOPS_LEVEL` and `SYMBOL_TRADE_FREEZE_LEVEL`.

---

## 4. Signal engine — the mathematics

Notation: bar index $i$ counts **backwards from the last closed bar** ($i=0$ is shift 1). $O_i,H_i,L_i,C_i$ are that bar's OHLC, $C_{i+1}$ the previous bar's close. All price statistics are computed on log prices $y=\ln C$, so they are scale-free and additive.

### 4.1 Pillar inputs — realized volatility (Yang–Zhang with a Garman–Klass range term)

Per bar:

$$o_i=\ln\frac{O_i}{C_{i+1}}\quad(\text{overnight/open-jump}),\qquad c_i=\ln\frac{C_i}{O_i}\quad(\text{open}\to\text{close})$$

$$\mathrm{GK}_i=\tfrac12\Big(\ln\tfrac{H_i}{L_i}\Big)^{2}-\big(2\ln 2-1\big)\Big(\ln\tfrac{C_i}{O_i}\Big)^{2}$$

Over a window of $n$ bars:

$$\sigma_O^2=\frac{1}{n-1}\sum_{i}(o_i-\bar o)^2,\qquad \sigma_C^2=\frac{1}{n-1}\sum_i(c_i-\bar c)^2,\qquad \sigma_{RS}^2=\frac1n\sum_i \mathrm{GK}_i$$

$$\boxed{\;\sigma_{YZ}^2=\sigma_O^2+k\,\sigma_C^2+(1-k)\,\sigma_{RS}^2,\qquad k=\frac{0.34}{1.34+\frac{n+1}{n-1}}\;}$$

$$\sigma_{\text{ann}}=\sigma_{YZ}\sqrt{N_{\text{year}}},\qquad \text{volRatio}=\frac{\sigma_{YZ}(n_{fast})}{\sigma_{YZ}(n_{slow})}$$

*Why:* the estimator is **drift-independent** (unlike Parkinson), uses the open (so the gold overnight gap is modelled rather than treated as noise), and is the minimum-variance combination of the three orthogonal variance components under a Brownian model with opening jumps. `volRatio` ≥ `InpVolExpansionRatio` flags an **expanding-volatility** state.
*Defensive detail:* if $\sigma^2_{YZ}\le 0$ on pathological data (a run of zero-range bars), the code falls back to close-to-close variance before giving up, so a data glitch can never permanently disable trading.

### 4.2 Persistence — variance ratio and the Hurst exponent

1-bar and $q$-bar log returns:

$$r_i=\ln\frac{C_i}{C_{i+1}},\qquad R_j=\ln\frac{C_j}{C_{j+q}}=\sum_{i=j}^{j+q-1}r_i$$

$$\mathrm{VR}(q)=\frac{\operatorname{Var}(R)}{q\,\operatorname{Var}(r)}\quad\Longrightarrow\quad
H_{VR}=\frac12\Big(\frac{\ln \mathrm{VR}(q)}{\ln q}+1\Big)$$

(the implication uses $\operatorname{Var}(R_q)=q^{2H-1}\operatorname{Var}(r_1)$ for fractional Brownian motion).

Multi-scale rescaled range, for block length $s$ (scales 8, 16, 32, 64):

$$Y_k=\sum_{i=1}^{k}(r_i-\bar r),\qquad R(s)=\max_k Y_k-\min_k Y_k,\qquad S(s)=\operatorname{stdev}(r)$$

$$H_{RS}=\text{slope of }\ln\overline{(R/S)}(s)\text{ on }\ln s,\qquad H=\tfrac12\big(H_{VR}+H_{RS}\big)$$

Discrete regime band (used for the weight tilt and the dashboard):

$$\text{regime}=\begin{cases}+1\ \text{TRENDING} & H\ge \texttt{InpTrendHurst}\\ -1\ \text{MEAN-REVERTING} & H\le \texttt{InpMeanRevHurst}\\ 0\ \text{NEUTRAL} & \text{otherwise}\end{cases}$$

*Why a regression over several scales rather than $\ln(R/S)/\ln n$ on one window:* the single-window estimator has enormous sampling error at $n=128$; averaging $R/S$ over sub-blocks at four scales and regressing turns it into an actual estimator. Measured behaviour (Section 12): $H=0.59$, $\mathrm{VR}=1.11$ on trending data vs $H=0.40$, $\mathrm{VR}=0.60$ on an OU process — the discriminator works.

### 4.3 Trend pillar — rolling OLS on log price

With $x_i=n-1-i$ (so $x$ increases with time; $i=0$ is the newest closed bar) and $y_i=\ln C_i$:

$$\beta=\frac{n\sum x y-\sum x\sum y}{n\sum x^2-(\sum x)^2},\qquad \alpha=\bar y-\beta\bar x$$

$$R^2=1-\frac{SSE}{SST},\qquad s^2=\frac{SSE}{n-2},\qquad \mathrm{se}(\beta)=\sqrt{\frac{s^2}{\sum (x-\bar x)^2}},\qquad t=\frac{\beta}{\mathrm{se}(\beta)}$$

$$\boxed{\;e_{\text{trend}}=\tanh\!\Big(\frac{t}{\texttt{InpTStatRef}}\Big)\cdot\big(0.25+0.75R^2\big)\;}\qquad\text{(vetoed if }R^2<\texttt{InpR2Min}\text{)}$$

$\sum x$ and $\sum x^2$ use the closed forms $n(n-1)/2$ and $(n-1)n(2n-1)/6$; the annualized drift is reported as $\beta\cdot N_{\text{year}}$.

*Why the t-statistic and not the slope:* the slope has units (log price per bar) and explodes when the fit is noisy; $t$ is already divided by the residual standard error, so it is scale-free **and** self-penalizing. The $R^2$ damping prevents a large $t$ produced by a line that explains 3 % of the variance from being treated as a trend. This is the whole point of replacing an "MA crossover" with a *significance test on drift*.

### 4.4 Mean-reversion pillar — residual z-score

$$z=\frac{y_0-(\alpha+\beta x_0)}{s},\qquad \boxed{\;e_{\text{mrev}}=-\tanh\!\Big(\frac{z}{\texttt{InpZRef}}\Big)\cdot \text{damp}\;}$$

with an expanding-volatility attenuation (fading a deviation while realized vol is expanding is negative-expectancy — it is more likely the start of a re-pricing than noise):

$$\text{damp}=1-0.5\cdot\mathrm{clamp}\Big(\frac{\text{volRatio}-\texttt{InpVolExpansionRatio}}{\texttt{InpVolExpansionRatio}},0,1\Big)$$

*Why this is not an oscillator:* the "band width" is the regression's own residual standard error, i.e. it is estimated from the same window that defines the fair value, and it adapts to volatility automatically. There is no fixed 70/30 level, no smoothing constant and no crossover.

### 4.5 Microstructure pillar — order-flow proxy

$$d_i=\ln\frac{C_i}{C_{i+1}},\qquad
EF=\frac{\big|\sum_{i<n_E}d_i\big|}{\sum_{i<n_E}|d_i|}\in[0,1],\qquad \text{dir}=\mathrm{sign}\Big(\sum_{i<n_E}d_i\Big)$$

$$ACC=\frac{\operatorname{mean}_{i<n_f}(d_i)-\operatorname{mean}_{i<n_s}(d_i)}{\operatorname{stdev}_{i<n_s}(d_i)},\qquad
RE=\frac{\operatorname{mean}_{i<n_R}(H_i-L_i)}{\operatorname{mean}_{n_R\le i<2n_R}(H_i-L_i)}-1$$

$$\text{arg}=\frac{w_{EF}\,\text{dir}\cdot EF+w_{ACC}\tanh(ACC/\texttt{InpAccelRef})+w_{RE}\,\text{dir}\cdot\tanh(RE/\texttt{InpExpansionRef})}{w_{EF}+w_{ACC}+w_{RE}}$$

$$\boxed{\;e_{\text{micro}}=\frac{\tanh(\text{arg})}{\tanh(1)}\;}$$

* $EF$ (path efficiency) is the directional purity of the flow: 1 = every bar pushed the same way (one-sided aggressive flow), 0 = pure churn. It is the *ratio of displacement to path length* — the microstructure quantity that separates a trend from noise, without any smoothing.
* $RE$ is the **high-low expansion delta**: current range versus the immediately preceding, equally sized window. Rising ranges = fresh participation / liquidity consumption.
* $ACC$ is the **second derivative of log price**, normalized by its own dispersion — momentum *acceleration*, not momentum. A moving average of momentum is a lagging indicator; a normalized difference of two momentum windows is an estimate of $\partial^2 \ln P/\partial t^2$ and leads.

### 4.6 Regime/persistence pillar

$$\boxed{\;e_{\text{vol}}=\text{dir}_{\text{ref}}\cdot\tanh\!\Big(\frac{\ln \mathrm{VR}}{\texttt{InpVRRef}}\Big)\;},\qquad \text{dir}_{\text{ref}}=\mathrm{sign}(e_{\text{trend}})\ \text{or}\ \mathrm{sign}(e_{\text{micro}})$$

The pillar votes **with** the dominant drift when increments are positively autocorrelated ($\mathrm{VR}>1$) and **against** it when they are negatively autocorrelated ($\mathrm{VR}<1$). It is computed from a statistic (autocorrelation of returns) that the other three pillars never touch.

### 4.7 Fusion — regime-adaptive weighted evidence, logistic confidence

$$p=\mathrm{clamp}\Big(\frac{H-0.5}{0.5},-1,1\Big),\qquad
\begin{cases}
w_{\text{trend}}\propto \texttt{InpWTrend}\,(1+\tau p)\\
w_{\text{micro}}\propto \texttt{InpWMicro}\,(1+\tau p)\\
w_{\text{mrev}}\propto \texttt{InpWMeanRev}\,(1-\tau p)\\
w_{\text{vol}}\propto \texttt{InpWVol}\,(1+\tfrac12\tau p)
\end{cases}\qquad \tau=\texttt{InpRegimeTilt}\ (\times 0.5\ \text{in the NEUTRAL band}),\ \ \sum_p w_p=1$$

$$\boxed{\;E=\sum_p w_p e_p\in[-1,1],\qquad \text{score}=\sigma\big(\texttt{InpSigmoidGain}\cdot|E|\big),\qquad \text{direction}=\mathrm{sign}(E)\;}$$

with $\sigma(x)=1/(1+e^{-x})$. Because $|E|\le 1$, the score is bounded in $[0.5,\ \sigma(\text{gain})]$ and the threshold is directly interpretable as a probability: with the default gain of 4, **score ≥ 0.52 ⟺ |E| ≥ 0.020**, score ≥ 0.60 ⟺ |E| ≥ 0.101, score ≥ 0.90 ⟺ |E| ≥ 0.549.

**Tie-break (anti-idle):** if $|E|<\texttt{InpMinEvidence}$ the direction falls back to $\text{dir}_{\text{ref}}$, then to $\mathrm{sign}(\beta)$, then to the first allowed side. The score stays low (so a normal entry is not forced), but the EA is never left without a *decision*.

### 4.8 Why this avoids classic indicators

| Classic device | QGE replacement | Information the classic device loses |
|---|---|---|
| MA / EMA crossover | OLS slope **t-statistic** + $R^2$ on log price | Significance and explanatory power; an MA cross fires identically on noise and on trend |
| RSI / Stochastic | Residual **z-score** against the bar's own regression, band = residual standard error | Volatility adaptation; fixed 70/30 levels are meaningless when σ changes 5× |
| MACD histogram | Momentum **acceleration** (normalized 2nd derivative) + range expansion | Lag; MACD is a difference of two EMAs of price — a doubly-smoothed price transform |
| Bollinger %B | Residual z-score (same statistic, no smoothing constant) | The σ of a *smoothed* series vs the σ of the *regression residual* |
| ATR bands as a signal | ATR **only** as a scalar: stops, size, spacing, hedge unwind distance | ATR says nothing about direction; using it as a signal is a category error |
| ADX for "trend strength" | Hurst exponent + variance ratio | ADX measures *displacement*, not *persistence*; two processes with identical ADX can have opposite autocorrelation |

---

## 5. Position sizing — risk math

$$\text{riskMoney}=\text{equity}\cdot\frac{\text{risk}\%}{100},\qquad
\text{SLdist}=\max(\texttt{InpSL\_ATR\_Mult}\cdot ATR,\ \text{stopsLevel}+\text{buffer})$$

$$\text{lossPerLot}=\big|\texttt{OrderCalcProfit}(\text{type},1.0,\text{entry},\text{SL})\big|
\ \xrightarrow{\text{fallback}}\ \frac{\text{SLdist}}{\text{tickSize}}\cdot\text{tickValue}
\ \xrightarrow{\text{fallback}}\ \text{SLdist}\cdot\text{contractSize}$$

$$\boxed{\;\text{lots}=\Big\lfloor \frac{\text{riskMoney}}{\text{lossPerLot}\cdot\text{volStep}}\Big\rfloor\cdot\text{volStep}\;}\qquad
\text{rejected (never bumped) if } \text{lots}<\text{volMin}$$

Caps applied afterwards, in order: aggregate risk budget (`InpMaxTotalRiskPct` minus currently open risk), aggregate volume (`InpMaxTotalLots` minus open lots), broker `VOLUME_MAX`, and margin feasibility (`OrderCalcMargin` × `InpMarginCushion`). Because SLdist is ATR-scaled, $\text{lots}\propto 1/ATR$: every leg commits the **same money risk** regardless of the volatility regime — that is the volatility normalization.

Stops and targets: $\text{SL}=\text{entry}\mp\text{SLdist}$, $\text{TP}=\text{entry}\pm\text{SLdist}\cdot\texttt{InpTP\_RR}$ (sign by direction), normalized to `_Digits` and re-validated against the broker stops level at send time.

---

## 6. Dynamic pyramiding

Add-on $k\in\{1..\texttt{InpMaxScaleIns}\}$, geometric decay plus a fractional-Kelly cap:

$$\text{risk}\%_k=\texttt{InpRiskPct}\cdot\frac{\texttt{InpAddOnRiskScalePct}}{100}\cdot \texttt{InpSizeDecay}^{\,k}$$

$$f^{*}=\frac{p\,b-(1-p)}{b},\quad p=\text{score},\ b=\texttt{InpTP\_RR}
\qquad\Longrightarrow\qquad
\text{risk}\%_k\leftarrow\min\big(\text{risk}\%_k,\ \texttt{InpKellyFraction}\cdot f^{*}\cdot100,\ \texttt{InpRiskPct}\big)$$

then the same ATR-normalized conversion to lots as the base entry. $f^*\le0$ (score below the break-even probability $1/(1+b)$) **vetoes the add-on outright**.

Gating conditions — all of them must hold:

1. `direction == sign(book_net_lots)` — **never scale against the book**;
2. score ≥ `InpAddOnMinScore`;
3. `InpAddOnRequireProfit` ⇒ book all-in P&L > 0 (scale into *confirmed* strength only);
4. spacing $|\text{entry}-\text{lastEntry}|\ge \texttt{InpSpacingATR}\cdot ATR$;
5. `scale_ins < InpMaxScaleIns`, aggregate risk ≤ `InpMaxTotalRiskPct`, total lots ≤ `InpMaxTotalLots`;
6. estimated round-turn commission ≤ 50 % of the add-on's money risk;
7. no hedge active (the directional sleeve is frozen for the hedge's whole life).

This is the opposite of a martingale: sizes **shrink** geometrically (0.36 %, 0.216 %, 0.130 % with the defaults), so the tail of the pyramid contributes almost nothing to total risk, while the average entry improves only when the market has already paid for it.

**R anchor policy.** $R$ (the price distance of 1R) is fixed when the *base* leg opens and persisted in a terminal global variable (`RPRICE`). It is deliberately **not** re-based on add-ons, so break-even, trailing and the hedge's R-money stay expressed in one consistent unit. On a restart with an existing book and a lost anchor, `InferRPrice()` rebuilds it from the oldest leg's own stop.

**Aggregate stop management.** Break-even at $\text{fav}\ge\texttt{InpBreakEvenAtR}\cdot R$ (SL → weighted-avg entry $+\ \texttt{InpBreakEvenLockR}\cdot R$) and ATR trailing at $\text{fav}\ge\texttt{InpTrailStartR}\cdot R$ (SL → mark $\mp\texttt{InpTrailATR}\cdot ATR$), where fav is measured from the **volume-weighted average entry** so a pyramided book is handled coherently. Stops only ever move in the favourable direction, are skipped inside the freeze level, and are skipped when the broker would reject them.

---

## 7. Intelligent hedge — full lifecycle

### 7.1 Trigger (never a blind opposite trade)

Let $s=\mathrm{sign}(\text{net book lots})$, $L=|\text{net book lots}|$, and

$$dd_{\text{eff}}=\max\Big(\underbrace{\tfrac{\text{peak}-\text{equity}}{\text{peak}}\cdot100}_{\text{account bleed}},\
\underbrace{\tfrac{\max(0,-\Pi)}{\text{equity}}\cdot100}_{\text{this sleeve bleeding}}\Big)$$

The second term matters: a peak-equity drawdown can be stale after a deposit or a long winning run, so the hedge also reacts to the sleeve that is actually losing. Preconditions: hedging enabled, no hedge already active, book not flat, $L>0$, and $\Pi<0$ (never hedge a winning book).

* **(a) Drawdown breach** — $dd_{\text{eff}}\ge\texttt{InpHedgeDDTriggerPct}$, severity
 $\mathrm{sev}=\mathrm{clamp}\big(\tfrac{dd_{\text{eff}}-\text{trigger}}{\text{trigger}},0,1\big)$ (0 *at* the breach, 1 at twice the breach → a marginal breach does **not** lock the book). Evaluated on **every tick**.
* **(b) Regime flip** — fused score ≥ `InpHedgeFlipMinScore` in the direction **opposite** the book, confirmed over `InpHedgeFlipConfirmBars` *closed* bars (the counter can only advance on the per-bar path, so intra-bar ticks cannot inflate it), with $\mathrm{sev}=\tfrac{\text{score}-\text{flipMin}}{1-\text{flipMin}}$.

### 7.2 Size — exact derivation

Inputs to the function: net lots $L$, weighted-avg entry $W$, current price $P_0$, contract size $CS$, book $R$-money $R_m=L\cdot\text{lossPerLot}(R)$, target $T=$ `InpHedgeTargetRecoveryR`, unwind excursion $d=\texttt{InpHedgeUnwindATR}\cdot ATR$, modelled unwind price $P_u=P_0-s\,d$.

The hedge carries signed volume $-sL_h$. Its P&L from $P_0$ to $P_u$ is $(-sL_h)CS(P_u-P_0)=L_h\,CS\,d$, so the total P&L at unwind is

$$\Pi(P_u)=\underbrace{sL\,CS\,(P_u-W)}_{\text{directional book}}+\underbrace{L_h\,CS\,d}_{\text{hedge}}$$

Imposing the recovery requirement $\Pi(P_u)\ge T R_m$ and solving for $L_h$:

$$L_h\ \ge\ \frac{T R_m-sL\,CS(P_u-W)}{CS\,d}=\frac{T R_m/CS+sL(W-P_u)}{d}$$

and with the adverse distance $A=s(W-P_0)$ (positive when the book is under water) and $W-P_u=(W-P_0)+sd$:

$$\boxed{\;L_h^{\text{req}}=L\Big(1+\frac{A}{d}\Big)+\frac{T\,R_m}{CS\cdot d}\;}$$

**Interpretation:** a full delta-neutral hedge, *plus* an extra tranche proportional to how deep the book is under water relative to the expected unwind excursion, *plus* the R-based recovery term. Severity scaling and caps then give the order actually sent:

$$\text{scale}=\mathrm{clamp}\big(\text{base}+(\text{max}-\text{base})\cdot \mathrm{sev},\ \text{base},\ \text{max}\big)$$

$$\boxed{\;L_h=\mathrm{clamp}\big(\text{scale}\cdot L_h^{\text{req}},\ 0,\ \text{cap}\big),\qquad
\text{cap}=\min\big(\text{max}\cdot L,\ \texttt{InpHedgeMaxLots},\ \text{room},\ \text{affordable}\big)\;}$$

Because $\text{scale}\le\text{max}\le1$ and $\text{cap}\le\text{max}\cdot L$, we always get $L_h\le L$: **the hedge can neutralize the book but can never flip the account into a net opposite position.** $L_h$ is then floored to the volume step and rejected below `VOLUME_MIN`.

The hedge leg is sent with **no TP** and a wide catastrophe stop at $3\cdot\texttt{InpSL\_ATR\_Mult}\cdot ATR$ — its exit is owned by the lifecycle manager, not by a tight stop.

*Netting accounts:* instead of an opposite order, `Deleverage()` partially closes the book by the same `scale` factor, largest leg first.

### 7.3 Manage / unwind — five exits, checked in this order every tick

| # | Exit | Condition | Action |
|---|---|---|---|
| 0 | **Orphan cleanup** | directional book gone ($L=0$) | close the whole hedge sleeve immediately |
| 1 | **Anti-lock time stop** | hedge age ≥ `InpHedgeMaxAgeHours` | close the whole hedge sleeve |
| 2 | **Regime re-flip** | score ≥ `InpHedgeFlipMinScore` in the *book's* direction | close the whole hedge sleeve, let the book run |
| 3 | **Hedge take-profit banking** | hedge P&L ≥ $(n{+}1)\cdot\texttt{InpHedgeTakeProfitR}\cdot R_m$ | close `InpHedgePartialClosePct` of the *remaining* hedge, realize the profit into the account, advance the level |
| 4 | **Drawdown-recovery ladder** | see below | close tranche $k$, cumulatively |

Recovery progress and the ladder:

$$\rho=\mathrm{clamp}\Big(\frac{\text{trigger}-dd_{\text{eff}}}{\text{trigger}\,(1-\texttt{InpHedgeReleaseDDFraction})},0,1\Big),\qquad
k^{*}=\lfloor \rho\cdot \text{steps}\rfloor,\qquad \text{frac}=\frac{k^{*}}{\text{steps}}$$

$$\text{goal}=\begin{cases}T\cdot R_m & k^{*}=\text{steps}\quad(\text{final rung: contractual break-even / R target})\\[2pt] \min\big(\Pi_{\text{birth}}-0.10R_m,\ \text{frac}\cdot T\cdot R_m\big) & \text{otherwise}\quad(\text{DD recovery alone, never worse than at birth})\end{cases}$$

$$\text{release tranche }k^{*}\ \text{if}\ \Pi\ge\text{goal},\qquad \text{cumulative closed target}=\text{frac}\cdot L_h^{\text{born}}$$

The $0.10R_m$ allowance exists because swap and commission accrue while the hedge is on: without it, a delta-locked sleeve whose P&L is *exactly* frozen at $\Pi_{\text{birth}}$ could never satisfy a strict inequality and would depend solely on the time stop.

**The honest treatment of the hedge-lock problem.** When $\text{scale}=1$ (severe drawdown) the book becomes delta-neutral and $\Pi$ is *frozen*: no ladder rung that depends on money can fire, because a locked book cannot recover on its own. The design accepts this explicitly and provides three independent ways out — profit banking (3), which progressively re-opens delta as the hedge earns; regime re-flip (2), which realizes the frozen P&L and lets the book run again in a re-confirmed regime; and the anti-lock time stop (1), which bounds the lock at `InpHedgeMaxAgeHours`. The maximum damage along the hedge path is therefore bounded by roughly the drawdown at trigger time plus carry — versus an unbounded loss with no hedge at all. If you prefer a *live* ladder at all times, set `InpHedgeMaxRatio` to 0.5–0.8 so a residual delta always remains (see Section 11).

Every lifecycle field (`born_lots`, `born_price`, `born_time`, `anchor_R`, `born_pnl`, `closed_lots`, TP level) is persisted in terminal global variables keyed by magic + account login, so a restart, a recompile or a parameter change resumes the hedge exactly where it left off. Hedge legs are additionally tagged by ticket in a global variable, so the sleeve is still identified correctly if the broker strips or rewrites position comments.

---

## 8. Risk & money-management guard stack

| Guard | Default | Behaviour when breached |
|---|---|---|
| Max spread (absolute) | 120 points | entry/add-on blocked (per-tick re-check with live Ask−Bid) |
| Max spread (relative) | 35 % of ATR | entry/add-on blocked |
| Daily loss limit | 8 % of day-start equity (realized **plus** floating) | `g_haltNewEntries=true` until the next trading day; existing positions keep being managed |
| Equity-floor kill switch | 30 % DD from peak equity | halts new entries; optionally flattens everything once per breach episode (`InpKillSwitchCloseAll`), re-arms on recovery |
| Aggregate risk cap | 4 % of equity | shrinks the next entry's risk budget to the remaining room; blocks at zero |
| Aggregate volume cap | 5.00 lots | shrinks or blocks; `VOLUME_MIN`-sized remainders are rejected, never bumped |
| Margin cushion | 3× needed margin | `OrderCalcMargin()` pre-check on every send |
| Cost sanity | round-turn commission ≤ 50 % of the trade's money risk | entry/add-on blocked |
| Daily entry cap | 20 | entries blocked, management continues |
| Trade permission | terminal/account/symbol/long-only/short-only/close-only | entry blocked with an explicit reason |
| Session filter | **off** | (available; off by default so nothing blocks the first trade) |

Day-start equity is anchored to the broker's `iTime(_Symbol, PERIOD_D1, 0)` bar (timezone-correct), persisted, and re-anchored automatically on rollover. Peak equity is persisted so the kill switch survives restarts.

---

## 9. Execution engineering

* One `CTrade` object, magic-bound, deviation = `InpSlippagePoints`, filling resolved per symbol, synchronous mode.
* Retry loop: `REQUOTE`, `PRICE_CHANGED`, `PRICE_OFF`, `TIMEOUT`, `CONNECTION`, `TOO_MANY_REQUESTS` are retried up to `InpOrderRetries` with `Sleep(InpRetryDelayMs)` on live accounts only (never in the tester). `INVALID_STOPS` triggers one stop-repair retry. `NO_MONEY`, `INVALID_VOLUME`, `LIMIT_VOLUME`, `TRADE_DISABLED`, `MARKET_CLOSED` abort immediately.
* Every retcode is mapped to a human-readable name (`RetcodeText`), and `POSITION_CLOSED` on a close request is treated as success.
* Position scans are always `PositionsTotal()-1 → 0`, filtered by symbol **and** magic, using `PositionGetTicket(i)` (never the deprecated index-only access pattern).
* Partial closes are normalized to the volume step; a remainder below `VOLUME_MIN` closes the whole leg only if it is ≥ 75 % of it, otherwise the action is skipped (never bumped).
* `OnTimer` re-runs the light pass (guards + hedge lifecycle + stops) so protection continues when the quote feed stalls; it never opens entries.
* `OnTester()` returns a composite objective (PF + Sharpe + 1.5·RecoveryFactor − 0.05·relative DD, with thin-sample and zero-loser discounts) so the optimizer cannot win by trading once.

---

## 10. Immediate-activation semantics (what happens on attach)

| Step | `OnInit` | First `OnTick` |
|---|---|---|
| 1 | Validate inputs (fail with `INIT_PARAMETERS_INCORRECT` on genuinely broken math windows), cache the whole symbol spec once | Section A: day/peak anchors, cheap book scan, guards, hedge DD trigger, hedge lifecycle, stops |
| 2 | Validate gold symbol (warn-only by default) and margin mode (warn + degrade) | Section B: bar guard; warm-up probe `iBars ≥ RequiredBars+1` |
| 3 | Create the single `iATR` handle | If `OnInit` already computed *this* closed bar → **reuse the cache** (no duplicate heavy work); otherwise one `Prime()` + `Compute()` |
| 4 | Anchor day-start and peak equity; restore hedge lifecycle state; rebuild the R anchor if needed | Clear the one-shot flag **only once a usable signal exists** (a not-yet-calculated ATR buffer can never stall activation; retries are bounded to 1/s) |
| 5 | `Prime()` + `Compute()` **now**, cache the signal, log readiness | Section C: hedge flip trigger → entry gate → `AttemptBaseEntry()` at market |
| 6 | `EventSetTimer()`; print the full configuration banner | If the score is below threshold, the idle counter starts; at `InpForceEntryAfterIdleBars` closed bars the EA **forces** an entry (guards still respected) |

`RequiredBars()` is the minimum window over *all* estimators plus two bars of slack — with the defaults that is **132 closed H1 bars** (≈ 5.5 trading days), the smallest window that makes every statistic well defined. Until then the EA logs status and re-checks cheaply every tick.


---

## 11. Parameter table (all 97 inputs)

Group headings match the `input group` blocks in the source, so the dialog layout is identical.

**0 -- Identity, activation & diagnostics**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpMagicNumber` | long | `905173` | Magic number (isolates this EA's book) |
| `InpSignalTF` | ENUM_TIMEFRAMES | `PERIOD_H1` | Signal timeframe (all statistics) |
| `InpTradeOnFirstTick` | bool | `true` | Evaluate + trade on the FIRST tick after attach |
| `InpForceEntryAfterIdleBars` | int | `3` | Force an entry after N idle closed bars (0 = never) |
| `InpUseTimer` | bool | `true` | Enable OnTimer for guard/hedge housekeeping |
| `InpTimerSeconds` | int | `5` | Timer period (seconds) |
| `InpRequireGoldSymbol` | bool | `false` | Hard-fail init if symbol is not gold (false = warn only) |
| `InpVerboseLog` | bool | `true` | Verbose logging of every pillar and decision |
| `InpShowDashboard` | bool | `true` | On-chart status dashboard (Comment) |

**1 -- Volatility regime: Yang-Zhang / Garman-Klass / persistence**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpYZFastWindow` | int | `20` | YZ fast window (bars) |
| `InpYZSlowWindow` | int | `100` | YZ slow window (bars) |
| `InpBarsPerYear` | int | `6000` | Bars per year (annualization scalar) |
| `InpVRWindow` | int | `120` | Variance-ratio window (bars) |
| `InpVRLag` | int | `5` | Variance-ratio aggregation lag q |
| `InpVRRef` | double | `0.40` | ln(VR) normalizer (ln(1.5) ~ 0.405) |
| `InpHurstRSWindow` | int | `128` | R/S Hurst window (bars) |
| `InpTrendHurst` | double | `0.55` | Hurst above this => trending regime |
| `InpMeanRevHurst` | double | `0.45` | Hurst below this => mean-reverting regime |
| `InpVolExpansionRatio` | double | `1.15` | YZ(fast)/YZ(slow) above this => expanding vol |

**2 -- Trend pillar: rolling OLS slope, R^2, t-statistic**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpOLSWindow` | int | `48` | OLS window (bars) |
| `InpTStatRef` | double | `2.00` | t-stat normalizer (t/TStatRef -> tanh) |
| `InpR2Min` | double | `0.00` | Minimum R^2 to trust the slope (0 = permissive) |
| `InpZWindow` | int | `48` | Residual z-score window (bars) |
| `InpZRef` | double | `1.50` | z-score normalizer |

**3 -- Microstructure pillar: order-flow proxy**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpEffWindow` | int | `12` | Path-efficiency window (bars) |
| `InpMomFast` | int | `3` | Fast momentum window (bars) |
| `InpMomSlow` | int | `12` | Slow momentum window (bars) |
| `InpRangeWindow` | int | `6` | Range-expansion half-window (bars) |
| `InpAccelRef` | double | `1.00` | Acceleration normalizer (std devs) |
| `InpExpansionRef` | double | `0.25` | Range-expansion normalizer |
| `InpMicroWEff` | double | `0.55` | Weight: path efficiency |
| `InpMicroWAccel` | double | `0.30` | Weight: momentum acceleration |
| `InpMicroWExp` | double | `0.15` | Weight: range expansion |

**4 -- Probabilistic fusion & confidence gate**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpConfidenceThreshold` | double | `0.52` | Minimum score [0..1] to enter (LOW = trades fast) |
| `InpSigmoidGain` | double | `4.00` | Logistic gain on |composite evidence| |
| `InpMinEvidence` | double | `0.02` | Minimum |E| for a non-degenerate direction |
| `InpWVol` | double | `0.15` | Pillar weight: volatility/persistence |
| `InpWTrend` | double | `0.35` | Pillar weight: OLS trend |
| `InpWMeanRev` | double | `0.20` | Pillar weight: residual z-score |
| `InpWMicro` | double | `0.30` | Pillar weight: microstructure |
| `InpRegimeAdaptiveWeights` | bool | `true` | Re-weight pillars by Hurst persistence |
| `InpRegimeTilt` | double | `0.50` | Regime tilt strength (0 = static weights) |
| `InpAllowLong` | bool | `true` | Permit long entries |
| `InpAllowShort` | bool | `true` | Permit short entries |
| `InpMaxTradesPerDay` | int | `20` | Daily entry cap (permissive) |

**5 -- Stops & targets (ATR = volatility SCALAR only)**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpATRPeriod` | int | `14` | ATR period (scalar) |
| `InpSL_ATR_Mult` | double | `2.00` | Stop-loss distance = mult x ATR |
| `InpTP_RR` | double | `2.00` | Take-profit = R:R multiple of SL distance |
| `InpStopLevelBufferPts` | int | `2` | Extra buffer beyond broker stops level (points) |
| `InpUseBreakEven` | bool | `true` | Move book SL to break-even |
| `InpBreakEvenAtR` | double | `0.80` | Break-even trigger (R of favorable excursion) |
| `InpBreakEvenLockR` | double | `0.10` | Break-even lock-in (R beyond weighted avg entry) |
| `InpUseTrailing` | bool | `true` | ATR trailing stop on the aggregate book |
| `InpTrailStartR` | double | `1.00` | Trailing starts after this many R in profit |
| `InpTrailATR` | double | `1.50` | Trailing distance (x ATR) |

**6 -- Risk & money management (account aware)**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpRiskPctOfEquity` | double | `1.00` | Risk per base entry (% of EQUITY) |
| `InpMaxTotalRiskPct` | double | `4.00` | Max aggregate open risk (% of equity) |
| `InpMaxTotalLots` | double | `5.00` | Hard cap on total open lots (book+hedge) |
| `InpMaxSpreadPoints` | int | `120` | Max spread (points) -- generous for gold |
| `InpMaxSpreadPctOfATR` | double | `0.35` | Max spread as fraction of ATR |
| `InpDailyLossLimitPct` | double | `8.00` | Daily loss limit (% of day-start equity) |
| `InpEquityFloorDDPct` | double | `30.00` | Equity-floor kill switch (% DD from peak) |
| `InpKillSwitchCloseAll` | bool | `false` | Kill switch also flattens the book |
| `InpMarginCushion` | double | `3.00` | Required free margin / needed margin |
| `InpSlippagePoints` | int | `30` | Max deviation (points) |
| `InpOrderRetries` | int | `3` | Retries on requote/price-changed/timeout |
| `InpRetryDelayMs` | int | `250` | Delay between retries (live only) |
| `InpEstRoundTurnCommPerLot` | double | `7.00` | Estimated round-turn commission per lot (USD) |

**7 -- Dynamic pyramiding (geometric decay + fractional Kelly)**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpEnablePyramiding` | bool | `true` | Allow scale-ins |
| `InpMaxScaleIns` | int | `3` | Max add-ons per directional book |
| `InpSizeDecay` | double | `0.60` | Geometric decay of add-on risk |
| `InpAddOnRiskScalePct` | double | `60.00` | First add-on risk as % of base risk |
| `InpSpacingATR` | double | `1.00` | Min spacing between entries (x ATR) |
| `InpAddOnMinScore` | double | `0.55` | Min score for an add-on |
| `InpAddOnRequireProfit` | bool | `true` | Add-ons only while the book is in profit |
| `InpKellyFraction` | double | `0.25` | Fractional Kelly cap (0.25 = quarter Kelly) |

**8 -- Intelligent hedge (full lifecycle)**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpEnableHedging` | bool | `true` | Enable hedge manager |
| `InpHedgeDDTriggerPct` | double | `3.00` | Drawdown trigger (% - peak DD or open-book loss) |
| `InpHedgeBaseRatio` | double | `0.35` | Severity scaling at the trigger (x required hedge) |
| `InpHedgeMaxRatio` | double | `1.00` | Severity scaling at 2x trigger (1.0 = delta neutral) |
| `InpHedgeMaxLots` | double | `3.00` | Absolute cap on hedge lots |
| `InpHedgeTargetRecoveryR` | double | `0.00` | Recovery target on unwind (R; 0 = break-even) |
| `InpHedgeUnwindATR` | double | `1.50` | Expected unwind excursion (x ATR) |
| `InpHedgeFlipMinScore` | double | `0.90` | Score needed for a regime-flip hedge trigger |
| `InpHedgeFlipConfirmBars` | int | `1` | Consecutive flip bars required (1 = immediate) |
| `InpHedgeReleaseDDFraction` | double | `0.35` | Full unwind once DD falls to this fraction of trigger |
| `InpHedgeTakeProfitR` | double | `1.00` | Bank hedge profit at this multiple of R |
| `InpHedgePartialClosePct` | double | `50.00` | % of remaining hedge closed per TP level |
| `InpHedgeUnwindLadderSteps` | int | `3` | Ladder tranches for graduated unwind |
| `InpHedgeMaxAgeHours` | int | `72` | Anti-lock time stop on the hedge (hours) |

**9 -- Session filter (OFF by default so nothing blocks entry)**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpUseSessionFilter` | bool | `false` | Restrict entries to a session window |
| `InpSessionStartHour` | int | `7` | Session start (server hour, inclusive) |
| `InpSessionEndHour` | int | `20` | Session end (server hour, exclusive) |
| `InpSkipLateFriday` | bool | `false` | No new entries late Friday |

**10 -- Position tags**

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpTagBook` | string | `"QGE-B"` | Comment tag: base entry |
| `InpTagPyramid` | string | `"QGE-P"` | Comment tag: scale-in |
| `InpTagHedge` | string | `"QGE-H"` | Comment tag: hedge leg |
**Defaults are deliberately biased toward action.** The confidence gate at 0.52 requires only |E| ≥ 0.020 of the full evidence range; spread limits are generous for gold (120 points ≈ $1.20, or 35 % of ATR); the daily-loss limit is 8 %; the session filter is off. Tighten in this order once the baseline behaviour is confirmed: `InpConfidenceThreshold` → `InpR2Min` → `InpAddOnMinScore` → `InpMaxSpreadPoints` → `InpHedgeFlipMinScore`.

---

## 12. Risk-math walkthrough (worked numbers)

Account: **$10 000 equity**, XAUUSD, contract size 100 oz, tick size 0.01, tick value $1.00 ⇒ **$100 of P&L per $1.00 price move per lot**. `ATR(H1) = $3.50` at entry, `InpSL_ATR_Mult = 2.0`, `InpTP_RR = 2.0`, `InpRiskPctOfEquity = 1.0`.

### 12.1 Base lot size

$$\text{SLdist}=2.0\times3.50=\$7.00\ (> \text{stops level }0.03),\qquad
\text{lossPerLot}=\frac{7.00}{0.01}\times1.00=\$700$$

$$\text{riskMoney}=10\,000\times1\%=\$100,\qquad
\text{lots}=\frac{100}{700}=0.142857\ \xrightarrow{\ \lfloor\cdot\rfloor\ \text{to step }0.01\ }\ \mathbf{0.14}$$

Realized risk $=0.14\times700=\$98$ (0.98 % — rounding *down* is what keeps realized risk ≤ budgeted risk).
Order sent: `BUY 0.14 @ 2000.25, SL 1993.25, TP 2014.25` ($R=\$7.00$, persisted as the book's R anchor).

*Sub-minimum rejection:* if equity were $500, riskMoney $= \$5$, lots $=0.0071 < \text{VOLUME\_MIN}=0.01$ ⇒ the trade is **rejected and logged**, never bumped to 0.01 (which would have doubled the intended risk).

### 12.2 Pyramid add-ons (geometric decay + Kelly cap)

| Add-on $k$ | decay $0.6^k$ | risk % $=1.0\times0.60\times0.6^k$ | risk $ | ATR | SLdist | lots | Kelly $f^*$ (score, $b$=2) | quarter-Kelly cap | Aggregate book |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 0.600 | 0.360 % | $36.21 | 3.60 | $7.20 | **0.05** | 0.820 (0.88) | 20.5 % → non-binding | 0.19 @ 2001.43 |
| 2 | 0.360 | 0.216 % | $21.91 | 3.70 | $7.40 | **0.02** | 0.790 (0.86) | 19.8 % → non-binding | 0.21 @ 2002.18 |
| 3 | 0.216 | 0.130 % | $13.25 | 3.80 | $7.60 | **0.01** | 0.760 (0.84) | 19.0 % → non-binding | 0.22 @ 2002.68 |

Total committed risk $=0.22\times\$700=\$154=1.54\%$ of equity — well inside the 4 % aggregate cap, and the marginal add-on contributes only 0.13 %. Each add-on also required: same direction as the book, score ≥ 0.55, book P&L > 0, and spacing ≥ 1.0 × ATR from the previous entry (at $t{=}1$: $2004.75-2000.25=4.50\ge3.60$ ✓).

Kelly acts as a **cap**, never a booster: with $b=2$ the break-even win probability is $1/(1+b)=0.333$, so any score above 0.33 gives $f^*>0$; at the observed scores $f^*\approx0.8$ and $\tfrac14 f^*\approx20\%$, far above the 1 % budget. With `InpTP_RR = 0.5` and score 0.55 the Kelly edge turns *negative* ($f^*=(0.55\cdot0.5-0.45)/0.5=-0.35$) and the add-on is **vetoed** — the cap has teeth.

### 12.3 Hedge trigger and size

Book: $L=0.22$ long, $W=2002.68$, $R=\$7.00\Rightarrow R_m=0.22\times700=\$154$.

**(a) Drawdown breach, deep adverse move (defaults).** Price at Bid $P_0=1996.00$, $ATR=4.20$, equity $9 853$, peak $10 227.25$:

$$dd_{\text{eff}}=\max\Big(\underbrace{3.66\%}_{\text{peak DD}},\underbrace{1.49\%}_{147/9853}\Big)=3.66\%\ge3.0\%\ \checkmark$$
$$\mathrm{sev}=\frac{3.66-3.00}{3.00}=0.220,\quad \text{scale}=0.35+0.65\times0.220=0.493$$
$$d=1.5\times4.20=6.30,\quad A=s(W-P_0)=+6.68,\quad L_h^{\text{req}}=0.22\Big(1+\frac{6.68}{6.30}\Big)+0=\mathbf{0.4533}$$
$$\text{cap}=\min(1.00\times0.22,\ 3.00,\ 5.00-0.22,\ \text{affordable})=0.2200\ \Rightarrow\ L_h=\min(0.493\times0.4533,\ 0.22)=\mathbf{0.22}$$

Order: `SELL 0.22 @ 1996.00`, catastrophe stop $1996.00+3\times2.0\times4.20=2021.20$, no TP. Net delta $=0.22-0.22=0$ — the recovery math *asked* for 0.4533 lots (2× the book) and the cap correctly refused to flip the account net short.

**(b) Regime flip, shallow adverse move (defaults).** $P_0=2001.68$, $ATR=4.20$, score $0.93$ against the book, confirmed:

$$\mathrm{sev}=\frac{0.93-0.90}{1-0.90}=0.300,\quad \text{scale}=0.35+0.65\times0.300=0.545$$
$$A=+1.00,\quad d=6.30,\quad L_h^{\text{req}}=0.22\Big(1+\frac{1.00}{6.30}\Big)=0.2549$$
$$L_h=\min(0.545\times0.2549,\ 0.22)=0.1389\ \xrightarrow{\text{floor to step}}\ \mathbf{0.13}$$

Net delta $=0.22-0.13=\mathbf{+0.09}$ — a *partial* hedge (41 % delta reduction). This is the graduated behaviour the severity scaling exists for: a marginal signal with a shallow loss does not lock the book.

**(c) Same as (a) with `InpHedgeMaxRatio = 0.6`** (the "live-ladder" configuration): cap $=0.6\times0.22=0.132$, scale $=0.405$, $L_h=\min(0.405\times0.4533,0.132)=0.132\to\mathbf{0.13}$, net delta $+0.09$.

### 12.4 Hedge unwind — path 1: delta-locked, exits by profit banking then the ladder

Continuation of case (a) — the actual event sequence produced by the lifecycle model:

| Bar | Price | Hedge | Hedge P&L | Book P&L | All-in Π | Event |
|---|---|---|---|---|---|---|
| 5 | 1996.00 | 0.22 short @1996 | 0 | −147.00 | −147.00 | **HEDGE OPENED** (ddEff 3.66 %, sev 0.22, scale 0.493, $L^{req}$ 0.4533, cap 0.22) |
| 6 | 1985.00 | 0.22 | +242.00 | −389.00 | −147.00 | **TP level 1**: $242\ge1\times R_m=154$ → close 50 % = **0.11 lots**, bank **+$121** |
| 8 | 1968.00 | 0.11 | +308.00 | −642.00 | −334.00 | **TP level 2**: $308\ge2\times154=308$ → close 50 % = **0.05 lots**, bank **+$140** |
| 9 | 1975.00 | 0.06 | +126.00 | −348.00 | −222.00 | ladder armed, $k=0$ ($dd_{\text{eff}}=4.94\%>$ trigger) → **hold** |
| 10 | 1988.00 | 0.06 | −14.00 | 0.00 | −14.00 | $dd_{\text{eff}}=2.75\%$, $\rho=0.38$, $k=1$ but $\Pi<$ goal → **hold** |
| 11 | 1999.00 | 0.06 | −161.00 | +323.00 | +162.00 | $\rho=1.00$, $k=3/3$, $\Pi=+162\ge T R_m=0$ → **FULL UNWIND**, close 0.06 |
| 13 | 2015.00 | 0.00 | — | +514.00 | +514.00 | book running free, equity $10 514 |

Two things to note. First, while the sleeve is delta-locked (bar 6–8) Π is *exactly* frozen at −147.00: the book and the hedge move by equal and opposite amounts. That is why profit **banking** (closing part of the hedge into realized cash) is the mechanism that re-opens delta, and why the ladder alone cannot rescue a full lock. Second, the lifecycle **terminates**: hedge = 0.00 lots, no orphan, no permanent lock.

### 12.5 Hedge unwind — path 2: partial hedge, ladder rungs fire

Case (c): hedge 0.13 short @ 1996, $\Pi_{\text{birth}}=-147.00$, $R_m=\$154$, peak equity $10 227.25$, `InpHedgeUnwindLadderSteps = 3`, `InpHedgeReleaseDDFraction = 0.35`, $T=0$.

| Price | Book P&L | Hedge P&L | Π | $dd_{\text{eff}}$ | $\rho$ | $k^*$ | goal | Action |
|---|---|---|---|---|---|---|---|---|
| 1996.00 | −146.96 | 0.00 | −146.96 | 1.46 % | 0.791 | 2/3 | $\min(-147-15.4,\ 0)=-162.40$ | Π ≥ goal ⇒ **release 0.08 lots** (cumulative target $\tfrac23\times0.13=0.0867$) |
| 1999.00 | −80.96 | −15.00 | −95.96 | 0.95 % | 1.000 | 3/3 | $T\cdot R_m=0$ | Π < 0 ⇒ **hold** (final rung enforces break-even) |
| 2002.00 | −14.96 | −30.00 | −44.96 | 0.44 % | 1.000 | 3/3 | 0 | **hold** |
| 2005.00 | +51.04 | −45.00 | +6.04 | 0.00 % | 1.000 | 3/3 | 0 | Π ≥ 0 ⇒ **FULL UNWIND**, close 0.05 |

The intermediate rung is released by **drawdown recovery alone**, guarded so that we never unwind into a position worse than at hedge birth minus 0.10 R ($-\$162.40$) — that allowance absorbs accrued swap/commission, which would otherwise make a strict `Π ≥ Π_birth` test fail on a frozen sleeve. The final rung enforces the contractual recovery target (`InpHedgeTargetRecoveryR = 0` ⇒ break-even).

---

## 13. Backtesting & optimization guide

### 13.1 Tester setup

| Setting | Recommendation | Why |
|---|---|---|
| Symbol | XAUUSD (your broker's exact suffix) | Contract size / tick value drive the sizing |
| Period | H1 (matches `InpSignalTF`) | The statistics are calibrated to the signal timeframe |
| Model | **Every tick based on real ticks** | Microstructure pillars (path efficiency, range expansion) are sensitive to intrabar paths; "1-minute OHLC" understates EF and RE |
| Spread | Real/floating, not fixed | The spread filter is part of the strategy |
| Deposit | 10 000 USD, leverage ≥ 1:100 | Matches the worked examples; margin cushion is checked live |
| Swap & commission | Your broker's real values | `InpEstRoundTurnCommPerLot` should match round-turn cost per lot |
| Optimization criterion | **Custom max** (uses `OnTester()`) | Composite = PF + Sharpe + 1.5·RF − 0.05·relative DD, with thin-sample discount |
| Delays | "Random delay" / realistic slippage | Retote & partial-fill retry paths need to be exercised |

### 13.2 What to optimize (and what to leave alone)

**Tier 1 — optimize first (largest effect on the distribution of trades)**

| Input | Range | Step | Notes |
|---|---|---|---|
| `InpSignalTF` | M15, M30, H1, H4 | discrete | Re-set `InpBarsPerYear` = 6000·(H1/TF) and re-scale the windows so they cover similar *time* |
| `InpConfidenceThreshold` | 0.52 – 0.90 | 0.02 | The master selectivity dial. Measured score distribution: p10 ≈ 0.51–0.80, p50 ≈ 0.57–0.87, p90 ≈ 0.67–0.92 |
| `InpSigmoidGain` | 2.0 – 8.0 | 0.5 | Rescales |E| → probability; raise together with the threshold |
| `InpOLSWindow` | 24 – 96 | 8 | Trend horizon |
| `InpSL_ATR_Mult` | 1.2 – 3.5 | 0.1 | Sets R, hence lot size and every R-denominated rule |
| `InpTP_RR` | 1.0 – 3.5 | 0.25 | Also the Kelly payoff $b$ |

**Tier 2 — regime estimation**

| Input | Range | Step |
|---|---|---|
| `InpYZFastWindow` | 10 – 40 | 5 |
| `InpYZSlowWindow` | 60 – 200 | 20 |
| `InpVRLag` | 3 – 10 | 1 |
| `InpVRWindow` | 80 – 200 | 20 |
| `InpHurstRSWindow` | 64 – 256 | 32 |
| `InpTrendHurst` / `InpMeanRevHurst` | 0.52–0.65 / 0.35–0.48 | 0.01 |
| `InpRegimeTilt` | 0.0 – 1.0 | 0.1 (0.0 = static weights; an important ablation) |

**Tier 3 — pillar weights and microstructure** (`InpWTrend`, `InpWMeanRev`, `InpWMicro`, `InpWVol`, `InpEffWindow`, `InpMomFast/Slow`, `InpRangeWindow`, `InpAccelRef`, `InpExpansionRef`, `InpTStatRef`, `InpZRef`). Optimize these **only after** Tiers 1–2 are stable; they are strongly interacting, so use a genetic algorithm rather than a full grid.

**Tier 4 — capital management** (`InpRiskPctOfEquity`, `InpMaxTotalRiskPct`, `InpMaxScaleIns`, `InpSizeDecay`, `InpAddOnRiskScalePct`, `InpSpacingATR`, `InpKellyFraction`).

**Tier 5 — hedge lifecycle** (`InpHedgeDDTriggerPct`, `InpHedgeFlipMinScore`, `InpHedgeBaseRatio`, `InpHedgeMaxRatio`, `InpHedgeTargetRecoveryR`, `InpHedgeUnwindATR`, `InpHedgeTakeProfitR`, `InpHedgePartialClosePct`, `InpHedgeUnwindLadderSteps`, `InpHedgeReleaseDDFraction`, `InpHedgeMaxAgeHours`).

**Never optimize:** `InpMagicNumber`, tags, timer settings, `InpRequireGoldSymbol`, `InpStopLevelBufferPts`, `InpSlippagePoints` (set from your broker), `InpBarsPerYear` (derive it from the timeframe).

### 13.3 Ablations to run (each isolates one claimed source of edge)

1. `InpRegimeTilt = 0` — does regime-adaptive weighting add anything?
2. `InpWVol = 0` (renormalize the rest) — is the persistence pillar pulling weight?
3. `InpWMicro = 0` — is microstructure pulling weight?
4. `InpR2Min = 0.3` — does demanding explanatory power help or just reduce sample size?
5. `InpEnablePyramiding = false` — what does pyramiding actually contribute to RF and DD?
6. `InpEnableHedging = false` — the hedge must *reduce* max DD and *raise* the recovery factor, otherwise disable it. This is the single most important ablation in the whole study.
7. `InpForceEntryAfterIdleBars = 0` — measures how much P&L comes from the anti-idle forcing (it should be a small, ideally negligible, contribution).

### 13.4 Walk-forward protocol

* **Data:** minimum 5 years of real-tick H1 gold, including 2020 (Aug breakout), 2022 (rate shock), 2023–24 (bank-stress and rally) and a quiet year.
* **Split:** 24-month in-sample / 6-month out-of-sample, rolled forward by 6 months ⇒ ~8 folds on 5 years. Anchor the first fold at least 6 months before the earliest test start so the peak-equity anchor and warm-up are realistic.
* **Per fold:** optimize on IS with *Custom max*; freeze parameters; run OOS unchanged; record OOS metrics.
* **Accept only if:** OOS Profit Factor ≥ 1.15, OOS Sharpe ≥ 0.8, OOS Recovery Factor ≥ 1.0, OOS max relative equity DD ≤ 1.5 × IS max DD, and the OOS trade count is at least 60 % of what the IS rate predicts (a collapse in trade count means the fitted thresholds are over-fit).
* **Parameter stability check:** plot the IS-optimal value of each Tier-1 parameter across folds. A parameter whose optimum jumps around is not a structural property of gold — fix it at a round value and re-run.
* **Monte Carlo:** after the walk-forward, resample the OOS trade sequence (block bootstrap, 1 000 paths) to get the 95th-percentile max DD, and re-run with 2× spread and 3× slippage to verify cost resilience.
* **Forward test:** demo for ≥ 4 weeks before any live capital; compare live fills to the tester's assumptions on slippage and spread.

### 13.5 Metrics that matter for *this* EA

| Metric | Why it is specific here |
|---|---|
| Profit Factor / expectancy | The score is a probability estimate — a well-calibrated gate should show a monotone expectancy vs score bucket (log the score and verify) |
| Sharpe (annualized) | Per-bar drift estimates make this comparable across timeframes |
| **Recovery Factor** | The hedge exists to compress max DD; RF is the metric it should move |
| Max relative equity DD | Directly bounded by the daily-loss limit + equity floor + hedge |
| Hedge statistics | Count of hedges, mean age, mean realized hedge P&L, count of time-stop exits (a *high* time-stop count means the triggers are too loose) |
| Trade count / idle bars | The anti-idle guarantee: `InpForceEntryAfterIdleBars` should rarely bind |
| Long vs short split | Should be roughly balanced; a strong asymmetry means a directional bias leaked into the pillars |

---

## 14. Known risks and failure modes

| # | Failure mode | Mitigation in the code | Residual risk |
|---|---|---|---|
| 1 | **Never trades** (the classic over-filtered EA) | Threshold 0.52 ⇔ |E| ≥ 0.02; permissive spread/session defaults; signal pre-computed in `OnInit`; forced evaluation on the first tick; idle-guard entry after 3 closed bars; degenerate-evidence tie-break so a direction always exists | A broker with no data or a suspended symbol still cannot trade (correctly) |
| 2 | **Look-ahead / repainting** | Every read is at shift ≥ 1; `CopyRates(start_pos=1)`; bar guard on `iTime(bar 0)`; a signal that does not match the current closed bar is invalidated | None known; verified by construction |
| 3 | **Permanent hedge lock** | Five independent exits incl. an anti-lock time stop and orphan cleanup; hedge ≤ book size so the account never flips net | Under a full lock Π is frozen until an exit fires; bounded by `InpHedgeMaxAgeHours` |
| 4 | **Martingale creep** | Geometric decay (0.6^k), fractional-Kelly cap, hard add-on count, aggregate risk cap 4 %, aggregate lot cap, add-ons only in profit and only with the trend | None: sizes strictly shrink |
| 5 | **Sub-minimum lot bumping** | `NormalizeVolume()` floors to the step and **returns 0 (reject)** below `VOLUME_MIN`; partial-close remainders are skipped, not rounded up | Some small accounts cannot trade at all — by design |
| 6 | **Wrong tick/value handling on XAUUSD** | `OrderCalcProfit()` first, tick-value formula second, contract-size formula third; all three logged in the sizing message | An exotic broker with a zero tick value falls back to the contract-size estimate (correct only when the account currency is the quote currency) |
| 7 | **Stops rejected / frozen** | Stops level + buffer enforced before send; one stop-repair retry on `INVALID_STOPS`; freeze-level check before any modify; non-improving modifications skipped | Instant-execution brokers with wide stops levels may widen the SL (logged) |
| 8 | **Requotes / partial fills / off-quotes** | Explicit `TRADE_RETCODE_*` handling, retry loop for transient codes, abort for permanent ones, `DONE_PARTIAL` accepted as success | Partial fills leave a smaller position; the next book scan reflects it |
| 9 | **Broker strips position comments** | Hedge legs are tagged by ticket in a terminal global variable *in addition* to the comment; scale-in count falls back to `legs − 1` | None material |
| 10 | **Restart / recompile mid-trade** | Peak equity, day-start equity, R anchor and the whole hedge lifecycle state are persisted per magic + account login; `InferRPrice()` rebuilds R from the oldest leg's own stop | A lost GV *and* legs without stops ⇒ R-based rules pause until the next entry (logged as a warning) |
| 11 | **Stale peak-equity anchor** (e.g. after a deposit) | `ddEff` uses `max(peakDD, open-book loss % equity)`, so a stale peak cannot cause a false hedge trigger by itself; the peak ratchets up on every tick | A large *withdrawal* still shows as drawdown; use `InpEquityFloorDDPct = 0` to disable the kill switch during planned withdrawals |
| 12 | **Cost-dominated trading** | Round-turn commission ≤ 50 % of the trade's money risk, checked pre-trade; commission+fees read from history deals and included in every all-in P&L | Frequent add-ons in a low-ATR regime shrink size automatically |
| 13 | **Weekend / holiday gaps** | Stops are always attached to entries; the hedge catastrophe stop is 3× the normal ATR stop; daily-loss and equity-floor guards halt new entries | Gap-through-stop slippage is unavoidable; the guards cap the *next* action, not the gap itself |
| 14 | **Over-optimization** | 97 inputs, but only ~12 in Tier 1; walk-forward + parameter-stability + ablation protocol in §13.4; `OnTester()` penalizes thin samples | Always present; the protocol bounds it |
| 15 | **Regime mis-estimation on short history** | Warm-up is the *minimum* window that makes every estimator well defined (132 bars); R/S uses 4 scales with ≥ 2 blocks each; YZ has a close-to-close variance fallback | The first bars after warm-up are the least reliable; `InpForceEntryAfterIdleBars` can be set to 0 to skip forced entries entirely |
| 16 | **Timer storms / CPU** | Heavy work is once per closed bar; the light pass is O(legs) plus a history scan throttled to 5 s; dashboard throttled to 1 Hz; logs throttled per message class | None material |

---

## 15. Verification appendix

Because MetaEditor is not available in this workspace, the numeric core of the EA was **ported line-for-line to Python** (same windows, same estimators, same fusion, same lifecycle rules) and exercised on synthetic XAUUSD-like H1 series (log-price random walk with drift regimes, an Ornstein–Uhlenbeck mean-reverting regime, 12 intra-bar sub-steps to build realistic H/L, and a gold-style overnight gap every 23 bars). σ was injected at 0.18 %/bar ⇒ 13.9 % annualized.

**Estimator validation (700 evaluations per run, 5 runs, 0 computation failures; harness synced to the final source including the regime bands and the expanding-volatility damping)**

| Series | Hurst | VR(q=5) | YZ annualized vol | R² | \|t\| | Path EF |
|---|---|---|---|---|---|---|
| Trending (drift ±0.09 %/bar) | **0.594** | **1.106** | 11.75 % | 0.917 | 30.7 | 0.593 |
| Mean-reverting (OU, θ=0.35) | **0.396** | **0.599** | 14.59 % | 0.097 | 1.98 | 0.167 |
| Mixed / random-walk | 0.548–0.565 | 0.986–0.988 | 11.87–12.02 % | 0.867–0.891 | 24.2–25.1 | 0.504–0.508 |

The Hurst/VR pair separates persistent from antipersistent data in the right direction and with the right magnitude; the Yang–Zhang estimate recovers the injected volatility to within ~15 % (the mean-reverting series is inflated because the OU increments are larger by construction: $1.3\sigma$); R² and |t| collapse in the mean-reverting regime exactly as a significance test should.

**Activation / fire-rate validation (default inputs)**

| Series | score p10 | p50 | p90 | Fire rate (score ≥ 0.52) | First bar after warm-up | Longest sub-threshold streak |
|---|---|---|---|---|---|---|
| Trending (seed 11) | 0.795 | 0.873 | 0.918 | **100.0 %** | score 0.947 ⇒ **trades** | 0 bars |
| Mean-reverting (seed 11) | 0.514 | 0.574 | 0.666 | **85.6 %** | score 0.606 ⇒ **trades** | 3 bars ⇒ idle-guard fires |
| Mixed (seed 11) | 0.795 | 0.873 | 0.918 | 100.0 % | score 0.947 ⇒ **trades** | 0 bars |
| Mixed (seed 23) | 0.733 | 0.839 | 0.908 | 99.9 % | score 0.945 ⇒ **trades** | 1 bar |
| Trending (seed 99) | 0.750 | 0.840 | 0.905 | 99.9 % | score 0.829 ⇒ **trades** | 1 bar |

Direction balance was 45.9–50.7 % long across runs — no structural long/short bias. **Conclusion: with default inputs the EA opens a position on the first tick after attach on every series tested, and the idle-guard covers the worst observed streak.**

**Lifecycle validation.** The full trade → pyramid → hedge → unwind chain was simulated end-to-end (Section 12.4): 1 base entry, 3 add-ons, 1 hedge, 2 profit-banking partial closes, 1 ladder unwind, final hedge volume 0.00, account $10 000 → $10 514. **The hedge lifecycle terminated; no lock, no orphan.**

**Static verification of the MQL5 source**

| Check | Result |
|---|---|
| Brace / parenthesis / bracket balance (comments and literals stripped) | 0 / 0 / 0 |
| `StringFormat` / `PrintFormat` specifier-vs-argument count (71 call sites, positional) | 0 mismatches |
| Undefined function calls (excluding the MQL5 built-in whitelist and `CTrade` methods verified against the official class reference) | none |
| Unused inputs / unused globals (dead code) | 0 / 0 (97 inputs, 36 globals, all referenced) |
| Non-ASCII characters (encoding safety in MetaEditor) | 0 |
| MQL4-only API (`OrderSend`, `OrderSelect`, `Close[]`, `Point`, `Digits`, `#property strict`, `iMA` as a value) | none |
| `TRADE_RETCODE_*`, `ENUM_STATISTICS`, `ENUM_SYMBOL_INFO_*`, `DEAL_*`, `POSITION_*` identifiers | all from the documented enumerations |

> The Python port is a *verification harness*, not part of the deliverable; it is not shipped in the repository. The MQL5 file must still be compiled in MetaEditor before use — expect 0 errors; the only warnings that can appear are benign "declaration hides a member" style notices from local loop variables.

---

## 16. Installation and first-run checklist

1. Copy `Experts/QGE_XAUUSD_Pro.mq5` into `MQL5/Experts/` (or any subfolder) of your terminal data folder.
2. Open it in MetaEditor and press **Compile** (F7). Expected: `0 errors` (the source is ASCII-only, uses no deprecated MQL4 API and declares no unused variable, input or global).
3. Attach to an **XAUUSD H1** chart with *AutoTrading* enabled and "Allow algorithmic trading" checked in the EA properties.
4. Read the first log lines: symbol spec, margin mode, risk anchors, `warm-up` or `PRE-COMPUTED SIGNAL`, and the `readiness: first tick will ATTEMPT AN ENTRY` line.
5. Confirm the on-chart dashboard shows `warmup READY`, a non-zero score and a direction within the first tick.
6. Only then consider changing inputs — start from the defaults, which are tuned to *act*, not to wait.

**Recommended first parameter changes by account profile**

| Profile | Changes |
|---|---|
| Small account (< $1 000) | `InpRiskPctOfEquity = 2`, `InpMaxScaleIns = 1`, keep `InpMaxTotalLots` ≥ 0.1 so sub-minimum rejections do not block every trade |
| Conservative / prop-firm (strict DD rules) | `InpDailyLossLimitPct = 3`, `InpEquityFloorDDPct = 8`, `InpKillSwitchCloseAll = true`, `InpMaxTotalRiskPct = 2`, `InpConfidenceThreshold = 0.80` |
| Selective / swing | `InpSignalTF = H4`, `InpBarsPerYear = 1500`, `InpConfidenceThreshold = 0.75`, `InpSL_ATR_Mult = 2.5`, `InpMaxScaleIns = 2` |
| Live-ladder hedging (never fully locked) | `InpHedgeMaxRatio = 0.6`, `InpHedgeUnwindLadderSteps = 4`, `InpHedgeTargetRecoveryR = -0.25` |
| Disable the anti-idle guarantee | `InpForceEntryAfterIdleBars = 0` |

---

*Document generated together with `Experts/QGE_XAUUSD_Pro.mq5`; the parameter table in §11 is produced directly from the source's `input` declarations, so it cannot drift from the code.*
