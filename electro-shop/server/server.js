'use strict';
/* =====================================================================
 * server/server.js — خادم Express لواجهات API + خدمة الواجهة
 * يعمل محليًا على 127.0.0.1:3000 افتراضيًا
 * ===================================================================== */

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const express = require('express');
const E = require('../engine.js');
const DB = require('./db.js');

const DATA_DIR = process.env.ELECTRO_DATA || path.join(__dirname, '..', 'data');
const BACKUP_DIR = path.join(DATA_DIR, 'backups');
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
if (!fs.existsSync(BACKUP_DIR)) fs.mkdirSync(BACKUP_DIR, { recursive: true });

const DB_PATH = process.env.ELECTRO_DB || path.join(DATA_DIR, 'shop.db');
const useSample = process.argv.indexOf('--sample') !== -1 || process.env.ELECTRO_SAMPLE === '1';

const store = new DB.SqliteStore(DB_PATH);
if (useSample) DB.seedSample(store);

const app = express();
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, '..', 'public')));

/* ------------------------- الجلسات (كوكيز موقعة HMAC) ------------------------- */

const SECRET = store.getSetting('session_secret');

function sign(payload) {
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const mac = crypto.createHmac('sha256', SECRET).update(body).digest('base64url');
  return body + '.' + mac;
}

function unsign(cookie) {
  if (!cookie || typeof cookie !== 'string' || cookie.indexOf('.') < 0) return null;
  const i = cookie.lastIndexOf('.');
  const body = cookie.slice(0, i);
  const mac = cookie.slice(i + 1);
  const calc = crypto.createHmac('sha256', SECRET).update(body).digest('base64url');
  const a = Buffer.from(mac);
  const b = Buffer.from(calc);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    if (!payload.exp || payload.exp < Date.now()) return null;
    return payload;
  } catch (e) { return null; }
}

function parseCookies(req) {
  const out = {};
  const h = req.headers.cookie;
  if (!h) return out;
  h.split(';').forEach(function (p) {
    const i = p.indexOf('=');
    if (i > 0) out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim());
  });
  return out;
}

function currentUser(req) {
  const c = parseCookies(req);
  if (!c.sid) return null;
  const payload = unsign(c.sid);
  if (!payload) return null;
  const u = store.db.prepare('SELECT id, username, full_name, role, force_change, is_active FROM users WHERE id = ?').get(payload.uid);
  if (!u || !u.is_active) return null;
  return u;
}

function requireAuth(req, res, next) {
  const u = currentUser(req);
  if (!u) return res.status(401).json({ error: 'غير مسجل الدخول' });
  req.user = u;
  next();
}

function requirePerm(perm) {
  return function (req, res, next) {
    try {
      E.assertCan(req.user.role, perm);
      next();
    } catch (e) {
      res.status(403).json({ error: e.message, code: e.code });
    }
  };
}

const cookieOpts = { httpOnly: true, sameSite: 'lax', path: '/' };

/* ------------------------- أدوات ------------------------- */

function num(v, dflt) {
  const n = Number(v);
  return Number.isFinite(n) ? n : (dflt || 0);
}

function audit(req, action, entity, entityId, details) {
  store.audit(req.user, action, entity, entityId, details);
}

function toCSV(rows) {
  if (!rows || rows.length === 0) return '\uFEFF';
  const cols = Object.keys(rows[0]);
  const esc = function (v) {
    const s = v == null ? '' : String(v);
    return /[",\n;]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  const lines = [cols.join(',')];
  rows.forEach(function (r) {
    lines.push(cols.map(function (c) { return esc(r[c]); }).join(','));
  });
  return '\uFEFF' + lines.join('\r\n');
}

function sendRows(req, res, rows, filename) {
  if (req.query.format === 'csv') {
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="' + filename + '"');
    return res.send(toCSV(rows));
  }
  res.json(rows);
}

/* ------------------------- المصادقة ------------------------- */

app.post('/api/login', function (req, res) {
  const { username, password } = req.body || {};
  const u = store.db.prepare('SELECT * FROM users WHERE username = ?').get(String(username || ''));
  if (!u || !u.is_active || !DB.verifyPassword(password || '', u.password_hash)) {
    return res.status(401).json({ error: 'اسم المستخدم أو كلمة المرور غير صحيحة' });
  }
  const payload = { uid: u.id, role: u.role, exp: Date.now() + 12 * 3600 * 1000 };
  res.setHeader('Set-Cookie', 'sid=' + encodeURIComponent(sign(payload)) + '; Path=/; HttpOnly; SameSite=Lax');
  store.audit(u, 'login', 'user', u.id, null);
  res.json({ id: u.id, username: u.username, full_name: u.full_name, role: u.role, force_change: !!u.force_change });
});

app.post('/api/logout', requireAuth, function (req, res) {
  audit(req, 'logout', 'user', req.user.id, null);
  res.setHeader('Set-Cookie', 'sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0');
  res.json({ ok: true });
});

app.post('/api/change-password', requireAuth, function (req, res) {
  const { oldPassword, newPassword } = req.body || {};
  const u = store.db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
  if (!DB.verifyPassword(oldPassword || '', u.password_hash)) {
    return res.status(400).json({ error: 'كلمة المرور الحالية غير صحيحة' });
  }
  if (!newPassword || String(newPassword).length < 6) {
    return res.status(400).json({ error: 'كلمة المرور الجديدة يجب أن تكون 6 أحرف على الأقل' });
  }
  store.db.prepare('UPDATE users SET password_hash = ?, force_change = 0, updated_at = ? WHERE id = ?')
    .run(DB.hashPassword(newPassword), DB.nowISO(), u.id);
  audit(req, 'change-password', 'user', u.id, null);
  res.json({ ok: true });
});

app.get('/api/me', requireAuth, function (req, res) { res.json(req.user); });

app.get('/api/permissions', requireAuth, function (req, res) {
  res.json({ role: req.user.role, perms: E.ROLES[req.user.role] || [] });
});

/* ------------------------- الإعدادات ------------------------- */

app.get('/api/settings', requireAuth, function (req, res) {
  const rows = store.db.prepare('SELECT key, value FROM settings').all();
  const out = {};
  rows.forEach(function (r) { if (r.key !== 'session_secret') out[r.key] = r.value; });
  res.json(out);
});

const ALLOWED_SETTINGS = {
  shop_name: 1, currency: 1, default_tax_pct: 1, max_discount_pct: 1,
  credit_limit_default: 1, allow_below_cost: 1, address: 1, phone: 1, receipt_footer: 1
};

app.put('/api/settings', requireAuth, requirePerm('settings.write'), function (req, res) {
  const applied = {};
  Object.keys(req.body || {}).forEach(function (k) {
    if (ALLOWED_SETTINGS[k]) {
      store.setSetting(k, req.body[k]);
      applied[k] = req.body[k];
    }
  });
  audit(req, 'settings.update', 'settings', null, applied);
  res.json({ ok: true });
});

/* ------------------------- المنتجات والفئات ------------------------- */

app.get('/api/products', requireAuth, function (req, res) {
  const rows = store.db.prepare(
    'SELECT p.*, c.name AS category_name FROM products p ' +
    'LEFT JOIN categories c ON c.id = p.category_id ORDER BY p.name').all();
  rows.forEach(function (p) { p.stock = store.stockOf(p.id); });
  sendRows(req, res, rows, 'products.csv');
});

app.post('/api/products', requireAuth, requirePerm('products.write'), function (req, res) {
  const b = req.body || {};
  try {
    E.assertUnit(b.unit || 'pcs');
    E.assertPrice(num(b.sale_price), 'سعر البيع');
    E.assertPrice(num(b.cost_price), 'سعر التكلفة');
    if (!b.name || !b.sku) throw new E.EngineError('E_REQUIRED', 'الاسم والرمز مطلوبان');
    const info = store.db.prepare(
      'INSERT INTO products (sku, name, category_id, unit, barcode, cost_price, sale_price, tax_pct, reorder_level, avg_cost, created_at, updated_at) ' +
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?)')
      .run(String(b.sku), String(b.name), b.category_id || null, b.unit || 'pcs', b.barcode || null,
           E.roundMoney(num(b.cost_price)), E.roundMoney(num(b.sale_price)),
           num(b.tax_pct), num(b.reorder_level), E.roundMoney(num(b.cost_price)),
           DB.nowISO(), DB.nowISO());
    audit(req, 'product.create', 'product', info.lastInsertRowid, { sku: b.sku });
    res.json({ id: info.lastInsertRowid });
  } catch (e) {
    if (String(e.message).indexOf('UNIQUE') !== -1) {
      return res.status(400).json({ error: 'الرمز (SKU) مستخدم بالفعل' });
    }
    res.status(400).json({ error: e.message, code: e.code });
  }
});

app.put('/api/products/:id', requireAuth, requirePerm('products.write'), function (req, res) {
  const b = req.body || {};
  const p = store.db.prepare('SELECT * FROM products WHERE id = ?').get(req.params.id);
  if (!p) return res.status(404).json({ error: 'الصنف غير موجود' });
  try {
    const newCost = E.roundMoney(num(b.cost_price, p.cost_price));
    const newSale = E.roundMoney(num(b.sale_price, p.sale_price));
    store.db.prepare(
      'UPDATE products SET name = ?, category_id = ?, unit = ?, barcode = ?, cost_price = ?, ' +
      'sale_price = ?, tax_pct = ?, reorder_level = ?, is_active = ?, updated_at = ? WHERE id = ?')
      .run(b.name || p.name, b.category_id != null ? b.category_id : p.category_id,
           b.unit || p.unit, b.barcode != null ? b.barcode : p.barcode,
           newCost, newSale,
           num(b.tax_pct, p.tax_pct), num(b.reorder_level, p.reorder_level),
           b.is_active != null ? (b.is_active ? 1 : 0) : p.is_active, DB.nowISO(), p.id);
    if (newCost !== E.roundMoney(p.cost_price) || newSale !== E.roundMoney(p.sale_price)) {
      store.db.prepare(
        'INSERT INTO price_history (product_id, old_cost, old_sale, new_cost, new_sale, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
        .run(p.id, p.cost_price, p.sale_price, newCost, newSale, req.user.id, DB.nowISO());
    }
    audit(req, 'product.update', 'product', p.id, b);
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.get('/api/categories', requireAuth, function (req, res) {
  res.json(store.db.prepare('SELECT * FROM categories ORDER BY name').all());
});

app.post('/api/categories', requireAuth, requirePerm('products.write'), function (req, res) {
  try {
    const info = store.db.prepare('INSERT INTO categories (name, created_at) VALUES (?, ?)')
      .run(String(req.body.name), DB.nowISO());
    audit(req, 'category.create', 'category', info.lastInsertRowid, req.body);
    res.json({ id: info.lastInsertRowid });
  } catch (e) { res.status(400).json({ error: 'اسم الفئة مستخدم بالفعل' }); }
});

/* ------------------------- المخزون ------------------------- */

app.get('/api/inventory', requireAuth, function (req, res) {
  const rows = store.db.prepare(
    'SELECT p.id, p.sku, p.name, p.unit, p.reorder_level, p.avg_cost, p.sale_price, c.name AS category_name ' +
    'FROM products p LEFT JOIN categories c ON c.id = p.category_id WHERE p.is_active = 1 ORDER BY p.name').all();
  rows.forEach(function (p) {
    p.stock = store.stockOf(p.id);
    p.low = E.isLowStock(p.stock, p.reorder_level);
    p.value = E.roundMoney(p.stock * p.avg_cost);
  });
  sendRows(req, res, rows, 'inventory.csv');
});

app.post('/api/inventory/adjust', requireAuth, requirePerm('inventory.adjust'), function (req, res) {
  const b = req.body || {};
  const p = store.db.prepare('SELECT * FROM products WHERE id = ?').get(b.productId);
  if (!p) return res.status(404).json({ error: 'الصنف غير موجود' });
  try {
    const stock = store.stockOf(p.id);
    const after = E.stockAfterAdjust(stock, num(b.delta));
    const tx = store.db.transaction(function () {
      store.db.prepare(
        "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, note, user_id, created_at) " +
        'VALUES (?,?,?,?,?,?,?,?,?)')
        .run(p.id, b.delta > 0 ? 'in' : 'out', Math.abs(E.roundMoney(b.delta)), p.avg_cost,
             'adjust', b.note || 'تسوية مخزون', req.user.id, DB.nowISO());
    });
    tx();
    audit(req, 'inventory.adjust', 'product', p.id, { delta: b.delta, before: stock, after: after });
    res.json({ ok: true, stock: after });
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

app.get('/api/stock-moves/:productId', requireAuth, function (req, res) {
  res.json(store.db.prepare(
    'SELECT sm.*, p.name AS product_name FROM stock_moves sm ' +
    'JOIN products p ON p.id = sm.product_id WHERE sm.product_id = ? ORDER BY sm.id DESC LIMIT 200')
    .all(req.params.productId));
});

/* ------------------------- المبيعات ------------------------- */

app.post('/api/sales', requireAuth, requirePerm('sales.create'), function (req, res) {
  const b = req.body || {};
  const items = (b.items || []).map(function (it) { return {
    productId: num(it.productId), qty: num(it.qty), unitPrice: E.roundMoney(num(it.unitPrice)),
    discountPct: num(it.discountPct) }; });
  const maxDisc = num(store.getSetting('max_discount_pct'), 10);
  const allowBelow = store.getSetting('allow_below_cost') === '1';

  try {
    if (items.length === 0) throw new E.EngineError('E_INVOICE_EMPTY', 'لا توجد بنود في الفاتورة');
    const enriched = items.map(function (it) {
      const p = store.db.prepare('SELECT * FROM products WHERE id = ? AND is_active = 1').get(it.productId);
      if (!p) throw new E.EngineError('E_PRODUCT_MISSING', 'صنف غير موجود أو غير نشط');
      return { productId: p.id, name: p.name, qty: it.qty, unitPrice: it.unitPrice,
               discountPct: it.discountPct, costPrice: p.avg_cost, taxPct: p.tax_pct, product: p };
    });
    const totals = E.validateSale({
      items: enriched,
      invoiceDiscountPct: num(b.invoiceDiscountPct),
      taxPct: 0,
      maxDiscountPct: maxDisc,
      allowBelowCost: allowBelow,
      requireDiscountPerm: true,
      hasDiscountPerm: E.roleCan(req.user.role, 'sales.discount')
    });

    /* ضريبة لكل بند بعد خصم البند + الحصة التناسبية من خصم الفاتورة */
    const afterLines = E.roundMoney(totals.subtotal - totals.lineDiscounts);
    let taxTotal = 0;
    totals.lines.forEach(function (line, i) {
      const it = enriched[i];
      const share = afterLines > 0 ? E.roundMoney(line.net / afterLines * totals.invoiceDiscount) : 0;
      const netAfterInv = E.roundMoney(line.net - share);
      taxTotal += netAfterInv * (Number(it.taxPct) || 0) / 100;
    });
    taxTotal = E.roundMoney(taxTotal);
    const grandTotal = E.roundMoney(totals.total + taxTotal);

    let customer = null;
    if (b.customerId) {
      customer = store.db.prepare('SELECT * FROM customers WHERE id = ?').get(b.customerId);
      if (!customer) throw new E.EngineError('E_CUSTOMER_MISSING', 'العميل غير موجود');
    }
    const paymentType = b.paymentType === 'credit' ? 'credit' : 'cash';
    if (paymentType === 'credit') {
      if (!customer) throw new E.EngineError('E_CREDIT_NO_CUSTOMER', 'البيع الآجل يتطلب اختيار عميل');
      if (E.canExtendCredit(customer.balance, customer.credit_limit, grandTotal) !== true) {
        throw new E.EngineError('E_CREDIT_LIMIT',
          'حد الائتمان صفري أو غير محدد — البيع الآجل غير مسموح لهذا العميل');
      }
    }
    const paid = paymentType === 'cash' ? E.roundMoney(num(b.paid, grandTotal)) : 0;
    if (paymentType === 'cash' && paid < grandTotal) {
      throw new E.EngineError('E_PAID_SHORT', 'المدفوع أقل من إجمالي الفاتورة');
    }

    for (const it of enriched) {
      E.canSell(store.stockOf(it.productId), it.qty);
    }

    const number = store.nextNumber('INV');
    const tx = store.db.transaction(function () {
      const costTotal = enriched.reduce(function (s, it, i) {
        return s + it.product.avg_cost * totals.lines[i].qty;
      }, 0);
      const info = store.db.prepare(
        'INSERT INTO sales (number, customer_id, user_id, subtotal, line_discounts, invoice_discount_pct, ' +
        'invoice_discount, net, tax_pct, tax, total, cost_total, payment_type, paid, status, notes, created_at) ' +
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)')
        .run(number, customer ? customer.id : null, req.user.id, totals.subtotal, totals.lineDiscounts,
             totals.invoiceDiscountPct, totals.invoiceDiscount, totals.net, 0, taxTotal,
             grandTotal, E.roundMoney(costTotal), paymentType, paid, 'completed', b.notes || null, DB.nowISO());
      const saleId = info.lastInsertRowid;
      enriched.forEach(function (it, i) {
        const line = totals.lines[i];
        store.db.prepare(
          'INSERT INTO sale_items (sale_id, product_id, qty, unit_price, discount_pct, gross, net, unit_cost) ' +
          'VALUES (?,?,?,?,?,?,?,?)')
          .run(saleId, it.productId, it.qty, it.unitPrice, it.discountPct, line.gross, line.net, it.product.avg_cost);
        store.db.prepare(
          "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, ref_id, note, user_id, created_at) " +
          "VALUES (?, 'out', ?, ?, 'sale', ?, NULL, ?, ?)")
          .run(it.productId, it.qty, it.product.avg_cost, saleId, req.user.id, DB.nowISO());
      });
      if (paymentType === 'cash') {
        const eff = E.cashEffect('sale', grandTotal);
        store.db.prepare(
          'INSERT INTO cashbox_tx (type, amount, ref_type, ref_id, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
          .run(eff.type, eff.amount, 'sale', saleId, 'تحصيل فاتورة ' + number, req.user.id, DB.nowISO());
        store.db.prepare(
          "INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('cash', ?, 0, 'sale', ?, ?, ?)")
          .run(grandTotal, saleId, number, DB.nowISO());
        store.db.prepare(
          "INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('sales', 0, ?, 'sale', ?, ?, ?)")
          .run(totals.net, saleId, number, DB.nowISO());
        if (taxTotal > 0) {
          store.db.prepare(
            "INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('tax', 0, ?, 'sale', ?, ?, ?)")
            .run(taxTotal, saleId, number, DB.nowISO());
        }
      } else {
        store.db.prepare('UPDATE customers SET balance = balance + ?, updated_at = ? WHERE id = ?')
          .run(grandTotal, DB.nowISO(), customer.id);
        store.db.prepare(
          "INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES (?, ?, 0, 'sale', ?, ?, ?)")
          .run('receivable:' + customer.id, grandTotal, saleId, number, DB.nowISO());
        store.db.prepare(
          "INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('sales', 0, ?, 'sale', ?, ?, ?)")
          .run(totals.net, saleId, number, DB.nowISO());
        if (taxTotal > 0) {
          store.db.prepare(
            "INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('tax', 0, ?, 'sale', ?, ?, ?)")
            .run(taxTotal, saleId, number, DB.nowISO());
        }
      }
      return { id: saleId, number: number, totals: totals, grandTotal: grandTotal,
               change: paymentType === 'cash' ? E.cashChange(grandTotal, paid) : 0 };
    });
    const result = tx();
    audit(req, 'sale.create', 'sale', result.id, { number: result.number, total: result.grandTotal });
    res.json(result);
  } catch (e) {
    res.status(400).json({ error: e.message, code: e.code });
  }
});

app.get('/api/sales', requireAuth, function (req, res) {
  const rows = store.db.prepare(
    'SELECT s.*, c.name AS customer_name, u.username FROM sales s ' +
    'LEFT JOIN customers c ON c.id = s.customer_id LEFT JOIN users u ON u.id = s.user_id ' +
    'ORDER BY s.id DESC LIMIT 500').all();
  sendRows(req, res, rows, 'sales.csv');
});

app.get('/api/sales/:id', requireAuth, function (req, res) {
  const sale = store.db.prepare(
    'SELECT s.*, c.name AS customer_name, u.username FROM sales s ' +
    'LEFT JOIN customers c ON c.id = s.customer_id LEFT JOIN users u ON u.id = s.user_id WHERE s.id = ?')
    .get(req.params.id);
  if (!sale) return res.status(404).json({ error: 'الفاتورة غير موجودة' });
  const items = store.db.prepare(
    'SELECT si.*, p.name AS product_name, p.sku FROM sale_items si ' +
    'JOIN products p ON p.id = si.product_id WHERE si.sale_id = ?').all(req.params.id);
  const returns = store.db.prepare('SELECT * FROM sale_returns WHERE sale_id = ?').all(req.params.id);
  res.json({ sale: sale, items: items, returns: returns });
});

/* ------------------------- المرتجعات ------------------------- */

app.post('/api/sale-returns', requireAuth, requirePerm('returns.create'), function (req, res) {
  const b = req.body || {};
  try {
    const sale = store.db.prepare('SELECT * FROM sales WHERE id = ?').get(b.saleId);
    if (!sale) throw new E.EngineError('E_SALE_MISSING', 'الفاتورة الأصلية غير موجودة');
    const lines = b.items || [];
    if (!lines.length) throw new E.EngineError('E_INVOICE_EMPTY', 'لا توجد بنود للمرتجع');
    let total = 0;
    const checked = lines.map(function (l) {
      const si = store.db.prepare('SELECT * FROM sale_items WHERE id = ? AND sale_id = ?').get(l.saleItemId, sale.id);
      if (!si) throw new E.EngineError('E_ITEM_MISSING', 'بند غير تابع للفاتورة');
      const ret = store.db.prepare('SELECT COALESCE(SUM(qty),0) AS q FROM sale_return_items WHERE sale_item_id = ?').get(si.id);
      const qty = E.validateSaleReturn(si.qty, ret.q, num(l.qty));
      const net = E.roundMoney(si.unit_price * qty * (1 - si.discount_pct / 100));
      total += net;
      return { si: si, qty: qty, net: net };
    });
    total = E.roundMoney(total);
    const number = store.nextNumber('SR');
    const refundType = (b.refundType === 'credit' && sale.customer_id) ? 'credit' : 'cash';
    const tx = store.db.transaction(function () {
      const info = store.db.prepare(
        'INSERT INTO sale_returns (number, sale_id, customer_id, user_id, total, refund_type, reason, created_at) ' +
        'VALUES (?,?,?,?,?,?,?,?)')
        .run(number, sale.id, sale.customer_id, req.user.id, total, refundType, b.reason || null, DB.nowISO());
      const rid = info.lastInsertRowid;
      checked.forEach(function (c) {
        store.db.prepare(
          'INSERT INTO sale_return_items (return_id, sale_item_id, product_id, qty, unit_price, net) VALUES (?,?,?,?,?,?)')
          .run(rid, c.si.id, c.si.product_id, c.qty, c.si.unit_price, c.net);
        store.db.prepare(
          "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, ref_id, note, user_id, created_at) " +
          "VALUES (?, 'in', ?, ?, 'sale-return', ?, NULL, ?, ?)")
          .run(c.si.product_id, c.qty, c.si.unit_cost, rid, req.user.id, DB.nowISO());
      });
      if (refundType === 'cash') {
        const eff = E.cashEffect('sale-return', total);
        store.db.prepare('INSERT INTO cashbox_tx (type, amount, ref_type, ref_id, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
          .run(eff.type, eff.amount, 'sale-return', rid, 'رد قيمة مرتجع ' + number, req.user.id, DB.nowISO());
      } else {
        store.db.prepare('UPDATE customers SET balance = balance - ?, updated_at = ? WHERE id = ?')
          .run(total, DB.nowISO(), sale.customer_id);
      }
      return { id: rid, number: number, total: total };
    });
    const result = tx();
    audit(req, 'sale-return.create', 'sale_return', result.id, { number: result.number, total: result.total });
    res.json(result);
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

app.get('/api/sale-returns', requireAuth, function (req, res) {
  const rows = store.db.prepare(
    'SELECT r.*, s.number AS sale_number, c.name AS customer_name FROM sale_returns r ' +
    'JOIN sales s ON s.id = r.sale_id LEFT JOIN customers c ON c.id = r.customer_id ORDER BY r.id DESC LIMIT 500').all();
  sendRows(req, res, rows, 'sale-returns.csv');
});

/* ------------------------- المشتريات ------------------------- */

app.post('/api/purchases', requireAuth, requirePerm('purchases.create'), function (req, res) {
  const b = req.body || {};
  try {
    const items = (b.items || []).map(function (it) {
      return { productId: num(it.productId), qty: num(it.qty), unitCost: E.roundMoney(num(it.unitCost)) };
    });
    if (!items.length) throw new E.EngineError('E_INVOICE_EMPTY', 'لا توجد بنود في الفاتورة');
    const discount = E.roundMoney(Math.max(0, num(b.discount)));
    let supplier = null;
    if (b.supplierId) {
      supplier = store.db.prepare('SELECT * FROM suppliers WHERE id = ?').get(b.supplierId);
      if (!supplier) throw new E.EngineError('E_SUPPLIER_MISSING', 'المورد غير موجود');
    }
    const paymentType = b.paymentType === 'credit' ? 'credit' : 'cash';
    const lines = items.map(function (it) {
      const p = store.db.prepare('SELECT * FROM products WHERE id = ?').get(it.productId);
      if (!p) throw new E.EngineError('E_PRODUCT_MISSING', 'صنف غير موجود: ' + it.productId);
      E.assertQty(it.qty);
      E.assertPrice(it.unitCost, 'تكلفة الشراء');
      return { p: p, qty: it.qty, unitCost: it.unitCost, net: E.roundMoney(it.qty * it.unitCost) };
    });
    let total = E.roundMoney(lines.reduce(function (s, l) { return s + l.net; }, 0));
    if (discount > total) throw new E.EngineError('E_DISCOUNT_RANGE', 'الخصم أكبر من إجمالي الفاتورة');
    total = E.roundMoney(total - discount);
    const number = store.nextNumber('PUR');
    const tx = store.db.transaction(function () {
      const info = store.db.prepare(
        'INSERT INTO purchases (number, supplier_id, user_id, subtotal, discount, total, payment_type, status, notes, created_at) ' +
        'VALUES (?,?,?,?,?,?,?,?,?,?)')
        .run(number, supplier ? supplier.id : null, req.user.id,
             E.roundMoney(total + discount), discount, total, paymentType, 'completed', b.notes || null, DB.nowISO());
      const pid = info.lastInsertRowid;
      lines.forEach(function (l) {
        store.db.prepare('INSERT INTO purchase_items (purchase_id, product_id, qty, unit_cost, net) VALUES (?,?,?,?,?)')
          .run(pid, l.p.id, l.qty, l.unitCost, l.net);
        const oldQty = store.stockOf(l.p.id);
        const newAvg = E.weightedAvgCost(oldQty, l.p.avg_cost, l.qty, l.unitCost);
        store.db.prepare(
          "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, ref_id, note, user_id, created_at) " +
          "VALUES (?, 'in', ?, ?, 'purchase', ?, NULL, ?, ?)")
          .run(l.p.id, l.qty, l.unitCost, pid, req.user.id, DB.nowISO());
        store.db.prepare('UPDATE products SET avg_cost = ?, cost_price = ?, updated_at = ? WHERE id = ?')
          .run(newAvg, l.unitCost, DB.nowISO(), l.p.id);
        if (E.roundMoney(newAvg) !== E.roundMoney(l.p.avg_cost) || E.roundMoney(l.unitCost) !== E.roundMoney(l.p.cost_price)) {
          store.db.prepare(
            'INSERT INTO price_history (product_id, old_cost, old_sale, new_cost, new_sale, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
            .run(l.p.id, l.p.avg_cost, l.p.sale_price, newAvg, l.p.sale_price, req.user.id, DB.nowISO());
        }
      });
      if (paymentType === 'cash') {
        const eff = E.cashEffect('purchase', total);
        store.db.prepare('INSERT INTO cashbox_tx (type, amount, ref_type, ref_id, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
          .run(eff.type, eff.amount, 'purchase', pid, 'سداد فاتورة شراء ' + number, req.user.id, DB.nowISO());
        store.db.prepare("INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('inventory', ?, 0, 'purchase', ?, ?, ?)")
          .run(total, pid, number, DB.nowISO());
        store.db.prepare("INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('cash', 0, ?, 'purchase', ?, ?, ?)")
          .run(total, pid, number, DB.nowISO());
      } else {
        store.db.prepare('UPDATE suppliers SET balance = balance + ?, updated_at = ? WHERE id = ?')
          .run(total, DB.nowISO(), supplier.id);
        store.db.prepare("INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES ('inventory', ?, 0, 'purchase', ?, ?, ?)")
          .run(total, pid, number, DB.nowISO());
        store.db.prepare("INSERT INTO journal (account, debit, credit, ref_type, ref_id, note, created_at) VALUES (?, 0, ?, 'purchase', ?, ?, ?)")
          .run('payable:' + supplier.id, total, pid, number, DB.nowISO());
      }
      return { id: pid, number: number, total: total };
    });
    const result = tx();
    audit(req, 'purchase.create', 'purchase', result.id, { number: result.number, total: result.total });
    res.json(result);
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

app.get('/api/purchases', requireAuth, function (req, res) {
  const rows = store.db.prepare(
    'SELECT p.*, s.name AS supplier_name, u.username FROM purchases p ' +
    'LEFT JOIN suppliers s ON s.id = p.supplier_id LEFT JOIN users u ON u.id = p.user_id ORDER BY p.id DESC LIMIT 500').all();
  sendRows(req, res, rows, 'purchases.csv');
});

app.post('/api/purchase-returns', requireAuth, requirePerm('purchases.create'), function (req, res) {
  const b = req.body || {};
  try {
    const purch = store.db.prepare('SELECT * FROM purchases WHERE id = ?').get(b.purchaseId);
    if (!purch) throw new E.EngineError('E_PURCHASE_MISSING', 'فاتورة الشراء غير موجودة');
    const lines = b.items || [];
    if (!lines.length) throw new E.EngineError('E_INVOICE_EMPTY', 'لا توجد بنود للمرتجع');
    let total = 0;
    const checked = lines.map(function (l) {
      const pi = store.db.prepare('SELECT * FROM purchase_items WHERE id = ? AND purchase_id = ?').get(l.purchaseItemId, purch.id);
      if (!pi) throw new E.EngineError('E_ITEM_MISSING', 'بند غير تابع للفاتورة');
      const ret = store.db.prepare('SELECT COALESCE(SUM(qty),0) AS q FROM purchase_return_items WHERE purchase_item_id = ?').get(pi.id);
      const qty = E.validateSaleReturn(pi.qty, ret.q, num(l.qty));
      const net = E.roundMoney(pi.unit_cost * qty);
      total += net;
      return { pi: pi, qty: qty, net: net };
    });
    total = E.roundMoney(total);
    const number = store.nextNumber('PR');
    const refundType = (b.refundType !== 'cash' && purch.supplier_id) ? 'credit' : 'cash';
    const tx = store.db.transaction(function () {
      const info = store.db.prepare(
        'INSERT INTO purchase_returns (number, purchase_id, supplier_id, user_id, total, refund_type, reason, created_at) VALUES (?,?,?,?,?,?,?,?)')
        .run(number, purch.id, purch.supplier_id, req.user.id, total, refundType, b.reason || null, DB.nowISO());
      const rid = info.lastInsertRowid;
      checked.forEach(function (c) {
        store.db.prepare('INSERT INTO purchase_return_items (return_id, purchase_item_id, product_id, qty, unit_cost, net) VALUES (?,?,?,?,?,?)')
          .run(rid, c.pi.id, c.pi.product_id, c.qty, c.pi.unit_cost, c.net);
        E.canSell(store.stockOf(c.pi.product_id), c.qty);
        store.db.prepare(
          "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, ref_id, note, user_id, created_at) " +
          "VALUES (?, 'out', ?, ?, 'purchase-return', ?, NULL, ?, ?)")
          .run(c.pi.product_id, c.qty, c.pi.unit_cost, rid, req.user.id, DB.nowISO());
      });
      if (refundType === 'cash') {
        store.db.prepare('INSERT INTO cashbox_tx (type, amount, ref_type, ref_id, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
          .run('purchase-return', total, 'purchase-return', rid, 'تحصيل مرتجع شراء ' + number, req.user.id, DB.nowISO());
      } else {
        store.db.prepare('UPDATE suppliers SET balance = balance - ?, updated_at = ? WHERE id = ?')
          .run(total, DB.nowISO(), purch.supplier_id);
      }
      return { id: rid, number: number, total: total };
    });
    const result = tx();
    audit(req, 'purchase-return.create', 'purchase_return', result.id, { number: result.number, total: result.total });
    res.json(result);
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

/* ------------------------- العملاء والموردون ------------------------- */

app.get('/api/customers', requireAuth, function (req, res) {
  sendRows(req, res, store.db.prepare('SELECT * FROM customers ORDER BY name').all(), 'customers.csv');
});

app.post('/api/customers', requireAuth, requirePerm('customers.write'), function (req, res) {
  const b = req.body || {};
  if (!b.name) return res.status(400).json({ error: 'اسم العميل مطلوب' });
  const info = store.db.prepare(
    'INSERT INTO customers (name, phone, address, credit_limit, balance, notes, created_at, updated_at) VALUES (?,?,?,?,0,?,?,?)')
    .run(String(b.name), b.phone || null, b.address || null, num(b.credit_limit), b.notes || null, DB.nowISO(), DB.nowISO());
  audit(req, 'customer.create', 'customer', info.lastInsertRowid, { name: b.name });
  res.json({ id: info.lastInsertRowid });
});

app.put('/api/customers/:id', requireAuth, requirePerm('customers.write'), function (req, res) {
  const b = req.body || {};
  const c = store.db.prepare('SELECT * FROM customers WHERE id = ?').get(req.params.id);
  if (!c) return res.status(404).json({ error: 'العميل غير موجود' });
  store.db.prepare('UPDATE customers SET name = ?, phone = ?, address = ?, credit_limit = ?, is_active = ?, notes = ?, updated_at = ? WHERE id = ?')
    .run(b.name || c.name, b.phone != null ? b.phone : c.phone, b.address != null ? b.address : c.address,
         num(b.credit_limit, c.credit_limit), b.is_active != null ? (b.is_active ? 1 : 0) : c.is_active,
         b.notes != null ? b.notes : c.notes, DB.nowISO(), c.id);
  audit(req, 'customer.update', 'customer', c.id, b);
  res.json({ ok: true });
});

app.get('/api/suppliers', requireAuth, function (req, res) {
  sendRows(req, res, store.db.prepare('SELECT * FROM suppliers ORDER BY name').all(), 'suppliers.csv');
});

app.post('/api/suppliers', requireAuth, requirePerm('suppliers.write'), function (req, res) {
  const b = req.body || {};
  if (!b.name) return res.status(400).json({ error: 'اسم المورد مطلوب' });
  const info = store.db.prepare('INSERT INTO suppliers (name, phone, address, notes, created_at, updated_at) VALUES (?,?,?,?,?,?)')
    .run(String(b.name), b.phone || null, b.address || null, b.notes || null, DB.nowISO(), DB.nowISO());
  audit(req, 'supplier.create', 'supplier', info.lastInsertRowid, { name: b.name });
  res.json({ id: info.lastInsertRowid });
});

app.put('/api/suppliers/:id', requireAuth, requirePerm('suppliers.write'), function (req, res) {
  const b = req.body || {};
  const s = store.db.prepare('SELECT * FROM suppliers WHERE id = ?').get(req.params.id);
  if (!s) return res.status(404).json({ error: 'المورد غير موجود' });
  store.db.prepare('UPDATE suppliers SET name = ?, phone = ?, address = ?, is_active = ?, notes = ?, updated_at = ? WHERE id = ?')
    .run(b.name || s.name, b.phone != null ? b.phone : s.phone, b.address != null ? b.address : s.address,
         b.is_active != null ? (b.is_active ? 1 : 0) : s.is_active, b.notes != null ? b.notes : s.notes, DB.nowISO(), s.id);
  audit(req, 'supplier.update', 'supplier', s.id, b);
  res.json({ ok: true });
});

/* ------------------------- المدفوعات (تحصيل/سداد) ------------------------- */

app.post('/api/payments', requireAuth, requirePerm('cashbox.manage'), function (req, res) {
  const b = req.body || {};
  try {
    const amount = E.roundMoney(num(b.amount));
    E.assertQty(amount);
    const isCustomer = b.partyType === 'customer';
    const party = store.db.prepare(
      'SELECT * FROM ' + (isCustomer ? 'customers' : 'suppliers') + ' WHERE id = ?').get(b.partyId);
    if (!party) throw new E.EngineError('E_PARTY_MISSING', 'الطرف غير موجود');
    if (isCustomer && E.roundMoney(party.balance) < amount) {
      throw new E.EngineError('E_OVERPAY', 'المبلغ يتجاوز رصيد العميل المستحق');
    }
    const tx = store.db.transaction(function () {
      store.db.prepare('INSERT INTO payments (party_type, party_id, amount, method, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
        .run(b.partyType, b.partyId, amount, 'cash', b.note || null, req.user.id, DB.nowISO());
      const cashType = isCustomer ? 'payment-in' : 'payment-out';
      const eff = E.cashEffect(cashType, amount);
      store.db.prepare('INSERT INTO cashbox_tx (type, amount, ref_type, ref_id, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
        .run(eff.type, eff.amount, 'payment', null,
             (isCustomer ? 'تحصيل من ' : 'سداد إلى ') + party.name, req.user.id, DB.nowISO());
      store.db.prepare('UPDATE ' + (isCustomer ? 'customers' : 'suppliers') +
                       ' SET balance = balance - ?, updated_at = ? WHERE id = ?')
        .run(amount, DB.nowISO(), party.id);
    });
    tx();
    audit(req, 'payment.create', 'payment', null, { partyType: b.partyType, partyId: b.partyId, amount: amount });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

app.get('/api/payments', requireAuth, function (req, res) {
  sendRows(req, res, store.db.prepare('SELECT * FROM payments ORDER BY id DESC LIMIT 500').all(), 'payments.csv');
});

/* ------------------------- الصندوق والمصروفات ------------------------- */

app.get('/api/cashbox', requireAuth, function (req, res) {
  const txs = store.db.prepare('SELECT * FROM cashbox_tx ORDER BY id DESC LIMIT 500').all();
  const balance = E.cashBalanceAfter(store.db.prepare('SELECT type, amount FROM cashbox_tx').all());
  res.json({ balance: balance, txs: txs });
});

app.post('/api/cashbox/tx', requireAuth, requirePerm('cashbox.manage'), function (req, res) {
  const b = req.body || {};
  try {
    const eff = E.cashEffect(b.type === 'withdraw' ? 'withdraw' : 'deposit', num(b.amount));
    if (!(eff.amount > 0)) {
      throw new E.EngineError('E_AMOUNT_INVALID', 'المبلغ يجب أن يكون رقمًا أكبر من صفر');
    }
    store.db.prepare('INSERT INTO cashbox_tx (type, amount, ref_type, note, user_id, created_at) VALUES (?,?,?,?,?,?)')
      .run(eff.type, eff.amount, 'manual', b.note || null, req.user.id, DB.nowISO());
    audit(req, 'cashbox.tx', 'cashbox', null, { type: eff.type, amount: eff.amount });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

app.post('/api/expenses', requireAuth, requirePerm('expenses.create'), function (req, res) {
  const b = req.body || {};
  try {
    const eff = E.cashEffect('expense', num(b.amount));
    if (!(eff.amount > 0)) {
      throw new E.EngineError('E_AMOUNT_INVALID', 'المبلغ يجب أن يكون رقمًا أكبر من صفر');
    }
    const tx = store.db.transaction(function () {
      const info = store.db.prepare('INSERT INTO expenses (category, amount, note, user_id, created_at) VALUES (?,?,?,?,?)')
        .run(String(b.category || 'مصروف'), eff.amount, b.note || null, req.user.id, DB.nowISO());
      store.db.prepare('INSERT INTO cashbox_tx (type, amount, ref_type, ref_id, note, user_id, created_at) VALUES (?,?,?,?,?,?,?)')
        .run(eff.type, eff.amount, 'expense', info.lastInsertRowid, b.category || 'مصروف', req.user.id, DB.nowISO());
      return info.lastInsertRowid;
    });
    const id = tx();
    audit(req, 'expense.create', 'expense', id, b);
    res.json({ id: id });
  } catch (e) { res.status(400).json({ error: e.message, code: e.code }); }
});

app.get('/api/expenses', requireAuth, function (req, res) {
  sendRows(req, res, store.db.prepare('SELECT * FROM expenses ORDER BY id DESC LIMIT 500').all(), 'expenses.csv');
});

/* ------------------------- التقارير ------------------------- */

app.get('/api/dashboard', requireAuth, function (req, res) {
  const dayStart = new Date(); dayStart.setHours(0, 0, 0, 0);
  const todayISO = dayStart.toISOString();
  const t = store.db.prepare('SELECT COALESCE(SUM(total),0) AS v FROM sales WHERE created_at >= ?').get(todayISO).v;
  const m = store.db.prepare("SELECT COALESCE(SUM(total),0) AS v FROM sales WHERE created_at >= datetime('now','start of month')").get().v;
  const p = store.db.prepare("SELECT COALESCE(SUM(total - tax - cost_total),0) AS v FROM sales WHERE created_at >= datetime('now','start of month')").get().v;
  const cash = E.cashBalanceAfter(store.db.prepare('SELECT type, amount FROM cashbox_tx').all());
  const lowRows = store.db.prepare(
    "SELECT p.reorder_level, COALESCE((SELECT SUM(CASE WHEN m.type = 'in' THEN m.qty ELSE -m.qty END) FROM stock_moves m WHERE m.product_id = p.id), 0) AS stock " +
    'FROM products p WHERE p.is_active = 1').all();
  const low = lowRows.filter(function (r) {
    return E.isLowStock(r.stock, r.reorder_level) || r.stock <= 0;
  }).length;
  const receivables = store.db.prepare('SELECT COALESCE(SUM(balance),0) AS v FROM customers').get().v;
  const payables = store.db.prepare('SELECT COALESCE(SUM(balance),0) AS v FROM suppliers').get().v;
  res.json({
    sales_today: E.roundMoney(t), sales_month: E.roundMoney(m), profit_month: E.roundMoney(p),
    cash_balance: cash, low_stock_count: low,
    receivables: E.roundMoney(receivables), payables: E.roundMoney(payables)
  });
});

app.get('/api/reports/daily', requireAuth, requirePerm('reports.view'), function (req, res) {
  const rows = store.db.prepare(
    "SELECT date(created_at) AS day, COUNT(*) AS invoices, SUM(total) AS total, SUM(total - tax - cost_total) AS profit " +
    'FROM sales GROUP BY day ORDER BY day DESC LIMIT 60').all();
  rows.forEach(function (r) { r.total = E.roundMoney(r.total); r.profit = E.roundMoney(r.profit); });
  sendRows(req, res, rows, 'daily-report.csv');
});

app.get('/api/reports/products', requireAuth, requirePerm('reports.view'), function (req, res) {
  const rows = store.db.prepare(
    'SELECT p.sku, p.name, SUM(si.qty) AS qty_sold, SUM(si.net) AS revenue, ' +
    'SUM(si.qty * si.unit_cost) AS cost, SUM(si.net - si.qty * si.unit_cost) AS profit ' +
    'FROM sale_items si JOIN products p ON p.id = si.product_id GROUP BY p.id ORDER BY revenue DESC').all();
  rows.forEach(function (r) {
    r.revenue = E.roundMoney(r.revenue); r.cost = E.roundMoney(r.cost); r.profit = E.roundMoney(r.profit);
  });
  sendRows(req, res, rows, 'products-report.csv');
});

app.get('/api/reports/low-stock', requireAuth, requirePerm('reports.view'), function (req, res) {
  const rows = store.db.prepare('SELECT id, sku, name, unit, reorder_level FROM products WHERE is_active = 1').all();
  const out = rows.map(function (p) {
    const stock = store.stockOf(p.id);
    return { sku: p.sku, name: p.name, unit: p.unit, stock: stock, reorder_level: p.reorder_level };
  }).filter(function (r) { return r.stock <= r.reorder_level; });
  sendRows(req, res, out, 'low-stock.csv');
});

app.get('/api/reports/customer-statement/:id', requireAuth, requirePerm('reports.view'), function (req, res) {
  const c = store.db.prepare('SELECT * FROM customers WHERE id = ?').get(req.params.id);
  if (!c) return res.status(404).json({ error: 'العميل غير موجود' });
  const sales = store.db.prepare('SELECT number, total, paid, created_at FROM sales WHERE customer_id = ? ORDER BY id DESC LIMIT 200').all(c.id);
  const payments = store.db.prepare("SELECT amount, created_at FROM payments WHERE party_type = 'customer' AND party_id = ? ORDER BY id DESC LIMIT 200").all(c.id);
  res.json({ customer: c, sales: sales, payments: payments });
});

/* ------------------------- المستخدمون ------------------------- */

app.get('/api/users', requireAuth, requirePerm('users.manage'), function (req, res) {
  res.json(store.db.prepare('SELECT id, username, full_name, role, is_active, force_change, created_at FROM users ORDER BY id').all());
});

app.post('/api/users', requireAuth, requirePerm('users.manage'), function (req, res) {
  const b = req.body || {};
  if (!b.username || !b.password || !b.full_name) {
    return res.status(400).json({ error: 'اسم المستخدم والاسم الكامل وكلمة المرور مطلوبة' });
  }
  if (String(b.password).length < 6) return res.status(400).json({ error: 'كلمة المرور يجب أن تكون 6 أحرف على الأقل' });
  if (!E.ROLES[b.role || 'cashier']) return res.status(400).json({ error: 'دور غير معروف' });
  try {
    const info = store.db.prepare(
      'INSERT INTO users (username, full_name, role, password_hash, is_active, force_change, created_at, updated_at) VALUES (?,?,?,?,?,1,1,?,?)')
      .run(String(b.username), String(b.full_name), b.role, DB.hashPassword(b.password), DB.nowISO(), DB.nowISO());
    audit(req, 'user.create', 'user', info.lastInsertRowid, { username: b.username, role: b.role });
    res.json({ id: info.lastInsertRowid });
  } catch (e) { res.status(400).json({ error: 'اسم المستخدم مستخدم بالفعل' }); }
});

app.put('/api/users/:id', requireAuth, requirePerm('users.manage'), function (req, res) {
  const b = req.body || {};
  const u = store.db.prepare('SELECT * FROM users WHERE id = ?').get(req.params.id);
  if (!u) return res.status(404).json({ error: 'المستخدم غير موجود' });
  if (u.id === req.user.id && b.is_active === 0) {
    return res.status(400).json({ error: 'لا يمكنك تعطيل حسابك الحالي' });
  }
  store.db.prepare('UPDATE users SET full_name = ?, role = ?, is_active = ?, updated_at = ? WHERE id = ?')
    .run(b.full_name || u.full_name, E.ROLES[b.role] ? b.role : u.role,
         b.is_active != null ? (b.is_active ? 1 : 0) : u.is_active, DB.nowISO(), u.id);
  if (b.password) {
    if (String(b.password).length < 6) return res.status(400).json({ error: 'كلمة المرور يجب أن تكون 6 أحرف على الأقل' });
    store.db.prepare('UPDATE users SET password_hash = ?, force_change = 1, updated_at = ? WHERE id = ?')
      .run(DB.hashPassword(b.password), DB.nowISO(), u.id);
  }
  audit(req, 'user.update', 'user', u.id, { username: u.username });
  res.json({ ok: true });
});

/* ------------------------- التدقيق ------------------------- */

app.get('/api/audit', requireAuth, requirePerm('audit.view'), function (req, res) {
  sendRows(req, res, store.db.prepare('SELECT * FROM audit_log ORDER BY id DESC LIMIT 1000').all(), 'audit.csv');
});

/* ------------------------- استيراد CSV ------------------------- */

app.post('/api/import/products', requireAuth, requirePerm('import.run'), function (req, res) {
  const csv = String((req.body || {}).csv || '');
  const lines = csv.split(/\r?\n/).filter(function (l) { return l.trim() !== ''; });
  if (lines.length === 0) return res.status(400).json({ error: 'الملف فارغ' });
  const header = lines[0].replace(/^\uFEFF/, '').split(',').map(function (s) { return s.trim(); });
  const idx = {};
  ['sku', 'name', 'category', 'unit', 'cost_price', 'sale_price', 'tax_pct', 'reorder_level', 'barcode']
    .forEach(function (k) { idx[k] = header.indexOf(k); });
  if (idx.sku < 0 || idx.name < 0) {
    return res.status(400).json({ error: 'يجب أن يحتوي صف العناوين على العمودين sku و name' });
  }
  let added = 0, updated = 0, errors = [];
  const tx = store.db.transaction(function () {
    for (let i = 1; i < lines.length; i++) {
      const cols = lines[i].split(',');
      const sku = (cols[idx.sku] || '').trim();
      const name = (cols[idx.name] || '').trim();
      if (!sku || !name) { errors.push('صف ' + (i + 1) + ': رمز أو اسم ناقص'); continue; }
      const cost = E.roundMoney(num(cols[idx.cost_price]));
      const sale = E.roundMoney(num(cols[idx.sale_price]));
      const catName = idx.category >= 0 ? (cols[idx.category] || '').trim() : '';
      let catId = null;
      if (catName) {
        let cat = store.db.prepare('SELECT id FROM categories WHERE name = ?').get(catName);
        if (!cat) cat = { id: store.db.prepare('INSERT INTO categories (name, created_at) VALUES (?, ?)').run(catName, DB.nowISO()).lastInsertRowid };
        catId = cat.id;
      }
      const unit = idx.unit >= 0 ? (cols[idx.unit] || 'pcs').trim() : 'pcs';
      const exists = store.db.prepare('SELECT id FROM products WHERE sku = ?').get(sku);
      if (exists) {
        store.db.prepare('UPDATE products SET name = ?, category_id = ?, unit = ?, cost_price = ?, sale_price = ?, tax_pct = ?, reorder_level = ?, updated_at = ? WHERE id = ?')
          .run(name, catId, E.UNITS[unit] ? unit : 'pcs', cost, sale,
               idx.tax_pct >= 0 ? num(cols[idx.tax_pct]) : 0,
               idx.reorder_level >= 0 ? num(cols[idx.reorder_level]) : 0, DB.nowISO(), exists.id);
        updated++;
      } else {
        store.db.prepare('INSERT INTO products (sku, name, category_id, unit, barcode, cost_price, sale_price, tax_pct, reorder_level, avg_cost, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)')
          .run(sku, name, catId, E.UNITS[unit] ? unit : 'pcs',
               idx.barcode >= 0 ? (cols[idx.barcode] || '').trim() : null,
               cost, sale, idx.tax_pct >= 0 ? num(cols[idx.tax_pct]) : 0,
               idx.reorder_level >= 0 ? num(cols[idx.reorder_level]) : 0,
               cost, DB.nowISO(), DB.nowISO());
        added++;
      }
    }
  });
  tx();
  audit(req, 'import.products', 'product', null, { added: added, updated: updated });
  res.json({ added: added, updated: updated, errors: errors });
});

/* ------------------------- النسخ الاحتياطي ------------------------- */

app.post('/api/backup', requireAuth, requirePerm('backup.manage'), function (req, res) {
  try {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const file = path.join(BACKUP_DIR, 'backup-' + stamp + '.db');
    store.db.pragma('wal_checkpoint(TRUNCATE)');
    store.db.exec("VACUUM INTO '" + file.replace(/'/g, "''") + "'");
    const size = fs.statSync(file).size;
    store.db.prepare('INSERT INTO backups (filename, size_bytes, created_by, created_at) VALUES (?,?,?,?)')
      .run(path.basename(file), size, req.user.username, DB.nowISO());
    audit(req, 'backup.create', 'backup', null, { file: path.basename(file) });
    res.json({ file: path.basename(file), size: size });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/backups', requireAuth, requirePerm('backup.manage'), function (req, res) {
  res.json(store.db.prepare('SELECT * FROM backups ORDER BY id DESC').all());
});

app.post('/api/restore', requireAuth, requirePerm('backup.manage'), function (req, res) {
  const filename = String((req.body || {}).file || '');
  if (/[\\/]/.test(filename)) return res.status(400).json({ error: 'اسم ملف غير صالح' });
  const file = path.join(BACKUP_DIR, filename);
  if (!fs.existsSync(file)) return res.status(404).json({ error: 'النسخة الاحتياطية غير موجودة' });
  try {
    const probe = new (require('better-sqlite3'))(file, { readonly: true });
    const check = probe.pragma('integrity_check');
    probe.close();
    if (!check || !check[0] || check[0].integrity_check !== 'ok') {
      return res.status(400).json({ error: 'فشل فحص السلامة — الملف تالف ولا يمكن استرجاعه' });
    }
    const pre = DB_PATH + '.pre-restore';
    if (fs.existsSync(pre)) fs.unlinkSync(pre);
    fs.copyFileSync(DB_PATH, pre);
    fs.copyFileSync(file, DB_PATH);
    audit(req, 'backup.restore', 'backup', null, { file: filename });
    res.json({ ok: true, note: 'تم الاسترجاع بنجاح — يعاد تشغيل الخادم مطلوب' });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

/* ------------------------- التشغيل ------------------------- */

const PORT = Number(process.env.PORT) || 3000;
const HOST = process.env.HOST || '127.0.0.1';
app.listen(PORT, HOST, function () {
  console.log('');
  console.log('  نظام إدارة المتجر — يعمل الآن');
  console.log('  العنوان:       http://' + HOST + ':' + PORT);
  console.log('  قاعدة البيانات: ' + DB_PATH);
  console.log('  الدخول الافتراضي: admin / admin (يُطلب تغييرها)');
  console.log('');
});

module.exports = app;

