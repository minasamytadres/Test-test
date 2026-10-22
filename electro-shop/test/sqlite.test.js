'use strict';
/* =====================================================================
 * test/sqlite.test.js — اختبارات تكامل طبقة قاعدة البيانات
 * يتطلب: npm install أولًا (better-sqlite3)
 * التشغيل: npm run test:sqlite  (أو: node test/sqlite.test.js)
 * ===================================================================== */

const os = require('os');
const path = require('path');
const fs = require('fs');
const DB = require('../server/db.js');

let pass = 0, fail = 0;
function check(name, fn) {
  try {
    fn();
    pass++;
    console.log('  [نجاح] ' + name);
  } catch (e) {
    fail++;
    console.log('  [فشل] ' + name);
    console.log('         ' + e.message);
  }
}
function ok(cond, msg) { if (!cond) throw new Error(msg || 'شرط غير متحقق'); }
function eq(a, b, msg) { if (a !== b) throw new Error((msg || '') + ' — المتوقع ' + b + ' والفعلي ' + a); }

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'electro-test-'));
const dbPath = path.join(tmpDir, 'test.db');
const store = new DB.SqliteStore(dbPath);

console.log('');
console.log('  اختبارات تكامل قاعدة البيانات');
console.log('  ' + '='.repeat(52));

check('إنشاء الجداول الافتراضية', function () {
  const tables = store.db.prepare(
    "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").get();
  ok(tables.c >= 23, 'عدد الجداول ' + tables.c + ' — المتوقع 23 على الأقل');
});

check('الجداول المطلوبة موجودة', function () {
  ['settings','users','audit_log','categories','products','stock_moves','customers',
   'suppliers','sales','sale_items','purchases','purchase_items','sale_returns',
   'sale_return_items','purchase_returns','purchase_return_items','cashbox_tx',
   'payments','journal','expenses','backups','price_history','counters']
  .forEach(function (t) {
    const r = store.db.prepare("SELECT COUNT(*) AS c FROM sqlite_master WHERE name = ?").get(t);
    ok(r.c === 1, 'الجدول ' + t + ' غير موجود');
  });
});

check('مستخدم admin افتراضي بكلمة مرور صحيحة', function () {
  const u = store.db.prepare("SELECT * FROM users WHERE username = 'admin'").get();
  ok(u, 'المستخدم admin غير موجود');
  ok(DB.verifyPassword('admin', u.password_hash), 'كلمة المرور الافتراضية لا تُقبل');
  ok(!DB.verifyPassword('wrong', u.password_hash), 'كلمة مرور خاطئة تُقبل — خطأ أمني');
});

check('تجزئة كلمات المرور scrypt فريدة لكل تشفير', function () {
  const h1 = DB.hashPassword('secret1');
  const h2 = DB.hashPassword('secret1');
  ok(h1 !== h2, 'التجزئة ثابتة — يجب أن يتغير الملح كل مرة');
  ok(DB.verifyPassword('secret1', h1), 'التحقق فشل بعد إعادة التشفير');
});

check('الإعدادات الافتراضية مهيأة', function () {
  eq(store.getSetting('shop_name'), 'متجر النور لمستلزمات الكهرباء', 'اسم المتجر');
  ok(store.getSetting('session_secret'), 'مفتاح الجلسة غير مهيأ');
  ok(store.getSetting('session_secret').length >= 32, 'مفتاح الجلسة قصير جدًا');
});

check('تحديث الإعدادات يعمل', function () {
  store.setSetting('shop_name', 'متجر تجريبي');
  eq(store.getSetting('shop_name'), 'متجر تجريبي', 'قراءة بعد الكتابة');
});

check('الترقيم التسلسلي للمستندات', function () {
  const n1 = store.nextNumber('INV');
  const n2 = store.nextNumber('INV');
  ok(n2 > n1, 'الترقيم لا يتزايد');
  ok(/^INV-\d{4}-\d{5}$/.test(n1), 'صيغة الرقم غير صحيحة: ' + n1);
});

check('بيانات العينة تُزرع مرة واحدة', function () {
  DB.seedSample(store);
  const c1 = store.db.prepare('SELECT COUNT(*) AS c FROM products').get().c;
  DB.seedSample(store);
  const c2 = store.db.prepare('SELECT COUNT(*) AS c FROM products').get().c;
  eq(c1, c2, 'الزرع المتكرر يضاعف البيانات');
  ok(c1 >= 16, 'عدد الأصناف النموذجية ' + c1);
});

check('أرصدة المخزون الافتتاحية صحيحة', function () {
  const p = store.db.prepare('SELECT * FROM products WHERE sku = ?').get('CBL-2.5');
  ok(p, 'الصنف النموذجي غير موجود');
  eq(store.stockOf(p.id), Math.max(p.reorder_level * 2, 10), 'رصيد الافتتاحي');
});

check('حركات المخزون تحسب الاتجاهين', function () {
  const p = store.db.prepare('SELECT * FROM products WHERE sku = ?').get('WIR-1.5');
  const before = store.stockOf(p.id);
  store.db.prepare(
    "INSERT INTO stock_moves (product_id, type, qty, unit_cost, ref_type, created_at) VALUES (?, 'out', 5, 620, 'test', datetime('now'))")
    .run(p.id);
  eq(store.stockOf(p.id), before - 5, 'الصرف من المخزون');
});

check('الصندوق يبدأ برصيد الافتتاحية', function () {
  const E = require('../engine.js');
  const txs = store.db.prepare('SELECT type, amount FROM cashbox_tx').all();
  eq(E.cashBalanceAfter(txs), 3000, 'رصيد الصندوق الافتراضي');
});

check('سجل التدقيق يسجل العمليات', function () {
  store.audit({ id: 1, username: 'tester' }, 'test.action', 'thing', 1, { x: 1 });
  const a = store.db.prepare("SELECT * FROM audit_log WHERE action = 'test.action'").get();
  ok(a, 'القيد غير مسجل');
  ok(JSON.parse(a.details).x === 1, 'التفاصيل لم تُحفظ');
});

store.close();
try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) {}

console.log('  ' + '='.repeat(52));
console.log('  النتيجة: ' + pass + ' نجاح' + (fail > 0 ? ' — ' + fail + ' فشل' : ''));
console.log('');
if (fail > 0) process.exit(1);

