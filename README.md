# Test-test
## QGE_XAUUSD_Pro — quantitative XAUUSD Expert Advisor (MQL5)

This repository now also contains a production-grade MetaTrader 5 Expert Advisor for gold,
built on statistical microstructure rather than classic lagging indicators.

| File | What it is |
|---|---|
| [`Experts/QGE_XAUUSD_Pro.mq5`](Experts/QGE_XAUUSD_Pro.mq5) | Single-file, compile-ready MQL5 EA (Yang–Zhang/Garman–Klass volatility regime, variance-ratio + R/S Hurst persistence, rolling OLS t-statistic trend with R², OLS-residual z-score mean reversion, order-flow microstructure trigger, probabilistic fusion, ATR-normalized geometric-decay pyramiding with fractional-Kelly caps, and a full-lifecycle intelligent hedge) |
| [`docs/QGE_XAUUSD_Whitepaper.md`](docs/QGE_XAUUSD_Whitepaper.md) | Strategy whitepaper: thesis, every formula, all 97 inputs, worked risk/hedge math, backtesting + walk-forward protocol, failure-mode register, verification results |

Copy the `.mq5` into `MQL5/Experts/`, compile in MetaEditor (expected: 0 errors) and attach it to an
XAUUSD H1 chart on a **hedging** account. The EA pre-computes its signal in `OnInit` and evaluates an
entry on the very first tick.
