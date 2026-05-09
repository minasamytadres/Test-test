// ============================================
// MQL5 Backtest Engine - Fixed for CORS
// Works on GitHub Pages, iPhone Safari, etc.
// ============================================

// ---- CORS Proxy ----
const CORS_PROXY = 'https://corsproxy.io/?';

// ---- Symbol Config ----
const SymbolConfig = {
    isGold: (s) => /XAU|GOLD|GC=/i.test(s),
    isJPY: (s) => /JPY/i.test(s),
    pointSize: (s) => SymbolConfig.isGold(s) ? 0.01 : (SymbolConfig.isJPY(s) ? 0.001 : 0.0001),
    spread: (s) => SymbolConfig.isGold(s) ? 0.25 : (SymbolConfig.isJPY(s) ? 0.008 : 0.00018),
    contractSize: (s) => SymbolConfig.isGold(s) ? 100 : 100000,
    yahooSymbol: (s) => {
        const u = s.toUpperCase().trim();
        if (u === 'XAUUSD' || u === 'GOLD') return 'GC=F';
        if (u.includes('=')) return s;
        return s + '=X';
    }
};

// ---- Logger ----
function log(msg) {
    const el = document.getElementById('log');
    const time = new Date().toLocaleTimeString('ar');
    el.innerHTML += time + ' ' + msg + '<br>';
    el.scrollTop = el.scrollHeight;
}

// ---- Sample Gold Data (Fallback) ----
function getSampleGoldData() {
    log('⚠️ استخدام بيانات نموذجية للذهب (fallback)');
    const data = [];
    const basePrice = 2350;
    const now = new Date();
    for (let i = 500; i >= 0; i--) {
        const date = new Date(now.getTime() - i * 15 * 60 * 1000);
        const trend = Math.sin(i / 50) * 30;
        const noise = (Math.random() - 0.5) * 10;
        const close = basePrice + trend + noise;
        const open = close + (Math.random() - 0.5) * 5;
        const high = Math.max(open, close) + Math.random() * 3;
        const low = Math.min(open, close) - Math.random() * 3;
        data.push({ date, open, high, low, close, volume: Math.floor(Math.random() * 5000 + 1000) });
    }
    return data;
}

// ---- Sample EURUSD Data (Fallback) ----
function getSampleEURUSDData() {
    log('⚠️ استخدام بيانات نموذجية لـ EURUSD (fallback)');
    const data = [];
    const basePrice = 1.0850;
    const now = new Date();
    for (let i = 500; i >= 0; i--) {
        const date = new Date(now.getTime() - i * 15 * 60 * 1000);
        const trend = Math.sin(i / 50) * 0.02;
        const noise = (Math.random() - 0.5) * 0.005;
        const close = basePrice + trend + noise;
        const open = close + (Math.random() - 0.5) * 0.002;
        const high = Math.max(open, close) + Math.random() * 0.003;
        const low = Math.min(open, close) - Math.random() * 0.003;
        data.push({ date, open, high, low, close, volume: Math.floor(Math.random() * 3000 + 500) });
    }
    return data;
}

// ---- Yahoo Finance Data Fetch ----
async function fetchYahooData(symbol, interval, range) {
    const ySym = SymbolConfig.yahooSymbol(symbol);
    const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(ySym)}?interval=${interval}&range=${range}`;
    const proxyUrl = CORS_PROXY + encodeURIComponent(url);

    log('⏳ جاري تحميل البيانات...');
    log('🌐 الرابط: ' + ySym);

    try {
        const response = await fetch(proxyUrl, {
            headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)' },
            timeout: 15000
        });

        if (!response.ok) {
            if (response.status === 404) throw new Error('الزوج غير موجود في Yahoo Finance');
            throw new Error('خطأ في السيرفر: ' + response.status);
        }

        const data = await response.json();

        if (data.chart && data.chart.error) {
            throw new Error(data.chart.error.description || 'خطأ في بيانات Yahoo');
        }

        const result = data.chart && data.chart.result ? data.chart.result[0] : null;
        if (!result) throw new Error('لا توجد بيانات');

        const timestamps = result.timestamp || [];
        const quote = result.indicators && result.indicators.quote ? result.indicators.quote[0] : null;
        if (!quote) throw new Error('بيانات ناقصة');

        const bars = [];
        for (let i = 0; i < timestamps.length; i++) {
            const o = quote.open ? quote.open[i] : null;
            const h = quote.high ? quote.high[i] : null;
            const l = quote.low ? quote.low[i] : null;
            const c = quote.close ? quote.close[i] : null;
            const v = quote.volume ? quote.volume[i] : 0;

            if (o && h && l && c && h >= l && c >= l && c <= h && o >= l && o <= h) {
                bars.push({
                    date: new Date(timestamps[i] * 1000),
                    open: o, high: h, low: l, close: c, volume: v || 0
                });
            }
        }

        if (bars.length < 20) throw new Error('البيانات غير كافية (' + bars.length + ' شمعة)');

        bars.sort((a, b) => a.date - b.date);
        log('✅ تم تحميل ' + bars.length + ' شمعة من Yahoo Finance');
        return bars;

    } catch (err) {
        log('⚠️ فشل الاتصال: ' + err.message);
        log('🔄 جاري استخدام البيانات الاحتياطية...');

        // Fallback to sample data
        if (SymbolConfig.isGold(symbol)) {
            return getSampleGoldData();
        }
        return getSampleEURUSDData();
    }
}

// ---- Tick Generator ----
function generateTicks(bars, symbol) {
    const isGold = SymbolConfig.isGold(symbol);
    const ticks = [];

    for (let i = 0; i < bars.length; i++) {
        const bar = bars[i];
        const nextBar = bars[i + 1];
        const barDuration = nextBar ? Math.max((nextBar.date - bar.date) / 1000, 60) : 3600;
        const tickCount = Math.max(Math.min(Math.floor(bar.volume / 50), isGold ? 200 : 500), isGold ? 10 : 20);
        const timeStep = barDuration / tickCount;
        const spread = SymbolConfig.spread(symbol);

        const prices = generatePricePath(bar.open, bar.high, bar.low, bar.close, tickCount, isGold);

        for (let j = 0; j < tickCount; j++) {
            const tickTime = new Date(bar.date.getTime() + timeStep * j * 1000);
            const mid = prices[j];
            ticks.push({
                date: tickTime,
                bid: mid - spread / 2,
                ask: mid + spread / 2,
                volume: Math.max(Math.floor(bar.volume / tickCount), 1)
            });
        }
    }

    log('📊 تم توليد ' + ticks.length + ' تيك');
    return ticks;
}

function generatePricePath(open, high, low, close, count, isGold) {
    const prices = [open];
    let current = open;
    let hitHigh = false, hitLow = false;
    const volatility = (high - low) * (isGold ? 0.12 : 0.15);

    for (let i = 1; i < count - 1; i++) {
        const progress = i / count;
        const randomChange = (Math.random() - 0.5) * 2 * volatility;
        const trend = (close - current) * 0.15;
        current += randomChange + trend;
        current = Math.max(low * 0.9999, Math.min(high * 1.0001, current));

        if (!hitHigh && progress > 0.25 && progress < 0.75 && Math.random() < 0.25) {
            current = high; hitHigh = true;
        }
        if (!hitLow && progress > 0.25 && progress < 0.75 && Math.random() < 0.25) {
            current = low; hitLow = true;
        }
        prices.push(current);
    }
    prices.push(close);
    return prices;
}

// ---- MQL5 Transpiler ----
function transpileMQL5(code) {
    let js = code;

    // Remove comments
    js = js.replace(/\/\/.*$/gm, '');
    js = js.replace(/\/\*[\s\S]*?\*\//g, '');

    // input declarations
    js = js.replace(/input\s+(?:int|double|string|bool|datetime|color)\s+/g, 'var ');

    // type declarations
    js = js.replace(/(?:^|;|\{|\})\s*(?:int|double|string|bool|datetime|color)\s+([a-zA-Z_][a-zA-Z0-9_]*)/g, '$1var $1');

    // Functions
    js = js.replace(/void\s+OnTick\s*\(\s*\)/g, 'function onTick()');
    js = js.replace(/void\s+OnInit\s*\(\s*\)/g, 'function onInit()');
    js = js.replace(/void\s+OnDeinit\s*\(\s*\)/g, 'function onDeinit()');
    js = js.replace(/int\s+OnInit\s*\(\s*\)/g, 'function onInit()');
    js = js.replace(/void\s+OnTimer\s*\(\s*\)/g, 'function onTimer()');

    // MQL5 functions
    const reps = [
        ['OrdersTotal', 'engine.ordersTotal'],
        ['OrderSelect', 'engine.orderSelect'],
        ['OrderProfit', 'engine.orderProfit'],
        ['OrderTicket', 'engine.orderTicket'],
        ['OrderType', 'engine.orderType'],
        ['OrderLots', 'engine.orderLots'],
        ['OrderOpenPrice', 'engine.orderOpenPrice'],
        ['OrderClosePrice', 'engine.orderClosePrice'],
        ['OrderStopLoss', 'engine.orderStopLoss'],
        ['OrderTakeProfit', 'engine.orderTakeProfit'],
        ['OrderClose', 'engine.orderClose'],
        ['OrderSend', 'engine.orderSend'],
        ['iMA', 'engine.iMA'],
        ['iRSI', 'engine.iRSI'],
        ['AccountBalance', 'engine.accountBalance'],
        ['AccountEquity', 'engine.accountEquity'],
        ['AccountMargin', 'engine.accountMargin'],
        ['AccountFreeMargin', 'engine.accountFreeMargin'],
        ['Print', 'engine.print'],
        ['Comment', 'engine.comment'],
        ['_Symbol', 'engine.symbol'],
        ['Ask', 'engine.ask'],
        ['Bid', 'engine.bid'],
    ];

    for (const [mql5, jsEq] of reps) {
        js = js.split(mql5).join(jsEq);
    }

    // Arrays
    js = js.replace(/Close\[(\d+)\]/g, 'engine.close($1)');
    js = js.replace(/Open\[(\d+)\]/g, 'engine.open($1)');
    js = js.replace(/High\[(\d+)\]/g, 'engine.high($1)');
    js = js.replace(/Low\[(\d+)\]/g, 'engine.low($1)');
    js = js.replace(/Volume\[(\d+)\]/g, 'engine.volume($1)');
    js = js.replace(/Time\[(\d+)\]/g, 'engine.time($1)');

    // Constants
    js = js.replace(/\bOP_BUY\b/g, '0');
    js = js.replace(/\bOP_SELL\b/g, '1');
    js = js.replace(/\bPERIOD_M1\b/g, '1');
    js = js.replace(/\bPERIOD_M5\b/g, '5');
    js = js.replace(/\bPERIOD_M15\b/g, '15');
    js = js.replace(/\bPERIOD_M30\b/g, '30');
    js = js.replace(/\bPERIOD_H1\b/g, '60');
    js = js.replace(/\bPERIOD_H4\b/g, '240');
    js = js.replace(/\bPERIOD_D1\b/g, '1440');
    js = js.replace(/\bPERIOD_CURRENT\b/g, '0');
    js = js.replace(/\bMODE_SMA\b/g, '0');
    js = js.replace(/\bMODE_EMA\b/g, '1');
    js = js.replace(/\bPRICE_CLOSE\b/g, '0');
    js = js.replace(/\bPRICE_OPEN\b/g, '1');
    js = js.replace(/\bPRICE_HIGH\b/g, '2');
    js = js.replace(/\bPRICE_LOW\b/g, '3');
    js = js.replace(/\bSELECT_BY_POS\b/g, '1');
    js = js.replace(/\bSELECT_BY_TICKET\b/g, '0');
    js = js.replace(/\bMODE_TRADES\b/g, '0');
    js = js.replace(/\bMODE_HISTORY\b/g, '1');

    return js;
}

// ---- MQL5 Engine ----
class MQL5Engine {
    constructor(balance) {
        this.balance = balance;
        this.initialBalance = balance;
        this.equity = balance;
        this.margin = 0;
        this.currentTick = null;
        this.bars = [];
        this.symbol = '';
        this.trades = [];
        this.history = [];
        this.selectedTrade = null;
        this.ticketCounter = 1000;
        this.equityHistory = [];
    }

    get ask() { return this.currentTick ? this.currentTick.ask : 0; }
    get bid() { return this.currentTick ? this.currentTick.bid : 0; }

    update(tick, bars, symbol) {
        this.currentTick = tick;
        this.bars = bars;
        this.symbol = symbol;
        this.checkSLTP();
        this.calcEquity();
        this.equityHistory.push({ date: tick.date, equity: this.equity });
    }

    checkSLTP() {
        const toRemove = [];
        for (let i = 0; i < this.trades.length; i++) {
            const t = this.trades[i];
            if (t.closeTime) continue;

            let shouldClose = false;
            let closePrice = t.openPrice;

            if (t.stopLoss > 0) {
                if (t.type === 'buy' && this.currentTick.bid <= t.stopLoss) {
                    shouldClose = true; closePrice = t.stopLoss;
                } else if (t.type === 'sell' && this.currentTick.ask >= t.stopLoss) {
                    shouldClose = true; closePrice = t.stopLoss;
                }
            }

            if (!shouldClose && t.takeProfit > 0) {
                if (t.type === 'buy' && this.currentTick.bid >= t.takeProfit) {
                    shouldClose = true; closePrice = t.takeProfit;
                } else if (t.type === 'sell' && this.currentTick.ask <= t.takeProfit) {
                    shouldClose = true; closePrice = t.takeProfit;
                }
            }

            if (shouldClose) {
                t.closeTime = this.currentTick.date;
                t.closePrice = closePrice;
                t.profit = this.calcProfit(t, closePrice);
                this.balance += t.profit;
                this.history.push(Object.assign({}, t));
                toRemove.push(i);
            }
        }

        for (let i = toRemove.length - 1; i >= 0; i--) {
            this.trades.splice(toRemove[i], 1);
        }
    }

    calcProfit(trade, closePrice) {
        const diff = trade.type === 'buy' ? (closePrice - trade.openPrice) : (trade.openPrice - closePrice);
        const cs = SymbolConfig.contractSize(trade.symbol);
        const ps = SymbolConfig.pointSize(trade.symbol);
        return (diff / ps) * trade.lots * cs * ps;
    }

    calcEquity() {
        let floating = 0;
        for (const t of this.trades) {
            if (!t.closeTime) {
                const cp = t.type === 'buy' ? (this.currentTick ? this.currentTick.bid : 0) : (this.currentTick ? this.currentTick.ask : 0);
                floating += this.calcProfit(t, cp);
            }
        }
        this.equity = this.balance + floating;
    }

    orderSend(symbol, cmd, volume, price, slippage, stopLoss, takeProfit) {
        const ticket = this.ticketCounter++;
        const type = cmd === 0 ? 'buy' : 'sell';
        const openPrice = type === 'buy' ? (this.currentTick ? this.currentTick.ask : price) : (this.currentTick ? this.currentTick.bid : price);
        const ps = SymbolConfig.pointSize(symbol);
        const slippagePoints = slippage * ps;
        const finalPrice = type === 'buy' ? openPrice + slippagePoints : openPrice - slippagePoints;

        this.trades.push({
            ticket: ticket,
            openTime: this.currentTick ? this.currentTick.date : new Date(),
            closeTime: null,
            type: type,
            openPrice: finalPrice,
            closePrice: null,
            lots: volume,
            profit: null,
            symbol: symbol,
            stopLoss: stopLoss > 0 ? stopLoss : 0,
            takeProfit: takeProfit > 0 ? takeProfit : 0
        });

        this.margin += volume * SymbolConfig.contractSize(symbol) * 0.01;
        return ticket;
    }

    orderClose(ticket, lots, price, slippage) {
        const idx = this.trades.findIndex(t => t.ticket === ticket && !t.closeTime);
        if (idx === -1) return false;

        const trade = this.trades[idx];
        const closePrice = trade.type === 'buy' ? (this.currentTick ? this.currentTick.bid : price) : (this.currentTick ? this.currentTick.ask : price);

        trade.closeTime = this.currentTick ? this.currentTick.date : null;
        trade.closePrice = closePrice;
        trade.profit = this.calcProfit(trade, closePrice);
        this.balance += trade.profit;
        this.margin -= trade.lots * SymbolConfig.contractSize(trade.symbol) * 0.01;

        this.history.push(Object.assign({}, trade));
        this.trades.splice(idx, 1);
        return true;
    }

    orderSelect(index, select, pool) {
        if (select === 1) {
            if (pool === 0) {
                const openTrades = this.trades.filter(t => !t.closeTime);
                if (index < openTrades.length) { this.selectedTrade = openTrades[index]; return true; }
            } else {
                if (index < this.history.length) { this.selectedTrade = this.history[index]; return true; }
            }
        } else {
            const t = this.trades.find(t => t.ticket === index) || this.history.find(t => t.ticket === index);
            if (t) { this.selectedTrade = t; return true; }
        }
        return false;
    }

    orderProfit() { return this.selectedTrade ? this.selectedTrade.profit : 0; }
    orderTicket() { return this.selectedTrade ? this.selectedTrade.ticket : 0; }
    orderType() { return this.selectedTrade && this.selectedTrade.type === 'buy' ? 0 : 1; }
    orderLots() { return this.selectedTrade ? this.selectedTrade.lots : 0; }
    orderOpenPrice() { return this.selectedTrade ? this.selectedTrade.openPrice : 0; }
    orderClosePrice() { return this.selectedTrade ? this.selectedTrade.closePrice : 0; }
    orderStopLoss() { return this.selectedTrade ? this.selectedTrade.stopLoss : 0; }
    orderTakeProfit() { return this.selectedTrade ? this.selectedTrade.takeProfit : 0; }

    iMA(symbol, timeframe, maPeriod, maShift, maMethod, appliedPrice, shift) {
        if (this.bars.length < maPeriod + shift + maShift) return 0;
        const endIdx = this.bars.length - 1 - shift - maShift;
        if (endIdx < maPeriod - 1) return 0;
        const startIdx = endIdx - maPeriod + 1;
        let sum = 0;
        for (let i = startIdx; i <= endIdx; i++) sum += this.getAppliedPrice(this.bars[i], appliedPrice);
        return sum / maPeriod;
    }

    iRSI(symbol, timeframe, period, appliedPrice, shift) {
        if (this.bars.length < period + shift + 1) return 50;
        const endIdx = this.bars.length - 1 - shift;
        if (endIdx < period) return 50;
        let gains = 0, losses = 0;
        for (let i = endIdx - period + 1; i <= endIdx; i++) {
            const curr = this.getAppliedPrice(this.bars[i], appliedPrice);
            const prev = this.getAppliedPrice(this.bars[i-1], appliedPrice);
            const change = curr - prev;
            if (change > 0) gains += change; else losses += Math.abs(change);
        }
        const avgGain = gains / period, avgLoss = losses / period;
        if (avgLoss === 0) return 100;
        const rs = avgGain / avgLoss;
        return 100 - (100 / (1 + rs));
    }

    getAppliedPrice(bar, ap) {
        switch(ap) {
            case 0: return bar.close;
            case 1: return bar.open;
            case 2: return bar.high;
            case 3: return bar.low;
            default: return bar.close;
        }
    }

    accountBalance() { return this.balance; }
    accountEquity() { return this.equity; }
    accountMargin() { return this.margin; }
    accountFreeMargin() { return this.equity - this.margin; }

    close(shift) { return shift < this.bars.length ? this.bars[this.bars.length - 1 - shift].close : 0; }
    open(shift) { return shift < this.bars.length ? this.bars[this.bars.length - 1 - shift].open : 0; }
    high(shift) { return shift < this.bars.length ? this.bars[this.bars.length - 1 - shift].high : 0; }
    low(shift) { return shift < this.bars.length ? this.bars[this.bars.length - 1 - shift].low : 0; }
    volume(shift) { return shift < this.bars.length ? this.bars[this.bars.length - 1 - shift].volume : 0; }
    time(shift) { return shift < this.bars.length ? this.bars[this.bars.length - 1 - shift].date.getTime() / 1000 : 0; }

    print(msg) { log('📝 ' + msg); }
    comment(msg) { log('💬 ' + msg); }
    ordersTotal() { return this.trades.filter(t => !t.closeTime).length; }

    closeAllTrades() {
        while (this.trades.length > 0) {
            const t = this.trades[0];
            const cp = t.type === 'buy' ? (this.currentTick ? this.currentTick.bid : t.openPrice) : (this.currentTick ? this.currentTick.ask : t.openPrice);
            t.closeTime = this.currentTick ? this.currentTick.date : null;
            t.closePrice = cp;
            t.profit = this.calcProfit(t, cp);
            this.balance += t.profit;
            this.margin -= t.lots * SymbolConfig.contractSize(t.symbol) * 0.01;
            this.history.push(Object.assign({}, t));
            this.trades.shift();
        }
        this.calcEquity();
    }

    generateReport() {
        const totalProfit = this.history.reduce((s, t) => s + (t.profit || 0), 0);
        const winning = this.history.filter(t => (t.profit || 0) > 0).length;
        const losing = this.history.filter(t => (t.profit || 0) < 0).length;

        let maxDD = 0, peak = this.initialBalance;
        for (const p of this.equityHistory) {
            if (p.equity > peak) peak = p.equity;
            const dd = peak > 0 ? (peak - p.equity) / peak * 100 : 0;
            if (dd > maxDD) maxDD = dd;
        }

        const grossProfit = this.history.filter(t => (t.profit || 0) > 0).reduce((s, t) => s + (t.profit || 0), 0);
        const grossLoss = Math.abs(this.history.filter(t => (t.profit || 0) < 0).reduce((s, t) => s + (t.profit || 0), 0));
        const profitFactor = grossLoss > 0 ? grossProfit / grossLoss : (grossProfit > 0 ? 999.99 : 0);

        const returns = [];
        for (let i = 1; i < this.equityHistory.length; i++) {
            const prev = this.equityHistory[i-1].equity;
            returns.push(prev > 0 ? (this.equityHistory[i].equity - prev) / prev : 0);
        }
        const avgRet = returns.reduce((s, r) => s + r, 0) / Math.max(returns.length, 1);
        const variance = returns.reduce((s, r) => s + Math.pow(r - avgRet, 2), 0) / Math.max(returns.length, 1);
        const stdDev = Math.sqrt(variance);
        const sharpe = stdDev > 0 ? (avgRet * Math.sqrt(252)) / stdDev : 0;

        return {
            initialBalance: this.initialBalance,
            finalBalance: this.balance,
            totalProfit: totalProfit,
            totalTrades: this.history.length,
            winningTrades: winning,
            losingTrades: losing,
            maxDrawdown: maxDD,
            profitFactor: profitFactor,
            sharpeRatio: sharpe,
            equityCurve: this.equityHistory,
            trades: this.history
        };
    }
}

// ---- Main Backtest Function ----
async function runBacktest() {
    const btn = document.getElementById('runBtn');
    const progressContainer = document.getElementById('progressContainer');
    const progressFill = document.getElementById('progressFill');
    const progressPercent = document.getElementById('progressPercent');
    const tickCount = document.getElementById('tickCount');

    btn.disabled = true;
    btn.textContent = '⏳ جاري الاختبار...';
    progressContainer.style.display = 'block';
    document.getElementById('log').innerHTML = '';

    try {
        const symbol = document.getElementById('symbol').value.toUpperCase().trim();
        const timeframe = document.getElementById('timeframe').value;
        const range = document.getElementById('range').value;
        const balance = parseFloat(document.getElementById('balance').value) || 10000;
        const code = document.getElementById('codeEditor').value;

        log('🚀 بدء المحاكاة لـ ' + symbol);

        // Fetch data
        const bars = await fetchYahooData(symbol, timeframe, range);
        const ticks = generateTicks(bars, symbol);

        // Setup engine
        const engine = new MQL5Engine(balance);
        const jsCode = transpileMQL5(code);

        log('⚙️ جاري تهيئة المحرك...');

        // Create JS function
        const setupCode = `
            var OP_BUY = 0, OP_SELL = 1;
            var PERIOD_M1 = 1, PERIOD_M5 = 5, PERIOD_M15 = 15, PERIOD_M30 = 30;
            var PERIOD_H1 = 60, PERIOD_H4 = 240, PERIOD_D1 = 1440, PERIOD_CURRENT = 0;
            var MODE_SMA = 0, MODE_EMA = 1;
            var PRICE_CLOSE = 0, PRICE_OPEN = 1, PRICE_HIGH = 2, PRICE_LOW = 3;
            var SELECT_BY_POS = 1, SELECT_BY_TICKET = 0;
            var MODE_TRADES = 0, MODE_HISTORY = 1;
            ${jsCode}
        `;

        // Execute setup
        const onTickFunc = new Function('engine', setupCode + '; return typeof onTick === "function" ? onTick : null;')(engine);
        const onInitFunc = new Function('engine', setupCode + '; return typeof onInit === "function" ? onInit : null;')(engine);
        const onDeinitFunc = new Function('engine', setupCode + '; return typeof onDeinit === "function" ? onDeinit : null;')(engine);

        if (onInitFunc) {
            log('🔧 تشغيل OnInit...');
            onInitFunc.call(engine);
        }

        // Run simulation
        const totalTicks = ticks.length;
        const reportInterval = Math.max(Math.floor(totalTicks / 100), 1);

        log('📊 معالجة ' + totalTicks + ' تيك...');

        for (let i = 0; i < totalTicks; i++) {
            engine.update(ticks[i], bars, symbol);
            if (onTickFunc) onTickFunc.call(engine);

            if (i % reportInterval === 0) {
                const prog = i / totalTicks;
                progressFill.style.width = (prog * 100) + '%';
                progressPercent.textContent = Math.round(prog * 100) + '%';
                tickCount.textContent = 'تيكات: ' + i;
                await new Promise(r => setTimeout(r, 0));
            }
        }

        if (onDeinitFunc) onDeinitFunc.call(engine);
        engine.closeAllTrades();

        progressFill.style.width = '100%';
        progressPercent.textContent = '100%';
        tickCount.textContent = 'تيكات: ' + totalTicks;

        const result = engine.generateReport();
        log('✅ اكتمل الاختبار!');
        log('💰 الربح: $' + result.totalProfit.toFixed(2));

        showResults(result);

    } catch (err) {
        log('❌ خطأ: ' + err.message);
        alert('خطأ: ' + err.message);
    } finally {
        btn.disabled = false;
        btn.textContent = '▶️ بدء المحاكاة';
    }
}

// ---- Show Results ----
function showResults(result) {
    const modal = document.getElementById('resultModal');
    const summaryCard = document.getElementById('summaryCard');

    const isPositive = result.finalBalance >= result.initialBalance;
    summaryCard.className = 'summary-card ' + (isPositive ? 'positive' : 'negative');

    document.getElementById('finalBalance').textContent = '$' + result.finalBalance.toFixed(2);
    document.getElementById('finalBalance').className = 'big-number ' + (isPositive ? 'green' : 'red');
    document.getElementById('netProfit').textContent = 'صافي الربح: $' + result.totalProfit.toFixed(2);
    document.getElementById('netProfit').style.color = result.totalProfit >= 0 ? '#3FB950' : '#F85149';

    document.getElementById('totalTrades').textContent = result.totalTrades;
    document.getElementById('winningTrades').textContent = result.winningTrades;
    document.getElementById('losingTrades').textContent = result.losingTrades;

    const winRate = result.totalTrades > 0 ? (result.winningTrades / result.totalTrades * 100).toFixed(1) : 0;
    document.getElementById('winRate').textContent = winRate + '%';
    document.getElementById('winRate').className = 'stat-value ' + (result.winningTrades >= result.losingTrades ? 'green' : 'red');

    const roi = result.initialBalance > 0 ? ((result.finalBalance - result.initialBalance) / result.initialBalance * 100).toFixed(2) : 0;
    document.getElementById('roi').textContent = roi + '%';
    document.getElementById('roi').className = 'stat-value ' + (roi >= 0 ? 'green' : 'red');

    document.getElementById('maxDD').textContent = result.maxDrawdown.toFixed(2) + '%';
    document.getElementById('profitFactor').textContent = result.profitFactor.toFixed(2);
    document.getElementById('profitFactor').className = 'stat-value ' + (result.profitFactor >= 1 ? 'green' : 'red');

    const avgProfit = result.totalTrades > 0 ? result.totalProfit / result.totalTrades : 0;
    document.getElementById('avgProfit').textContent = '$' + avgProfit.toFixed(2);
    document.getElementById('avgProfit').className = 'stat-value ' + (avgProfit >= 0 ? 'green' : 'red');

    document.getElementById('sharpe').textContent = result.sharpeRatio.toFixed(2);
    document.getElementById('sharpe').className = 'stat-value ' + (result.sharpeRatio > 0 ? 'green' : 'red');
    document.getElementById('initialBal').textContent = '$' + result.initialBalance.toFixed(0);

    drawEquityChart(result.equityCurve);
    renderTrades(result.trades);

    modal.style.display = 'block';
    document.body.style.overflow = 'hidden';
}

function closeModal() {
    document.getElementById('resultModal').style.display = 'none';
    document.body.style.overflow = 'auto';
}

// ---- Draw Equity Chart ----
function drawEquityChart(equityCurve) {
    const canvas = document.getElementById('equityChart');
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();

    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    const w = rect.width, h = rect.height;
    const padding = 30;

    const minEq = Math.min(...equityCurve.map(p => p.equity));
    const maxEq = Math.max(...equityCurve.map(p => p.equity));
    const range = maxEq - minEq || 1;

    ctx.clearRect(0, 0, w, h);

    // Grid
    ctx.strokeStyle = '#30363D';
    ctx.lineWidth = 0.5;
    for (let i = 0; i <= 4; i++) {
        const y = padding + (h - 2 * padding) * i / 4;
        ctx.beginPath();
        ctx.moveTo(padding, y);
        ctx.lineTo(w - padding, y);
        ctx.stroke();
    }

    // Line
    ctx.strokeStyle = '#00D4AA';
    ctx.lineWidth = 2;
    ctx.beginPath();

    for (let i = 0; i < equityCurve.length; i++) {
        const x = padding + (w - 2 * padding) * i / (equityCurve.length - 1);
        const y = padding + (h - 2 * padding) * (1 - (equityCurve[i].equity - minEq) / range);
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    }
    ctx.stroke();

    // Fill
    ctx.fillStyle = 'rgba(0, 212, 170, 0.1)';
    ctx.lineTo(w - padding, h - padding);
    ctx.lineTo(padding, h - padding);
    ctx.closePath();
    ctx.fill();

    // Labels
    ctx.fillStyle = '#8B949E';
    ctx.font = '10px sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText('$' + maxEq.toFixed(0), padding - 5, padding + 10);
    ctx.fillText('$' + minEq.toFixed(0), padding - 5, h - padding);
}

// ---- Render Trades ----
function renderTrades(trades) {
    const container = document.getElementById('tradesList');
    container.innerHTML = '';

    const recent = trades.slice(-50).reverse();

    for (const t of recent) {
        const div = document.createElement('div');
        div.className = 'trade-item';
        const profitClass = (t.profit || 0) >= 0 ? 'green' : 'red';
        const typeClass = t.type === 'buy' ? 'buy' : 'sell';

        div.innerHTML = `
            <div class="trade-info">
                <span class="trade-type ${typeClass}"></span>
                <strong>#${t.ticket} ${t.type === 'buy' ? 'شراء' : 'بيع'}</strong>
                <div class="trade-details">
                    د: ${t.openPrice.toFixed(5)} ${t.closePrice ? '• خ: ' + t.closePrice.toFixed(5) : ''} • ${t.lots.toFixed(2)} لوت
                </div>
            </div>
            <div class="trade-profit ${profitClass}">
                $${(t.profit || 0).toFixed(2)}
            </div>
        `;
        container.appendChild(div);
    }
}

// ---- Presets ----
const presets = {
    eurusd: {
        symbol: 'EURUSD',
        code: `input int MA_Period = 14;
input double LotSize = 0.1;

void OnTick() {
    double ma = iMA(_Symbol, PERIOD_H1, MA_Period, 0, MODE_SMA, PRICE_CLOSE, 0);

    if(Close[0] > ma && OrdersTotal() == 0) {
        OrderSend(_Symbol, OP_BUY, LotSize, Ask, 3, 0, 0);
    }

    if(Close[0] < ma && OrdersTotal() > 0) {
        OrderSelect(0, SELECT_BY_POS, MODE_TRADES);
        OrderClose(OrderTicket(), OrderLots(), Bid, 3);
    }
}`
    },
    xauusd: {
        symbol: 'XAUUSD',
        timeframe: '15m',
        code: `input int FastMA = 10;
input int SlowMA = 50;
input double LotSize = 0.1;
input double StopLoss = 5.0;
input double TakeProfit = 10.0;

void OnTick() {
    double fastMA = iMA(_Symbol, PERIOD_M15, FastMA, 0, MODE_SMA, PRICE_CLOSE, 0);
    double slowMA = iMA(_Symbol, PERIOD_M15, SlowMA, 0, MODE_SMA, PRICE_CLOSE, 0);

    if(fastMA > slowMA && OrdersTotal() == 0) {
        OrderSend(_Symbol, OP_BUY, LotSize, Ask, 5, Bid - StopLoss, Bid + TakeProfit);
    }

    if(fastMA < slowMA && OrdersTotal() > 0) {
        OrderSelect(0, SELECT_BY_POS, MODE_TRADES);
        if(OrderType() == OP_BUY) {
            OrderClose(OrderTicket(), OrderLots(), Bid, 5);
        }
    }
}`
    },
    gbpusd: {
        symbol: 'GBPUSD',
        code: `input int RSI_Period = 14;
input double LotSize = 0.1;
input double RSI_Oversold = 30;
input double RSI_Overbought = 70;

void OnTick() {
    double rsi = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE, 0);

    if(rsi < RSI_Oversold && OrdersTotal() == 0) {
        OrderSend(_Symbol, OP_BUY, LotSize, Ask, 3, 0, 0);
    }

    if(rsi > RSI_Overbought && OrdersTotal() > 0) {
        OrderSelect(0, SELECT_BY_POS, MODE_TRADES);
        OrderClose(OrderTicket(), OrderLots(), Bid, 3);
    }
}`
    },
    usdjpy: {
        symbol: 'USDJPY',
        code: `input int MA_Fast = 10;
input int MA_Slow = 30;
input double LotSize = 0.1;

void OnTick() {
    double fast = iMA(_Symbol, PERIOD_H1, MA_Fast, 0, MODE_SMA, PRICE_CLOSE, 0);
    double slow = iMA(_Symbol, PERIOD_H1, MA_Slow, 0, MODE_SMA, PRICE_CLOSE, 0);

    if(fast > slow && OrdersTotal() == 0) {
        OrderSend(_Symbol, OP_BUY, LotSize, Ask, 3, 0, 0);
    }
    if(fast < slow && OrdersTotal() > 0) {
        OrderSelect(0, SELECT_BY_POS, MODE_TRADES);
        OrderClose(OrderTicket(), OrderLots(), Bid, 3);
    }
}`
    }
};

function loadPreset(name) {
    const p = presets[name];
    if (!p) return;
    document.getElementById('symbol').value = p.symbol;
    document.getElementById('codeEditor').value = p.code;
    if (p.timeframe) document.getElementById('timeframe').value = p.timeframe;
    log('⚡ تم تحميل إعدادات ' + p.symbol);
}

// ---- Install Banner ----
function dismissBanner() {
    document.getElementById('installBanner').style.display = 'none';
    localStorage.setItem('bannerDismissed', '1');
}

if (!localStorage.getItem('bannerDismissed') && !window.matchMedia('(display-mode: standalone)').matches) {
    setTimeout(() => {
        document.getElementById('installBanner').style.display = 'block';
    }, 2000);
}
