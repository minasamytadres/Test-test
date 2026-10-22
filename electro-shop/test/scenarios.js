'use strict';
/* =====================================================================
 * test/scenarios.js — 24 سيناريو تحقق لقواعد العمل (S1–S14 + X1–X10)
 * تعمل بدون أي اعتماديات خارجية: node test/business.test.js
 * ===================================================================== */

function buildScenarios(E) {

  function ok(cond, msg) {
    if (!cond) throw new Error('فشل التحقق: ' + (msg || 'شرط غير متحقق'));
  }
  function eq(a, b, msg) {
    if (a !== b) throw new Error((msg || 'قيم غير متطابقة') + ' — المتوقع ' + b + ' والفعلي ' + a);
  }
  function throwsCode(fn, code) {
    try { fn(); } catch (e) {
      if (e.code === code) return e;
      throw new Error('رمز خطأ مختلف — المتوقع ' + code + ' والفعلي ' + e.code);
    }
    throw new Error('لم يُرمَ أي خطأ — المتوقع ' + code);
  }

  const S = [];

  /* ------------------------- السيناريوهات الأساسية ------------------------- */

  S.push({ id: 'S1', name: 'حساب صافي البند مع خصم نسبي', run: function () {
    const l = E.calcLine(3, 25, 10);
    eq(l.gross, 75, 'الإجمالي');
    eq(l.net, 67.5, 'الصافي');
  }});

  S.push({ id: 'S2', name: 'خصم الفاتورة يوزَّع بعد خصوم البنود', run: function () {
    const t = E.calcInvoiceTotals(
      [{ qty: 2, unitPrice: 100 }, { qty: 1, unitPrice: 50, discountPct: 20 }],
      { invoiceDiscount: 10 });
    eq(t.subtotal, 250, 'الإجمالي قبل الخصومات');
    eq(t.lineDiscounts, 10, 'خصوم البنود');
    eq(t.invoiceDiscount, 24, 'خصم الفاتورة (10% من 240)');
    eq(t.total, 216, 'الإجمالي النهائي');
  }});

  S.push({ id: 'S3', name: 'الضريبة تُحسب بعد الخصومات', run: function () {
    const t = E.calcInvoiceTotals([{ qty: 1, unitPrice: 200 }], { invoiceDiscount: 25, taxPct: 14 });
    eq(t.net, 150, 'الصافي');
    eq(t.tax, 21, 'الضريبة (14% من 150)');
    eq(t.total, 171, 'الإجمالي');
  }});

  S.push({ id: 'S4', name: 'التكلفة الوسيطة — إضافة كمية واحدة', run: function () {
    eq(E.weightedAvgCost(10, 20, 10, 30), 25, 'متوسط (10×20 + 10×30) ÷ 20');
  }});

  S.push({ id: 'S5', name: 'التكلفة الوسيطة — إضافات متتالية', run: function () {
    let qty = 0, cost = 0;
    const a = E.weightedAvgCost(qty, cost, 100, 1850); qty += 100; cost = a;
    const b = E.weightedAvgCost(qty, cost, 50, 1990); qty += 50;
    eq(a, 1850, 'الإضافة الأولى');
    ok(Math.abs(b - 1896.66667) < 0.001, 'الإضافة الثانية: ' + b);
    eq(qty, 150, 'الكمية التراكمية');
  }});

  S.push({ id: 'S6', name: 'حساب ربح الفاتورة على التكلفة الوسيطة', run: function () {
    const items = [{ qty: 5, unitPrice: 2100 }];
    const totals = E.calcInvoiceTotals(items, {});
    const p = E.profitForInvoice(totals, function () { return 1850; });
    eq(p.cost, 9250, 'التكلفة');
    eq(p.profit, 1250, 'الربح (5 × (2100 − 1850))');
  }});

  S.push({ id: 'S7', name: 'منع البيع بكمية أكبر من المخزون', run: function () {
    throwsCode(function () { E.canSell(4, 5); }, 'E_STOCK_SHORT');
    ok(E.canSell(4, 4) === true, 'البيع بكامل المخزون مسموح');
    eq(E.stockAfterSale(10, 3), 7, 'المخزون بعد البيع');
  }});

  S.push({ id: 'S8', name: 'حد الائتمان يمنع تجاوز الرصيد', run: function () {
    throwsCode(function () { E.canExtendCredit(4000, 5000, 1500); }, 'E_CREDIT_LIMIT');
    ok(E.canExtendCredit(4000, 5000, 1000) === true, 'البيع ضمن الحد مسموح');
    ok(E.canExtendCredit(0, 0, 100) === false, 'حد صفري = لا بيع آجل');
  }});

  S.push({ id: 'S9', name: 'مرتجع البيع يُعيد المخزون ويحترم الكميات', run: function () {
    eq(E.stockAfterReturn(7, 3), 10, 'إعادة المخزون');
    eq(E.validateSaleReturn(10, 4, 6), 6, 'الكمية المتبقية القابلة للإرجاع');
    throwsCode(function () { E.validateSaleReturn(10, 4, 7); }, 'E_RETURN_QTY');
  }});

  S.push({ id: 'S10', name: 'الشراء يزيد المخزون ويسجل التكلفة', run: function () {
    eq(E.stockAfterPurchase(20, 30), 50, 'المخزون بعد الشراء');
    eq(E.weightedAvgCost(20, 10, 30, 14), 12.4, 'الوسيطة الجديدة');
  }});

  S.push({ id: 'S11', name: 'حساب الباقي للعميل في الدفع النقدي', run: function () {
    eq(E.cashChange(216, 250), 34, 'الباقي');
    throwsCode(function () { E.cashChange(216, 200); }, 'E_PAID_SHORT');
  }});

  S.push({ id: 'S12', name: 'تنبيه إعادة الطلب عند حد الطلب', run: function () {
    ok(E.isLowStock(5, 10) === true, 'أقل من الحد');
    ok(E.isLowStock(15, 10) === false, 'أعلى من الحد');
    ok(E.isLowStock(10, 10) === true, 'مساوٍ للحد = يحتاج طلب');
  }});

  S.push({ id: 'S13', name: 'مصفوفة الصلاحيات حسب الدور', run: function () {
    ok(E.roleCan('admin', 'users.manage') === true, 'المدير يدير المستخدمين');
    ok(E.roleCan('cashier', 'users.manage') === false, 'الكاشير لا يدير المستخدمين');
    ok(E.roleCan('cashier', 'sales.create') === true, 'الكاشير يبيع');
    ok(E.roleCan('accountant', 'sales.create') === false, 'المحاسب لا يبيع');
    throwsCode(function () { E.assertCan('cashier', 'backup.manage'); }, 'E_FORBIDDEN');
  }});

  S.push({ id: 'S14', name: 'تطبيق حد الخصم الأقصى', run: function () {
    const t = E.validateSale({ items: [{ qty: 1, unitPrice: 100, discountPct: 8 }],
      maxDiscountPct: 10, hasDiscountPerm: true });
    eq(t.total, 92, 'خصم البند يُحسب');
    throwsCode(function () {
      E.validateSale({ items: [{ qty: 1, unitPrice: 100, discountPct: 15, costPrice: 0 }],
        maxDiscountPct: 10 });
    }, 'E_DISCOUNT_CAP');
    throwsCode(function () {
      E.validateSale({ items: [{ qty: 1, unitPrice: 100, discountPct: 15, costPrice: 0 }],
        maxDiscountPct: 10, hasDiscountPerm: false, requireDiscountPerm: true });
    }, 'E_DISCOUNT_PERM');
  }});

  /* ------------------------- حالات حدية ------------------------- */

  S.push({ id: 'X1', name: 'رفض كمية صفرية أو سالبة', run: function () {
    throwsCode(function () { E.calcLine(0, 100, 0); }, 'E_QTY_INVALID');
    throwsCode(function () { E.calcLine(-1, 100, 0); }, 'E_QTY_INVALID');
    throwsCode(function () { E.assertQty(NaN); }, 'E_QTY_INVALID');
  }});

  S.push({ id: 'X2', name: 'رفض سعر سالب', run: function () {
    throwsCode(function () { E.assertPrice(-5, 'سعر'); }, 'E_PRICE_INVALID');
    throwsCode(function () { E.calcLine(1, -10, 0); }, 'E_PRICE_INVALID');
  }});

  S.push({ id: 'X3', name: 'دقة الفاصلة العائمة مع ROLL = 100000', run: function () {
    eq(E.roundMoney(0.1 + 0.2), 0.3, '0.1 + 0.2');
    eq(E.roundMoney(1.1 * 3), 3.3, '1.1 × 3');
    eq(E.roundMoney(2100 * 3 * 0.9), 5670, '2100 × 3 × 0.9');
    ok(Math.abs(E.roundMoney(1 / 3) - 0.33333) < 1e-9, 'ثلث');
  }});

  S.push({ id: 'X4', name: 'منع البيع بأقل من التكلفة', run: function () {
    throwsCode(function () {
      E.validateSale({ items: [{ qty: 1, unitPrice: 90, costPrice: 100 }], allowBelowCost: false });
    }, 'E_BELOW_COST');
    const t = E.validateSale({ items: [{ qty: 1, unitPrice: 90, costPrice: 100 }], allowBelowCost: true });
    eq(t.total, 90, 'السماح عند تفعيل الخيار');
  }});

  S.push({ id: 'X5', name: 'رفض فاتورة بلا بنود', run: function () {
    throwsCode(function () { E.calcInvoiceTotals([], {}); }, 'E_INVOICE_EMPTY');
    throwsCode(function () { E.calcInvoiceTotals(null, {}); }, 'E_INVOICE_EMPTY');
  }});

  S.push({ id: 'X6', name: 'خصم فاتورة 100% يجعل الإجمالي صفرًا', run: function () {
    const t = E.calcInvoiceTotals([{ qty: 2, unitPrice: 50 }], { invoiceDiscount: 100 });
    eq(t.net, 0, 'الصافي');
    eq(t.tax, 0, 'الضريبة');
    eq(t.total, 0, 'الإجمالي');
  }});

  S.push({ id: 'X7', name: 'اتساق التحويل إلى القروش', run: function () {
    eq(E.toPiasters(10), 1000, '10 جنيه = 1000 قرش');
    eq(E.toPiasters(12.5), 1250, '12.50 جنيه');
    eq(E.fromPiasters(1250), 12.5, 'العودة من القروش');
    eq(E.fromPiasters(E.toPiasters(67.5)), 67.5, 'دورة كاملة');
  }});

  S.push({ id: 'X8', name: 'رفض إرجاع أكثر من المُباع', run: function () {
    throwsCode(function () { E.validateSaleReturn(5, 0, 6); }, 'E_RETURN_QTY');
    throwsCode(function () { E.validateSaleReturn(5, 5, 1); }, 'E_RETURN_QTY');
    throwsCode(function () { E.validateSaleReturn(5, 0, 0); }, 'E_QTY_INVALID');
  }});

  S.push({ id: 'X9', name: 'التكلفة الوسيطة مع مخزون صفري = تكلفة الجديدة', run: function () {
    eq(E.weightedAvgCost(0, 0, 20, 45.75), 45.75, 'مخزون صفر');
    eq(E.weightedAvgCost(0, 999, 10, 30), 30, 'التكلفة القديمة تُهمل عند مخزون صفري');
  }});

  S.push({ id: 'X10', name: 'بيع آجل ضمن الحد يمر بنجاح', run: function () {
    ok(E.canExtendCredit(15000, 50000, 20000) === true, 'ضمن الحد');
    throwsCode(function () { E.canExtendCredit(40000, 50000, 11000); }, 'E_CREDIT_LIMIT');
    eq(E.cashBalanceAfter([
      { type: 'deposit', amount: 3000 },
      { type: 'sale', amount: 500 },
      { type: 'expense', amount: 200 }
    ]), 3300, 'رصيد الصندوق التراكمي');
  }});

  return S;
}

module.exports = { buildScenarios: buildScenarios };
