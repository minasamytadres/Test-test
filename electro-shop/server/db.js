'use strict';
/* =====================================================================
 * server/db.js — طبقة قاعدة البيانات SQLite (better-sqlite3)
 * 23 جدولًا + متجر SqliteStore + تهيئة افتراضية + بيانات نموذجية
 * ===================================================================== */

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const Database = require('better-sqlite3');
const engine = require('../engine.js');

const nowISO = function () { return new Date().toISOString(); };

function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(String(password), salt, 32).toString('hex');
  return salt + ':' + hash;
}

function verifyPassword(password, stored) {
  if (!stored || typeof stored !== 'string' || stored.indexOf(':') < 0) return false;
  const parts = stored.split(':');
  const salt = parts[0];
  const hash = parts.slice(1).join(':');
  const calc = crypto.scryptSync(String(password), salt, 32).toString('hex');
  const a = Buffer.from(hash, 'hex');
  const b = Buffer.from(calc, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE, full_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'cashier', password_hash TEXT NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 1, force_change INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER, username TEXT, action TEXT NOT NULL,
  entity TEXT, entity_id INTEGER, details TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS products (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sku TEXT NOT NULL UNIQUE, name TEXT NOT NULL, category_id INTEGER,
  unit TEXT NOT NULL DEFAULT 'pcs', barcode TEXT,
  cost_price REAL NOT NULL DEFAULT 0, sale_price REAL NOT NULL DEFAULT 0,
  tax_pct REAL NOT NULL DEFAULT 0, reorder_level REAL NOT NULL DEFAULT 0,
  avg_cost REAL NOT NULL DEFAULT 0, is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS stock_moves (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  product_id INTEGER NOT NULL, type TEXT NOT NULL CHECK (type IN ('in','out')),
  qty REAL NOT NULL, unit_cost REAL NOT NULL DEFAULT 0,
  ref_type TEXT, ref_id INTEGER, note TEXT,
  user_id INTEGER, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS customers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL, phone TEXT, address TEXT,
  credit_limit REAL NOT NULL DEFAULT 0, balance REAL NOT NULL DEFAULT 0,
  is_active INTEGER NOT NULL DEFAULT 1, notes TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS suppliers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL, phone TEXT, address TEXT,
  balance REAL NOT NULL DEFAULT 0, is_active INTEGER NOT NULL DEFAULT 1, notes TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sales (
  id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT NOT NULL UNIQUE,
  customer_id INTEGER, user_id INTEGER,
  subtotal REAL NOT NULL, line_discounts REAL NOT NULL DEFAULT 0,
  invoice_discount_pct REAL NOT NULL DEFAULT 0, invoice_discount REAL NOT NULL DEFAULT 0,
  net REAL NOT NULL, tax_pct REAL NOT NULL DEFAULT 0, tax REAL NOT NULL DEFAULT 0,
  total REAL NOT NULL, cost_total REAL NOT NULL DEFAULT 0,
  payment_type TEXT NOT NULL CHECK (payment_type IN ('cash','credit')),
  paid REAL NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'completed',
  notes TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sale_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL,
  product_id INTEGER NOT NULL, qty REAL NOT NULL,
  unit_price REAL NOT NULL, discount_pct REAL NOT NULL DEFAULT 0,
  gross REAL NOT NULL, net REAL NOT NULL, unit_cost REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS purchases (
  id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT NOT NULL UNIQUE,
  supplier_id INTEGER, user_id INTEGER,
  subtotal REAL NOT NULL, discount REAL NOT NULL DEFAULT 0, total REAL NOT NULL,
  payment_type TEXT NOT NULL CHECK (payment_type IN ('cash','credit')),
  status TEXT NOT NULL DEFAULT 'completed', notes TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS purchase_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT, purchase_id INTEGER NOT NULL,
  product_id INTEGER NOT NULL, qty REAL NOT NULL, unit_cost REAL NOT NULL,
  net REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS sale_returns (
  id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT NOT NULL UNIQUE,
  sale_id INTEGER NOT NULL, customer_id INTEGER, user_id INTEGER,
  total REAL NOT NULL, refund_type TEXT NOT NULL DEFAULT 'cash',
  reason TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sale_return_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT, return_id INTEGER NOT NULL,
  sale_item_id INTEGER NOT NULL, product_id INTEGER NOT NULL,
  qty REAL NOT NULL, unit_price REAL NOT NULL, net REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS purchase_returns (
  id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT NOT NULL UNIQUE,
  purchase_id INTEGER NOT NULL, supplier_id INTEGER, user_id INTEGER,
  total REAL NOT NULL, refund_type TEXT NOT NULL DEFAULT 'credit',
  reason TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS purchase_return_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT, return_id INTEGER NOT NULL,
  purchase_item_id INTEGER NOT NULL, product_id INTEGER NOT NULL,
  qty REAL NOT NULL, unit_cost REAL NOT NULL, net REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS cashbox_tx (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL, amount REAL NOT NULL,
  ref_type TEXT, ref_id INTEGER, note TEXT,
  user_id INTEGER, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS payments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  party_type TEXT NOT NULL CHECK (party_type IN ('customer','supplier')),
  party_id INTEGER NOT NULL, amount REAL NOT NULL,
  method TEXT NOT NULL DEFAULT 'cash', note TEXT,
  user_id INTEGER, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS journal (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account TEXT NOT NULL, debit REAL NOT NULL DEFAULT 0, credit REAL NOT NULL DEFAULT 0,
  ref_type TEXT, ref_id INTEGER, note TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS expenses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category TEXT NOT NULL, amount REAL NOT NULL, note TEXT,
  user_id INTEGER, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS backups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  filename TEXT NOT NULL, size_bytes INTEGER NOT NULL,
  created_by TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS counters (
  name TEXT PRIMARY KEY, value INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_moves_product ON stock_moves(product_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_purch_items_purch ON purchase_items(purchase_id);
CREATE INDEX IF NOT EXISTS idx_journal_account ON journal(account);
`;

const DEFAULT_SETTINGS = {
  shop_name: 'متجر النور لمستلزمات الكهرباء',
  currency: 'EGP',
  default_tax_pct: '0',
  max_discount_pct: '10',
  credit_limit_default: '0',
  allow_below_cost: '0',
  address: '',
  phone: '',
  receipt_footer: 'شكرًا لتعاملكم معنا — ضمان استبدال خلال 14 يومًا'
};

function SqliteStore(dbPath) {
  this.dbPath = dbPath;
  this.db = new Database(dbPath);
  this.db.pragma('journal_mode = WAL');
  this.db.pragma('foreign_keys = ON');
  this.db.exec(SCHEMA);
  this.ensureDefaults();
}

SqliteStore.prototype.ensureDefaults = function () {
  const now = nowISO();
  const ins = this.db.prepare(
    'INSERT OR IGNORE INTO settings (key, value, updated_at) VALUES (?, ?, ?)');
  for (const k of Object.keys(DEFAULT_SETTINGS)) ins.run(k, String(DEFAULT_SETTINGS[k]), now);
  if (!this.getSetting('session_secret')) {
    ins.run('session_secret', crypto.randomBytes(32).toString('hex'), now);
  }
  const users = this.db.prepare('SELECT COUNT(*) AS c FROM users').get();
  if (users.c === 0) {
    this.db.prepare(
      'INSERT INTO users (username, full_name, role, password_hash, is_active, force_change, created_at, updated_at) ' +
      'VALUES (?, ?, ?, ?, 1, ?, ?, ?)')
      .run('admin', 'المدير العام', 'admin', hashPassword('admin'), 1, now, now);
  }
  const cnt = this.db.prepare("SELECT value FROM counters WHERE name = 'doc'").get();
  if (!cnt) {
    this.db.prepare('INSERT INTO counters (name, value) VALUES (?, ?)').run('doc', 0);
  }
};

SqliteStore.prototype.getSetting = function (key) {
  const r = this.db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
  return r ? r.value : null;
};

SqliteStore.prototype.setSetting = function (key, value) {
  this.db.prepare(
    'INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ' +
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at')
    .run(key, String(value), nowISO());
};

SqliteStore.prototype.nextNumber = function (prefix) {
  const tx = this.db.transaction(function (db) {
    db.prepare("INSERT INTO counters (name, value) VALUES ('doc', 0) " +
               'ON CONFLICT(name) DO NOTHING').run();
    db.prepare('UPDATE counters SET value = value + 1 WHERE name = ?').run('doc');
    return db.prepare('SELECT value FROM counters WHERE name = ?').get('doc').value;
  });
  const n = tx(this.db);
  return prefix + '-' + new Date().getFullYear() + '-' + String(n).padStart(5, '0');
};

SqliteStore.prototype.audit = function (user, action, entity, entityId, details) {
  this.db.prepare(
    'INSERT INTO audit_log (user_id, username, action, entity, entity_id, details, created_at) ' +
    'VALUES (?, ?, ?, ?, ?, ?, ?)')
    .run(user ? user.id : null, user ? user.username : 'system', action,
         entity || null, entityId || null,
         details ? JSON.stringify(details) : null, nowISO());
};

SqliteStore.prototype.stockOf = function (productId) {
  const r = this.db.prepare(
    "SELECT COALESCE(SUM(CASE WHEN type = 'in' THEN qty ELSE -qty END), 0) AS s " +
    'FROM stock_moves WHERE product_id = ?').get(productId);
  return engine.roundMoney(r.s);
};

SqliteStore.prototype.close = function () { this.db.close(); };

/* ------------------------- بيانات نموذجية ------------------------- */

function seedSample(store) {
  const db = store.db;
  const now = nowISO();
  const has = db.prepare('SELECT COUNT(*) AS c FROM products').get();
  if (has.c > 0) return;

  const cats = ['كابلات وأسلاك', 'مفاتيح وأفياش', 'إضاءة', 'قواطع ولوحات',
               'أدوات عزل وتثبيت', 'مواسير وخراطيم'];
  const insCat = db.prepare('INSERT INTO categories (name, created_at) VALUES (?, ?)');
  const catIds = {};
  cats.forEach(function (c) { catIds[c] = insCat.run(c, now).lastInsertRowid; });

  const products = [
    ['CBL-2.5', 'كابل نحاس 2.5 مم — لفة 100 متر', 'كابلات وأسلاك', 'roll', 1850, 2100, 5],
    ['CBL-4', 'كابل نحاس 4 مم — لفة 100 متر', 'كابلات وأسلاك', 'roll', 2875, 3250, 3],
    ['WIR-1.5', 'سلك نحاس مرن 1.5 مم — لفة 50 متر', 'كابلات وأسلاك', 'roll', 620, 745, 10],
    ['SWT-1P', 'مفتاح إضاءة عادي — أبيض', 'مفاتيح وأفياش', 'pcs', 18, 30, 200],
    ['SWT-2P', 'مفتاح مزدوج — أبيض', 'مفاتيح وأفياش', 'pcs', 26, 42, 150],
    ['SOC-16', 'فيش ثنائي 16 أمبير', 'مفاتيح وأفياش', 'pcs', 22, 36, 180],
    ['LMP-LED9', 'لمبة ليد 9 واط — أبيض بارد', 'إضاءة', 'pcs', 38, 60, 300],
    ['LMP-LED18', 'لمبة ليد 18 واط — أبيض دافئ', 'إضاءة', 'pcs', 65, 98, 120],
    ['FLR-120', 'سلاح فلورسنت 120 سم', 'إضاءة', 'pcs', 145, 210, 40],
    ['BRK-16', 'قاطع كهربائي 16 أمبير', 'قواطع ولوحات', 'pcs', 85, 130, 60],
    ['BRK-25', 'قاطع كهربائي 25 أمبير', 'قواطع ولوحات', 'pcs', 105, 160, 40],
    ['PNL-8', 'لوحة توزيع 8 خطوط', 'قواطع ولوحات', 'pcs', 260, 390, 12],
    ['TAP-19', 'شريط عزل كهربائي 19 مم', 'أدوات عزل وتثبيت', 'pcs', 9, 15, 400],
    ['TYR-100', 'سدادات تثبيت 100 حبة', 'أدوات عزل وتثبيت', 'box', 14, 24, 90],
    ['PVC-20', 'مواسير PVC 20 مم — 3 متر', 'مواسير وخراطيم', 'pcs', 32, 50, 150],
    ['CRD-16', 'خرطوم كورد 16 أمبير — 3 متر', 'مواسير وخراطيم', 'pcs', 48, 75, 80]
  ];
  const insP = db.prepare(
    'INSERT INTO products (sku, name, category_id, unit, cost_price, sale_price, tax_pct, ' +
    'reorder_level, avg_cost, is_active, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,1,?,?)');
  const insM = db.prepare(
    "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, ref_id, note, user_id, created_at) " +
    "VALUES (?, 'in', ?, ?, 'opening', NULL, 'رصيد افتتاحي', NULL, ?)");
  products.forEach(function (p) {
    const id = insP.run(p[0], p[1], catIds[p[2]], p[3], p[4], p[5], 0, p[6], p[4], now, now).lastInsertRowid;
    const openingQty = Math.max(p[6] * 2, 10);
    insM.run(id, openingQty, p[4], now);
  });

  db.prepare('INSERT INTO customers (name, phone, credit_limit, balance, created_at, updated_at) VALUES (?,?,?,?,?,?)')
    .run('أحمد محمود — عميل نقدي', '', 0, 0, now, now);
  db.prepare('INSERT INTO customers (name, phone, address, credit_limit, balance, created_at, updated_at) VALUES (?,?,?,?,?,?,?)')
    .run('شركة البناء الحديث', '01001234567', 'مدينة نصر — القاهرة', 50000, 0, now, now);
  db.prepare('INSERT INTO suppliers (name, phone, balance, created_at, updated_at) VALUES (?,?,?,?,?)')
    .run('مورد الفتح — العبور', '01112223334', 0, now, now);
  db.prepare('INSERT INTO suppliers (name, phone, balance, created_at, updated_at) VALUES (?,?,?,?,?)')
    .run('مورد الدلتا للكابلات', '01223334445', 0, now, now);

  db.prepare("INSERT INTO cashbox_tx (type, amount, ref_type, note, user_id, created_at) VALUES ('deposit', ?, 'opening', 'رصيد افتتاحي للصندوق', NULL, ?)")
    .run(3000, now);
  db.prepare("INSERT INTO journal (account, debit, credit, ref_type, note, created_at) VALUES ('cash', ?, 0, 'opening', 'رصيد افتتاحي للصندوق', ?)")
    .run(3000, now);
}

module.exports = { SCHEMA: SCHEMA, SqliteStore: SqliteStore, hashPassword: hashPassword,
                   verifyPassword: verifyPassword, ensureDefaults: DEFAULT_SETTINGS,
                   seedSample: seedSample, nowISO: nowISO };
