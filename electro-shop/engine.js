'use strict';
/* =====================================================================
 * engine.js — محرك قواعد العمل لمتجر مستلزمات الكهرباء
 * نظام محلي — عربي RTL — العملة: الجنيه المصري (ج.م)
 * ---------------------------------------------------------------------
 * مبادئ التصميم:
 *  1) المحرك نقي بالكامل: لا يقرأ الملفات ولا الشبكة ولا قاعدة البيانات.
 *  2) كل المبالغ تُقرَّب بعامل ROLL = 100000 لمنع تراكم أخطاء الفاصلة العائمة.
 *  3) كل عمليات المخزون تُحسب من حركات المخزون وليس من حقل مخزّن قابل للانحراف.
 *  4) كل دالة إما تُرجع قيمة صحيحة أو تُرمي EngineError برمز خطأ صريح.
 * ===================================================================== */

const ROLL = 100000;      // عامل التقريب المالي الثابت
const PIASTERS = 100;     // 1 جنيه = 100 قرش

class EngineError extends Error {
  constructor(code, message) {
    super(message || code);
    this.name = 'EngineError';
    this.code = code;
  }
}

/* ------------------------- أدوات مالية ------------------------- */

function roundMoney(v) {
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    throw new EngineError('E_MONEY_NAN', 'قيمة مالية غير صالحة');
  }
  return Math.round((v + Number.EPSILON) * ROLL) / ROLL;
}

function toPiasters(v) {
  return Math.round(roundMoney(v) * PIASTERS);
}

function fromPiasters(p) {
  return roundMoney(p / PIASTERS);
}

function formatEGP(v) {
  const n = roundMoney(Number(v) || 0);
  const sign = n < 0 ? '-' : '';
  const abs = Math.abs(n);
  const whole = Math.floor(abs).toLocaleString('en-US');
  const frac = String(Math.round((abs - Math.floor(abs)) * 100)).padStart(2, '0');
  return sign + whole + '.' + frac + ' ج.م';
}

/* ------------------------- الصلاحيات والأدوار ------------------------- */

const PERMS = [
  'products.write', 'inventory.adjust', 'sales.create', 'sales.discount',
  'returns.create', 'purchases.create', 'customers.write', 'suppliers.write',
  'cashbox.manage', 'expenses.create', 'reports.view', 'audit.view',
  'users.manage', 'settings.write', 'backup.manage', 'import.run'
];

const ROLES = {
  admin:     PERMS.slice(),
  manager:   ['products.write','inventory.adjust','sales.create','sales.discount','returns.create',
              'purchases.create','customers.write','suppliers.write','cashbox.manage',
              'expenses.create','reports.view','audit.view','import.run','backup.manage'],
  cashier:   ['sales.create','returns.create','customers.write','reports.view'],
  accountant:['reports.view','cashbox.manage','expenses.create','audit.view','customers.write','suppliers.write']
};

function roleCan(role, perm) {
  const list = ROLES[role];
  if (!list) throw new EngineError('E_ROLE_UNKNOWN', 'دور غير معروف: ' + role);
  return list.indexOf(perm) !== -1;
}

function assertCan(role, perm) {
  if (!roleCan(role, perm)) {
    throw new EngineError('E_FORBIDDEN', 'الدور «' + role + '» لا يمتلك صلاحية «' + perm + '»');
  }
}

/* ------------------------- الكميات والمخزون ------------------------- */

function assertQty(qty) {
  if (typeof qty !== 'number' || !Number.isFinite(qty) || qty <= 0) {
    throw new EngineError('E_QTY_INVALID', 'الكمية يجب أن تكون رقمًا موجبًا أكبر من صفر');
  }
  return roundMoney(qty);
}

function assertPrice(price, label) {
  if (typeof price !== 'number' || !Number.isFinite(price) || price < 0) {
    throw new EngineError('E_PRICE_INVALID', 'سعر غير صالح: ' + (label || ''));
  }
  return roundMoney(price);
}

function stockOf(moves, productId) {
  let s = 0;
  for (const m of moves) {
    if (m.product_id !== productId) continue;
    s += (m.type === 'in' ? m.qty : -m.qty);
  }
  return roundMoney(s);
}

function canSell(stock, qty) {
  assertQty(qty);
  if (roundMoney(stock) < qty) {
    throw new EngineError('E_STOCK_SHORT',
      'المخزون غير كافٍ: المتاح ' + stock + ' والمطلوب ' + qty);
  }
  return true;
}

function stockAfterSale(stock, qty) { canSell(stock, qty); return roundMoney(stock - qty); }
function stockAfterReturn(stock, qty) { assertQty(qty); return roundMoney(stock + qty); }
function stockAfterPurchase(stock, qty) { assertQty(qty); return roundMoney(stock + qty); }
function stockAfterAdjust(stock, delta) {
  if (typeof delta !== 'number' || !Number.isFinite(delta) || delta === 0) {
    throw new EngineError('E_ADJUST_ZERO', 'قيمة التسوية يجب أن تكون رقمًا غير صفري');
  }
  const out = roundMoney(stock + delta);
  if (out < 0) throw new EngineError('E_STOCK_SHORT', 'التسوية تُنتج مخزونًا سالبًا');
  return out;
}

function isLowStock(stock, reorderLevel) {
  return roundMoney(stock) <= (Number(reorderLevel) || 0);
}

/* ------------------------- التكلفة المرجحة ------------------------- */

function weightedAvgCost(oldQty, oldAvgCost, addQty, addUnitCost) {
  assertQty(addQty);
  assertPrice(addUnitCost, 'تكلفة الشراء');
  const oq = Math.max(0, Number(oldQty) || 0);
  if (oq === 0) return roundMoney(addUnitCost);
  const oc = Math.max(0, Number(oldAvgCost) || 0);
  const total = (oq * oc) + (addQty * addUnitCost);
  return roundMoney(total / (oq + addQty));
}

/* ------------------------- فواتير البيع ------------------------- */

function calcLine(qty, unitPrice, discountPct) {
  assertQty(qty);
  assertPrice(unitPrice, 'سعر الوحدة');
  const disc = Number(discountPct) || 0;
  if (disc < 0 || disc > 100) {
    throw new EngineError('E_DISCOUNT_RANGE', 'نسبة الخصم يجب أن تكون بين 0 و 100');
  }
  const gross = qty * unitPrice;
  const line = gross * (1 - disc / 100);
  return { qty, unitPrice: roundMoney(unitPrice), discountPct: disc,
           gross: roundMoney(gross), net: roundMoney(line) };
}

function calcInvoiceTotals(items, opts) {
  if (!Array.isArray(items) || items.length === 0) {
    throw new EngineError('E_INVOICE_EMPTY', 'لا يمكن إصدار فاتورة بدون بنود');
  }
  const o = opts || {};
  const invDisc = Number(o.invoiceDiscount) || 0;
  if (invDisc < 0 || invDisc > 100) {
    throw new EngineError('E_DISCOUNT_RANGE', 'خصم الفاتورة يجب أن يكون بين 0 و 100');
  }
  const taxPct = Math.max(0, Number(o.taxPct) || 0);
  let subtotal = 0, lineDiscounts = 0;
  const lines = items.map(function (it) {
    const line = calcLine(it.qty, it.unitPrice, it.discountPct);
    subtotal += line.gross;
    lineDiscounts += (line.gross - line.net);
    return line;
  });
  subtotal = roundMoney(subtotal);
  const afterLines = roundMoney(subtotal - lineDiscounts);
  const invDiscAmount = roundMoney(afterLines * invDisc / 100);
  const net = roundMoney(afterLines - invDiscAmount);
  const tax = roundMoney(net * taxPct / 100);
  const total = roundMoney(net + tax);
  return { lines: lines, subtotal: subtotal, lineDiscounts: roundMoney(lineDiscounts),
           invoiceDiscountPct: invDisc, invoiceDiscount: invDiscAmount,
           net: net, taxPct: taxPct, tax: tax, total: total };
}

/* ------------------------- قواعد البيع ------------------------- */

function validateSale(input) {
  const items = input && input.items;
  const totals = calcInvoiceTotals(items, {
    invoiceDiscount: input.invoiceDiscountPct,
    taxPct: input.taxPct
  });
  const maxDisc = Number(input.maxDiscountPct) || 0;
  const allowBelowCost = !!input.allowBelowCost;
  for (const it of items) {
    const d = Number(it.discountPct) || 0;
    if (input.requireDiscountPerm && d > 0 && !input.hasDiscountPerm) {
      throw new EngineError('E_DISCOUNT_PERM', 'الخصم يتطلب صلاحية sales.discount');
    }
    if (maxDisc > 0 && d > maxDisc) {
      throw new EngineError('E_DISCOUNT_CAP',
        'الخصم يتجاوز الحد الأقصى المسموح (' + maxDisc + '%)');
    }
    if (!allowBelowCost && it.costPrice != null) {
      const net = calcLine(it.qty, it.unitPrice, d).net / it.qty;
      if (roundMoney(net) < roundMoney(it.costPrice)) {
        throw new EngineError('E_BELOW_COST',
          'سعر البيع أقل من التكلفة للصنف: ' + (it.name || it.productId));
      }
    }
  }
  return totals;
}

function canExtendCredit(customerBalance, creditLimit, invoiceTotal) {
  const bal = roundMoney(customerBalance || 0);
  const lim = Number(creditLimit);
  if (lim == null || lim <= 0) return false; // حد صفر يعني: البيع الآجل غير مسموح
  if (roundMoney(bal + invoiceTotal) > roundMoney(lim)) {
    throw new EngineError('E_CREDIT_LIMIT',
      'تجاوز حد الائتمان: الرصيد بعد الفاتورة سيصبح ' + formatEGP(bal + invoiceTotal) +
      ' والحد ' + formatEGP(lim));
  }
  return true;
}

function cashChange(total, paid) {
  assertPrice(paid, 'المبلغ المدفوع');
  if (roundMoney(paid) < roundMoney(total)) {
    throw new EngineError('E_PAID_SHORT', 'المدفوع أقل من إجمالي الفاتورة');
  }
  return roundMoney(paid - total);
}

/* ------------------------- المرتجعات ------------------------- */

function validateSaleReturn(soldQty, alreadyReturned, returnQty) {
  assertQty(returnQty);
  const remaining = roundMoney(soldQty - (Number(alreadyReturned) || 0));
  if (returnQty > remaining) {
    throw new EngineError('E_RETURN_QTY',
      'كمية المرتجع تتجاوز الكمية المتبقية القابلة للإرجاع (' + remaining + ')');
  }
  return roundMoney(returnQty);
}

/* ------------------------- الأرباح ------------------------- */

function profitForInvoice(totals, costOfLine) {
  let cost = 0;
  totals.lines.forEach(function (line, i) {
    cost += costOfLine(i) * line.qty;
  });
  cost = roundMoney(cost);
  return { cost: cost, net: totals.net, profit: roundMoney(totals.net - cost) };
}

/* ------------------------- عمليات الصندوق ------------------------- */

const CASH_TX = { deposit: 1, sale: 1, 'purchase-return': 1, withdraw: -1, purchase: -1,
                  'sale-return': -1, expense: -1, 'payment-out': -1, 'payment-in': 1 };

function cashEffect(type, amount) {
  const dir = CASH_TX[type];
  if (!dir) throw new EngineError('E_CASH_TYPE', 'نوع حركة صندوق غير معروف: ' + type);
  assertPrice(amount, 'مبلغ الحركة');
  return { type: type, amount: roundMoney(amount), delta: roundMoney(dir * amount) };
}

function cashBalanceAfter(txs) {
  let b = 0;
  for (const t of txs) b += cashEffect(t.type, t.amount).delta;
  return roundMoney(b);
}

/* ------------------------- وحدة الأصناف ------------------------- */

const UNITS = { pcs: 'قطعة', box: 'علبة', meter: 'متر', roll: 'لفة', kg: 'كجم' };

function assertUnit(u) {
  if (!UNITS[u]) throw new EngineError('E_UNIT', 'وحدة قياس غير معروفة: ' + u);
  return u;
}

/* ------------------------- التصدير ------------------------- */

module.exports = {
  ROLL: ROLL, PIASTERS: PIASTERS, EngineError: EngineError,
  roundMoney: roundMoney, toPiasters: toPiasters, fromPiasters: fromPiasters,
  formatEGP: formatEGP,
  PERMS: PERMS, ROLES: ROLES, roleCan: roleCan, assertCan: assertCan,
  assertQty: assertQty, assertPrice: assertPrice,
  stockOf: stockOf, canSell: canSell, stockAfterSale: stockAfterSale,
  stockAfterReturn: stockAfterReturn, stockAfterPurchase: stockAfterPurchase,
  stockAfterAdjust: stockAfterAdjust, isLowStock: isLowStock,
  weightedAvgCost: weightedAvgCost,
  calcLine: calcLine, calcInvoiceTotals: calcInvoiceTotals,
  validateSale: validateSale, canExtendCredit: canExtendCredit,
  cashChange: cashChange, validateSaleReturn: validateSaleReturn,
  profitForInvoice: profitForInvoice,
  cashEffect: cashEffect, cashBalanceAfter: cashBalanceAfter,
  UNITS: UNITS, assertUnit: assertUnit
};
