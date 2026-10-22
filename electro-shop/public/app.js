'use strict';
/* =====================================================================
 * public/app.js — منطق الواجهة (SPA عربية RTL)
 * ===================================================================== */

const fmt = (v) => (Math.round((Number(v) || 0) * 100) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' ج.م';
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const dt = (s) => s ? String(s).replace('T', ' ').slice(0, 16) : '';
const UNITS = { pcs: 'قطعة', box: 'علبة', meter: 'متر', roll: 'لفة', kg: 'كجم' };
const ROLE_NAMES = { admin: 'مدير النظام', manager: 'مدير', cashier: 'كاشير', accountant: 'محاسب' };

let ME = null, PERMS = [], SETTINGS = {};

/* ------------------------- أدوات الشبكة ------------------------- */

async function api(path, opts) {
  const o = Object.assign({ headers: { 'Content-Type': 'application/json' } }, opts || {});
  if (o.body && typeof o.body !== 'string') o.body = JSON.stringify(o.body);
  const res = await fetch(path, o);
  if (res.status === 401) { showLogin(); throw new Error('انتهت الجلسة — أعد تسجيل الدخول'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'خطأ غير متوقع');
  return data;
}

function toast(msg, kind) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast ' + (kind || 'ok');
  setTimeout(() => t.classList.add('hidden'), 2600);
  t.classList.remove('hidden');
}

function can(perm) { return perm === '' || PERMS.indexOf(perm) !== -1; }

/* ------------------------- الدخول ------------------------- */

function showLogin() {
  document.getElementById('app').classList.add('hidden');
  document.getElementById('login-screen').classList.remove('hidden');
}

async function doLogin(e) {
  e.preventDefault();
  const err = document.getElementById('login-error');
  err.textContent = '';
  try {
    ME = await api('/api/login', { method: 'POST', body: {
      username: document.getElementById('login-username').value.trim(),
      password: document.getElementById('login-password').value } });
    await afterLogin();
  } catch (ex) { err.textContent = ex.message; }
}

async function afterLogin() {
  PERMS = (await api('/api/permissions')).perms;
  SETTINGS = await api('/api/settings');
  document.getElementById('login-screen').classList.add('hidden');
  document.getElementById('app').classList.remove('hidden');
  document.getElementById('who').textContent = ME.full_name + ' — ' + (ROLE_NAMES[ME.role] || ME.role);
  document.getElementById('shop-name').textContent = SETTINGS.shop_name || 'المتجر';
  document.querySelectorAll('#nav a').forEach((a) => {
    const p = a.getAttribute('data-perm');
    a.style.display = can(p) ? '' : 'none';
  });
  if (ME.force_change) {
    openModal('تغيير كلمة المرور الافتراضية', `
      <p class="muted">حسابك يستخدم كلمة مرور افتراضية — يلزم تغييرها الآن.</p>
      <div class="form-grid">
        <div class="field full"><label>كلمة المرور الحالية</label><input id="cp-old" type="password"></div>
        <div class="field full"><label>كلمة المرور الجديدة (6 أحرف على الأقل)</label><input id="cp-new" type="password"></div>
      </div>
      <button class="btn primary" style="margin-top:14px" onclick="changePwd()">حفظ</button>`);
  }
  if (!location.hash || location.hash === '#') location.hash = '#dashboard';
  route();
}

async function changePwd() {
  try {
    await api('/api/change-password', { method: 'POST', body: {
      oldPassword: document.getElementById('cp-old').value,
      newPassword: document.getElementById('cp-new').value } });
    closeModal(); toast('تم تغيير كلمة المرور');
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- الهيكل والتوجيه ------------------------- */

const TITLES = { dashboard: 'لوحة التحكم', pos: 'نقطة البيع', products: 'الأصناف', inventory: 'المخزون',
  sales: 'المبيعات', purchases: 'المشتريات', returns: 'المرتجعات', customers: 'العملاء',
  suppliers: 'الموردون', cashbox: 'الصندوق', reports: 'التقارير', users: 'المستخدمون',
  backup: 'النسخ الاحتياطي', settings: 'الإعدادات', audit: 'سجل التدقيق' };

function route() {
  const sec = (location.hash || '#dashboard').slice(1);
  const navLink = document.querySelector('[data-sec="' + sec + '"]');
  if (!VIEWS[sec] || !navLink || !can(navLink.getAttribute('data-perm') || '')) {
    location.hash = '#dashboard'; return;
  }
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.getAttribute('data-sec') === sec));
  document.getElementById('section-title').textContent = TITLES[sec];
  VIEWS[sec]().catch((e) => view.innerHTML = '<div class="card err">' + esc(e.message) + '</div>');
}

/* ------------------------- النوافذ ------------------------- */

function openModal(title, html) {
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = html;
  document.getElementById('modal').classList.remove('hidden');
}
function closeModal() { document.getElementById('modal').classList.add('hidden'); }

/* ------------------------- لوحة التحكم ------------------------- */

async function vDashboard() {
  const d = await api('/api/dashboard');
  view.innerHTML = `
    <div class="cards">
      <div class="stat"><span class="muted">مبيعات اليوم</span><div class="v">${fmt(d.sales_today)}</div></div>
      <div class="stat"><span class="muted">مبيعات الشهر</span><div class="v">${fmt(d.sales_month)}</div></div>
      <div class="stat ok"><span class="muted">أرباح الشهر</span><div class="v">${fmt(d.profit_month)}</div></div>
      <div class="stat"><span class="muted">رصيد الصندوق</span><div class="v">${fmt(d.cash_balance)}</div></div>
      <div class="stat warn"><span class="muted">أصناف تحت حد الطلب</span><div class="v">${d.low_stock_count}</div></div>
      <div class="stat err"><span class="muted">مستحقات على العملاء</span><div class="v">${fmt(d.receivables)}</div></div>
    </div>
    <div class="card"><b>مستحقات للموردين:</b> ${fmt(d.payables)}
      <p class="muted" style="margin-top:8px">تُحدَّث هذه اللوحة تلقائيًا مع كل عملية بيع أو شراء أو تحصيل.</p>
    </div>`;
}

/* ------------------------- نقطة البيع ------------------------- */

let cart = [];

async function vPOS() {
  const [products, customers] = await Promise.all([api('/api/products'), api('/api/customers')]);
  const active = products.filter((p) => p.is_active && p.stock > 0);
  view.innerHTML = `
    <div class="pos">
      <div>
        <div class="pos-search">
          <input id="pos-q" placeholder="ابحث بالاسم أو الرمز أو الباركود..." oninput="posFilter()">
        </div>
        <div class="pos-products" id="pos-products"></div>
      </div>
      <div class="cart">
        <h3>سلة الفاتورة</h3>
        <div class="cart-items" id="cart-items"></div>
        <div class="cart-totals">
          <div><span>الإجمالي قبل الخصم</span><span id="t-gross">${fmt(0)}</span></div>
          <div><span>خصم الفاتورة %</span>
            <input id="inv-disc" style="width:70px" value="0" oninput="renderCart()"></div>
          <div class="grand"><span>الإجمالي النهائي</span><span id="t-total">${fmt(0)}</span></div>
        </div>
        <div class="row" style="margin-top:12px">
          <div class="field"><label>نوع الدفع</label>
            <select id="pay-type"><option value="cash">نقدي</option><option value="credit">آجل (على الحساب)</option></select></div>
          <div class="field"><label>العميل</label>
            <select id="pos-customer" onchange="renderCart()"><option value="">— عميل نقدي —</option>
              ${customers.map((c) => '<option value="' + c.id + '">' + esc(c.name) + '</option>').join('')}
            </select></div>
        </div>
        <div class="field" style="margin-top:10px"><label>المبلغ المدفوع (نقدي)</label>
          <input id="pos-paid" style="width:100%" placeholder="اتركه فارغًا = كامل المبلغ" oninput="renderCart()"></div>
        <button class="btn primary" style="width:100%;margin-top:14px" onclick="submitSale()">إتمام البيع</button>
        <p id="pos-change" class="muted" style="margin-top:8px"></p>
      </div>
    </div>`;
  window.__posProducts = active;
  window.__posCustomers = customers;
  posFilter();
}

function posFilter() {
  const q = (document.getElementById('pos-q').value || '').trim().toLowerCase();
  const list = (window.__posProducts || []).filter((p) =>
    !q || p.name.toLowerCase().indexOf(q) !== -1 || p.sku.toLowerCase().indexOf(q) !== -1 ||
    (p.barcode || '').toLowerCase().indexOf(q) !== -1);
  document.getElementById('pos-products').innerHTML = list.map((p) => `
    <div class="pos-item" onclick="addToCart(${p.id})">
      <div class="nm">${esc(p.name)}</div>
      <div class="pr">${fmt(p.sale_price)}</div>
      <div class="st">المتاح: ${p.stock} ${esc(UNITS[p.unit] || '')}</div>
    </div>`).join('') || '<p class="muted">لا توجد أصناف مطابقة.</p>';
}

function addToCart(id) {
  const p = window.__posProducts.find((x) => x.id === id);
  if (!p) return;
  const line = cart.find((l) => l.productId === id);
  const q = line ? line.qty + 1 : 1;
  if (q > p.stock) return toast('الكمية المطلوبة تتجاوز المخزون المتاح', 'err');
  if (line) line.qty = q; else cart.push({ productId: id, name: p.name, unitPrice: p.sale_price, qty: 1, discountPct: 0, stock: p.stock });
  renderCart();
}

function cartQty(i, d) {
  const l = cart[i];
  const q = l.qty + d;
  if (q <= 0) { cart.splice(i, 1); } else if (q > l.stock) { return toast('لا يوجد مخزون كافٍ', 'err'); } else { l.qty = q; }
  renderCart();
}

function cartDisc(i, v) {
  cart[i].discountPct = Math.max(0, Math.min(Number(v) || 0, 100));
  renderCart();
}

function renderCart() {
  const gross = cart.reduce((s, l) => s + l.qty * l.unitPrice * (1 - l.discountPct / 100), 0);
  const d = Math.max(0, Math.min(100, Number(document.getElementById('inv-disc').value) || 0));
  const total = gross * (1 - d / 100);
  document.getElementById('cart-items').innerHTML = cart.map((l, i) => `
    <div class="cart-line">
      <div>${esc(l.name)}<br><span class="muted">${fmt(l.unitPrice)} × ${l.qty}</span></div>
      <div class="q">
        <input style="width:52px" value="${l.discountPct}" title="خصم %" oninput="cartDisc(${i}, this.value)">%
        <button onclick="cartQty(${i}, 1)">+</button>
        <button onclick="cartQty(${i}, -1)">−</button>
        <b>${fmt(l.qty * l.unitPrice * (1 - l.discountPct / 100))}</b>
      </div>
    </div>`).join('') || '<p class="muted">اختر الأصناف لإضافتها إلى الفاتورة.</p>';
  document.getElementById('t-gross').textContent = fmt(gross);
  document.getElementById('t-total').textContent = fmt(total);
  const paid = Number(document.getElementById('pos-paid').value) || 0;
  document.getElementById('pos-change').textContent =
    document.getElementById('pay-type').value === 'cash' && paid > 0 ?
    (paid >= total ? 'الباقي للعميل: ' + fmt(paid - total) : 'المدفوع أقل من الإجمالي') : '';
}

async function submitSale() {
  try {
    const gross = cart.reduce((s, l) => s + l.qty * l.unitPrice * (1 - l.discountPct / 100), 0);
    const d = Math.max(0, Math.min(100, Number(document.getElementById('inv-disc').value) || 0));
    const total = gross * (1 - d / 100);
    const paidVal = document.getElementById('pos-paid').value;
    const r = await api('/api/sales', { method: 'POST', body: {
      items: cart.map((l) => ({ productId: l.productId, qty: l.qty, unitPrice: l.unitPrice, discountPct: l.discountPct })),
      invoiceDiscountPct: d,
      paymentType: document.getElementById('pay-type').value,
      customerId: document.getElementById('pos-customer').value || null,
      paid: paidVal === '' ? total : Number(paidVal) } });
    cart = [];
    toast('تم إصدار الفاتورة ' + r.number + (r.change > 0 ? ' — الباقي: ' + fmt(r.change) : ''));
    vPOS();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- الأصناف ------------------------- */

async function vProducts() {
  const [products, cats] = await Promise.all([api('/api/products'), api('/api/categories')]);
  const canWrite = PERMS.indexOf('products.write') !== -1;
  view.innerHTML = `
    <div class="toolbar">
      <input id="p-q" placeholder="بحث..." oninput="filterTable('p-tbl','p-q')">
      ${canWrite ? '<button class="btn primary" onclick="productForm()">إضافة صنف</button>' : ''}
      ${canWrite ? '<button class="btn ghost" onclick="catForm()">إدارة الفئات</button>' : ''}
      ${canWrite ? '<button class="btn ghost" onclick="importForm()">استيراد CSV</button>' : ''}
      <a class="btn ghost" href="/api/products?format=csv">تصدير CSV</a>
    </div>
    <table class="grid" id="p-tbl"><thead><tr>
      <th>الرمز</th><th>الاسم</th><th>الفئة</th><th>الوحدة</th><th>التكلفة</th><th>سعر البيع</th><th>المخزون</th><th>حالة</th><th></th>
    </tr></thead><tbody>
    ${products.map((p) => `<tr>
      <td>${esc(p.sku)}</td><td>${esc(p.name)}</td><td>${esc(p.category_name || '—')}</td>
      <td>${esc(UNITS[p.unit] || p.unit)}</td><td>${fmt(p.cost_price)}</td><td>${fmt(p.sale_price)}</td>
      <td>${p.stock} ${esc(UNITS[p.unit] || '')}</td>
      <td>${p.is_active ? '<span class="badge ok">نشط</span>' : '<span class="badge err">موقوف</span>'}</td>
      <td>${canWrite ? '<button class="btn sm ghost" onclick="productForm(' + p.id + ')">تعديل</button>' : ''}</td>
    </tr>`).join('')}
    </tbody></table>`;
  window.__cats = cats; window.__products = products;
}

function filterTable(tblId, inputId) {
  const q = (document.getElementById(inputId).value || '').toLowerCase();
  document.querySelectorAll('#' + tblId + ' tbody tr').forEach((tr) => {
    tr.style.display = tr.textContent.toLowerCase().indexOf(q) !== -1 ? '' : 'none';
  });
}

function productForm(id) {
  const p = id ? window.__products.find((x) => x.id === id) : null;
  openModal(p ? 'تعديل صنف' : 'إضافة صنف', `
    <div class="form-grid">
      <div class="field"><label>الرمز SKU</label><input id="f-sku" value="${p ? esc(p.sku) : ''}" ${p ? 'disabled' : ''}></div>
      <div class="field"><label>الوحدة</label><select id="f-unit">
        ${Object.keys(UNITS).map((u) => '<option value="' + u + '"' + (p && p.unit === u ? ' selected' : '') + '>' + UNITS[u] + '</option>').join('')}
      </select></div>
      <div class="field full"><label>اسم الصنف</label><input id="f-name" value="${p ? esc(p.name) : ''}"></div>
      <div class="field"><label>الفئة</label><select id="f-cat">
        <option value="">—</option>
        ${window.__cats.map((c) => '<option value="' + c.id + '"' + (p && p.category_id === c.id ? ' selected' : '') + '>' + esc(c.name) + '</option>').join('')}
      </select></div>
      <div class="field"><label>الباركود</label><input id="f-barcode" value="${p ? esc(p.barcode || '') : ''}"></div>
      <div class="field"><label>سعر التكلفة</label><input id="f-cost" type="number" step="0.01" value="${p ? p.cost_price : ''}"></div>
      <div class="field"><label>سعر البيع</label><input id="f-sale" type="number" step="0.01" value="${p ? p.sale_price : ''}"></div>
      <div class="field"><label>حد إعادة الطلب</label><input id="f-reorder" type="number" value="${p ? p.reorder_level : ''}"></div>
      <div class="field"><label>نشط</label><select id="f-active">
        <option value="1">نعم</option><option value="0" ${p && !p.is_active ? 'selected' : ''}>لا</option></select></div>
    </div>
    <button class="btn primary" style="margin-top:16px" onclick="saveProduct(${id || 0})">حفظ</button>`);
}

async function saveProduct(id) {
  try {
    const body = {
      sku: document.getElementById('f-sku').value.trim(),
      name: document.getElementById('f-name').value.trim(),
      category_id: document.getElementById('f-cat').value || null,
      unit: document.getElementById('f-unit').value,
      barcode: document.getElementById('f-barcode').value.trim(),
      cost_price: Number(document.getElementById('f-cost').value) || 0,
      sale_price: Number(document.getElementById('f-sale').value) || 0,
      reorder_level: Number(document.getElementById('f-reorder').value) || 0,
      is_active: document.getElementById('f-active').value === '1' };
    if (id) await api('/api/products/' + id, { method: 'PUT', body });
    else await api('/api/products', { method: 'POST', body });
    closeModal(); toast('تم الحفظ'); vProducts();
  } catch (ex) { toast(ex.message, 'err'); }
}

function catForm() {
  openModal('الفئات', `
    <div id="cat-list">${window.__cats.map((c) => '<div class="cart-line"><span>' + esc(c.name) + '</span></div>').join('') || '<p class="muted">لا توجد فئات.</p>'}</div>
    <div class="row" style="margin-top:14px">
      <input id="cat-name" placeholder="اسم فئة جديدة">
      <button class="btn primary" onclick="addCat()">إضافة</button>
    </div>`);
}

async function addCat() {
  try {
    await api('/api/categories', { method: 'POST', body: { name: document.getElementById('cat-name').value.trim() } });
    toast('تمت الإضافة'); window.__cats = await api('/api/categories'); catForm();
  } catch (ex) { toast(ex.message, 'err'); }
}

function importForm() {
  openModal('استيراد أصناف من CSV', `
    <p class="muted">يجب أن يحتوي الصف الأول على العناوين، مثل:<br>
    <code>sku,name,category,unit,cost_price,sale_price,reorder_level</code></p>
    <textarea id="imp-csv" rows="8" style="width:100%;margin-top:10px" placeholder="الصق محتوى ملف CSV هنا"></textarea>
    <button class="btn primary" style="margin-top:12px" onclick="doImport()">استيراد</button>`);
}

async function doImport() {
  try {
    const r = await api('/api/import/products', { method: 'POST', body: { csv: document.getElementById('imp-csv').value } });
    closeModal(); toast('أضيف ' + r.added + ' وحدّث ' + r.updated + ' صنفًا' + (r.errors.length ? ' — أخطاء: ' + r.errors.length : ''));
    vProducts();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- المخزون ------------------------- */

async function vInventory() {
  const rows = await api('/api/inventory');
  const canAdj = PERMS.indexOf('inventory.adjust') !== -1;
  view.innerHTML = `
    <div class="toolbar">
      <input id="i-q" placeholder="بحث..." oninput="filterTable('i-tbl','i-q')">
      <a class="btn ghost" href="/api/inventory?format=csv">تصدير CSV</a>
    </div>
    <table class="grid" id="i-tbl"><thead><tr>
      <th>الرمز</th><th>الصنف</th><th>الفئة</th><th>المخزون</th><th>حد الطلب</th><th>التكلفة الوسيطة</th><th>قيمة المخزون</th><th>الحالة</th><th></th>
    </tr></thead><tbody>
    ${rows.map((p) => `<tr>
      <td>${esc(p.sku)}</td><td>${esc(p.name)}</td><td>${esc(p.category_name || '—')}</td>
      <td>${p.stock} ${esc(UNITS[p.unit] || '')}</td><td>${p.reorder_level}</td>
      <td>${fmt(p.avg_cost)}</td><td>${fmt(p.value)}</td>
      <td>${p.low ? '<span class="badge warn">يحتاج طلب</span>' : '<span class="badge ok">جيد</span>'}</td>
      <td>${canAdj ? '<button class="btn sm ghost" onclick="adjustForm(' + p.id + ', \'' + esc(p.name).replace(/'/g, '') + '\')">تسوية</button>' : ''}
      </tr>`).join('')}
    </tbody></table>`;
  window.__inv = rows;
}

function adjustForm(id, name) {
  openModal('تسوية مخزون: ' + name, `
    <p class="muted">أدخل التغير بالموجب (زيادة) أو بالسالب (نقص).</p>
    <div class="row" style="margin-top:10px">
      <div class="field"><label>الكمية ±</label><input id="adj-delta" type="number" step="0.01"></div>
      <div class="field"><label>سبب</label><input id="adj-note" placeholder="جرد / تالف / هدية..."></div>
    </div>
    <button class="btn primary" style="margin-top:14px" onclick="doAdjust(${id})">تنفيذ</button>`);
}

async function doAdjust(id) {
  try {
    await api('/api/inventory/adjust', { method: 'POST', body: {
      productId: id, delta: Number(document.getElementById('adj-delta').value),
      note: document.getElementById('adj-note').value } });
    closeModal(); toast('تمت التسوية'); vInventory();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- المبيعات ------------------------- */

async function vSales() {
  const rows = await api('/api/sales');
  view.innerHTML = `
    <div class="toolbar">
      <input id="s-q" placeholder="بحث..." oninput="filterTable('s-tbl','s-q')">
      <a class="btn ghost" href="/api/sales?format=csv">تصدير CSV</a>
    </div>
    <table class="grid" id="s-tbl"><thead><tr>
      <th>الرقم</th><th>التاريخ</th><th>العميل</th><th>الإجمالي</th><th>التكلفة</th><th>الربح</th><th>الدفع</th><th></th>
    </tr></thead><tbody>
    ${rows.map((s) => `<tr>
      <td>${esc(s.number)}</td><td>${dt(s.created_at)}</td><td>${esc(s.customer_name || 'عميل نقدي')}</td>
      <td>${fmt(s.total)}</td><td>${fmt(s.cost_total)}</td>
      <td style="color:var(--ok);font-weight:700">${fmt(s.total - s.cost_total)}</td>
      <td>${s.payment_type === 'cash' ? '<span class="badge ok">نقدي</span>' : '<span class="badge warn">آجل</span>'}</td>
      <td><button class="btn sm ghost" onclick="saleDetail(${s.id})">عرض</button></td>
    </tr>`).join('')}
    </tbody></table>`;
  window.__sales = rows;
}

async function saleDetail(id) {
  const r = await api('/api/sales/' + id);
  openModal('فاتورة ' + r.sale.number, `
    <p class="muted">${dt(r.sale.created_at)} — ${esc(r.sale.customer_name || 'عميل نقدي')} — البائع: ${esc(r.sale.username || '')}</p>
    <table class="grid" style="margin-top:10px"><thead><tr><th>الصنف</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>الصافي</th></tr></thead><tbody>
    ${r.items.map((i) => `<tr><td>${esc(i.product_name)}</td><td>${i.qty}</td><td>${fmt(i.unit_price)}</td>
      <td>${i.discount_pct}%</td><td>${fmt(i.net)}</td></tr>`).join('')}
    </tbody></table>
    <div class="cart-totals" style="margin-top:12px">
      <div><span>الصافي</span><b>${fmt(r.sale.net)}</b></div>
      <div><span>الضريبة</span><b>${fmt(r.sale.tax)}</b></div>
      <div class="grand"><span>الإجمالي</span><span>${fmt(r.sale.total)}</span></div>
    </div>
    ${r.returns.length ? '<p class="badge warn" style="margin-top:10px">توجد مرتجعات على هذه الفاتورة (' + r.returns.length + ')</p>' : ''}
    ${PERMS.indexOf('returns.create') !== -1 ? '<button class="btn primary" style="margin-top:14px" onclick="location.hash=\'#returns\';closeModal()">إنشاء مرتجع</button>' : ''}`);
}

/* ------------------------- المشتريات ------------------------- */

async function vPurchases() {
  const rows = await api('/api/purchases');
  const products = await api('/api/products');
  const suppliers = await api('/api/suppliers');
  window.__pProducts = products; window.__pSuppliers = suppliers;
  view.innerHTML = `
    <div class="toolbar">
      <button class="btn primary" onclick="purchaseForm()">فاتورة شراء جديدة</button>
      <a class="btn ghost" href="/api/purchases?format=csv">تصدير CSV</a>
    </div>
    <table class="grid"><thead><tr>
      <th>الرقم</th><th>التاريخ</th><th>المورد</th><th>الإجمالي</th><th>الدفع</th>
    </tr></thead><tbody>
    ${rows.map((p) => `<tr>
      <td>${esc(p.number)}</td><td>${dt(p.created_at)}</td><td>${esc(p.supplier_name || '—')}</td>
      <td>${fmt(p.total)}</td>
      <td>${p.payment_type === 'cash' ? '<span class="badge ok">نقدي</span>' : '<span class="badge warn">آجل</span>'}</td>
    </tr>`).join('')}
    </tbody></table>`;
}

let pLines = [];

function purchaseForm() {
  pLines = [];
  openModal('فاتورة شراء جديدة', `
    <div class="row">
      <div class="field"><label>المورد</label><select id="pu-supplier"><option value="">— بدون —</option>
        ${window.__pSuppliers.map((s) => '<option value="' + s.id + '">' + esc(s.name) + '</option>').join('')}</select></div>
      <div class="field"><label>نوع الدفع</label><select id="pu-pay"><option value="cash">نقدي</option><option value="credit">آجل</option></select></div>
    </div>
    <div class="row" style="margin-top:12px">
      <div class="field"><label>الصنف</label><select id="pu-product">
        ${window.__pProducts.map((p) => '<option value="' + p.id + '">' + esc(p.name) + '</option>').join('')}</select></div>
      <div class="field"><label>الكمية</label><input id="pu-qty" type="number" step="0.01" value="1"></div>
      <div class="field"><label>تكلفة الوحدة</label><input id="pu-cost" type="number" step="0.01"></div>
      <button class="btn ok" onclick="pAddLine()">إضافة</button>
    </div>
    <div id="pu-lines" style="margin-top:12px"></div>
    <button class="btn primary" style="margin-top:16px" onclick="savePurchase()">حفظ الفاتورة</button>`);
  renderPLines();
}

function pAddLine() {
  const sel = document.getElementById('pu-product');
  const p = window.__pProducts.find((x) => x.id === Number(sel.value));
  const qty = Number(document.getElementById('pu-qty').value);
  const cost = Number(document.getElementById('pu-cost').value);
  if (!p || !qty || qty <= 0 || !cost || cost < 0) return toast('أدخل كمية وتكلفة صحيحتين', 'err');
  pLines.push({ productId: p.id, name: p.name, qty: qty, unitCost: cost });
  document.getElementById('pu-cost').value = '';
  renderPLines();
}

function renderPLines() {
  document.getElementById('pu-lines').innerHTML = pLines.map((l, i) => `
    <div class="cart-line"><span>${esc(l.name)} — ${l.qty} × ${fmt(l.unitCost)}</span>
      <button class="btn sm danger" onclick="pLines.splice(${i},1);renderPLines()">حذف</button></div>`).join('')
    || '<p class="muted">لا بنود بعد.</p>';
}

async function savePurchase() {
  try {
    const r = await api('/api/purchases', { method: 'POST', body: {
      supplierId: document.getElementById('pu-supplier').value || null,
      paymentType: document.getElementById('pu-pay').value,
      items: pLines.map((l) => ({ productId: l.productId, qty: l.qty, unitCost: l.unitCost })) } });
    closeModal(); toast('تم حفظ فاتورة الشراء ' + r.number); vPurchases();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- المرتجعات ------------------------- */

async function vReturns() {
  const rows = await api('/api/sale-returns');
  view.innerHTML = `
    <div class="toolbar">
      <button class="btn primary" onclick="returnForm()">مرتجع مبيعات جديد</button>
      <a class="btn ghost" href="/api/sale-returns?format=csv">تصدير CSV</a>
    </div>
    <table class="grid"><thead><tr>
      <th>الرقم</th><th>التاريخ</th><th>الفاتورة الأصلية</th><th>العميل</th><th>القيمة</th><th>الرد</th>
    </tr></thead><tbody>
    ${rows.map((r) => `<tr>
      <td>${esc(r.number)}</td><td>${dt(r.created_at)}</td><td>${esc(r.sale_number)}</td>
      <td>${esc(r.customer_name || '—')}</td><td>${fmt(r.total)}</td>
      <td>${r.refund_type === 'cash' ? '<span class="badge ok">نقدي</span>' : '<span class="badge warn">على الحساب</span>'}</td>
    </tr>`).join('')}
    </tbody></table>`;
}

async function returnForm() {
  const sales = (await api('/api/sales')).slice(0, 50);
  openModal('مرتجع مبيعات', `
    <div class="field"><label>الفاتورة الأصلية</label>
      <select id="ret-sale">${sales.map((s) => '<option value="' + s.id + '">' + esc(s.number) + ' — ' + fmt(s.total) + '</option>').join('')}</select></div>
    <div class="row" style="margin-top:10px">
      <div class="field"><label>طريقة الرد</label><select id="ret-type"><option value="cash">نقدي من الصندوق</option><option value="credit">خصم من حساب العميل</option></select></div>
      <div class="field"><label>السبب</label><input id="ret-reason" placeholder="تالف / خاطئ..."></div>
    </div>
    <div id="ret-items" style="margin-top:12px"></div>
    <button class="btn primary" style="margin-top:14px" onclick="saveReturn()">حفظ المرتجع</button>`);
  document.getElementById('ret-sale').onchange = loadRetItems;
  loadRetItems();
}

async function loadRetItems() {
  const r = await api('/api/sales/' + document.getElementById('ret-sale').value);
  document.getElementById('ret-items').innerHTML = `
    <table class="grid"><thead><tr><th>الصنف</th><th>المتبقي</th><th>كمية الإرجاع</th></tr></thead><tbody>
    ${r.items.map((i) => `<tr>
      <td>${esc(i.product_name)}</td><td>${i.qty}</td>
      <td><input type="number" min="0" max="${i.qty}" step="0.01" data-si="${i.id}" class="ret-qty" style="width:80px" value="0"></td>
    </tr>`).join('')}
    </tbody></table>`;
  window.__retSale = r;
}

async function saveReturn() {
  try {
    const items = [];
    document.querySelectorAll('.ret-qty').forEach((inp) => {
      const q = Number(inp.value) || 0;
      if (q > 0) items.push({ saleItemId: Number(inp.getAttribute('data-si')), qty: q });
    });
    if (!items.length) return toast('حدد الكميات المرتجعة', 'err');
    const r = await api('/api/sale-returns', { method: 'POST', body: {
      saleId: Number(document.getElementById('ret-sale').value),
      refundType: document.getElementById('ret-type').value,
      reason: document.getElementById('ret-reason').value,
      items: items } });
    closeModal(); toast('تم حفظ المرتجع ' + r.number); vReturns();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- العملاء والموردون ------------------------- */

async function vCustomers() {
  const rows = await api('/api/customers');
  const canWrite = PERMS.indexOf('customers.write') !== -1;
  const canPay = PERMS.indexOf('cashbox.manage') !== -1;
  view.innerHTML = `
    <div class="toolbar">
      <input id="c-q" placeholder="بحث..." oninput="filterTable('c-tbl','c-q')">
      ${canWrite ? '<button class="btn primary" onclick="customerForm()">إضافة عميل</button>' : ''}
      <a class="btn ghost" href="/api/customers?format=csv">تصدير CSV</a>
    </div>
    <table class="grid" id="c-tbl"><thead><tr>
      <th>الاسم</th><th>الهاتف</th><th>حد الائتمان</th><th>الرصيد المستحق</th><th></th>
    </tr></thead><tbody>
    ${rows.map((c) => `<tr>
      <td>${esc(c.name)}</td><td>${esc(c.phone || '—')}</td><td>${fmt(c.credit_limit)}</td>
      <td style="${c.balance > 0 ? 'color:var(--err);font-weight:700' : ''}">${fmt(c.balance)}</td>
      <td>${canWrite ? '<button class="btn sm ghost" onclick="customerForm(' + c.id + ')">تعديل</button>' : ''}
          ${canPay && c.balance > 0 ? '<button class="btn sm ok" onclick="payForm(\'customer\',' + c.id + ',\'' + esc(c.name).replace(/'/g, '') + '\',' + c.balance + ')">تحصيل</button>' : ''}</td>
    </tr>`).join('')}
    </tbody></table>`;
  window.__customers = rows;
}

function customerForm(id) {
  const c = id ? window.__customers.find((x) => x.id === id) : null;
  openModal(c ? 'تعديل عميل' : 'إضافة عميل', `
    <div class="form-grid">
      <div class="field full"><label>الاسم</label><input id="c-name" value="${c ? esc(c.name) : ''}"></div>
      <div class="field"><label>الهاتف</label><input id="c-phone" value="${c ? esc(c.phone || '') : ''}"></div>
      <div class="field"><label>حد الائتمان (0 = نقدي فقط)</label><input id="c-limit" type="number" value="${c ? c.credit_limit : 0}"></div>
      <div class="field full"><label>العنوان</label><input id="c-addr" value="${c ? esc(c.address || '') : ''}"></div>
    </div>
    <button class="btn primary" style="margin-top:14px" onclick="saveCustomer(${id || 0})">حفظ</button>`);
}

async function saveCustomer(id) {
  try {
    const body = {
      name: document.getElementById('c-name').value.trim(),
      phone: document.getElementById('c-phone').value.trim(),
      address: document.getElementById('c-addr').value.trim(),
      credit_limit: Number(document.getElementById('c-limit').value) || 0 };
    if (id) await api('/api/customers/' + id, { method: 'PUT', body });
    else await api('/api/customers', { method: 'POST', body });
    closeModal(); toast('تم الحفظ'); vCustomers();
  } catch (ex) { toast(ex.message, 'err'); }
}

async function vSuppliers() {
  const rows = await api('/api/suppliers');
  const canPay = PERMS.indexOf('cashbox.manage') !== -1;
  view.innerHTML = `
    <div class="toolbar">
      <button class="btn primary" onclick="supplierForm()">إضافة مورد</button>
      <a class="btn ghost" href="/api/suppliers?format=csv">تصدير CSV</a>
    </div>
    <table class="grid"><thead><tr>
      <th>الاسم</th><th>الهاتف</th><th>الرصيد المستحق للمورد</th><th></th>
    </tr></thead><tbody>
    ${rows.map((s) => `<tr>
      <td>${esc(s.name)}</td><td>${esc(s.phone || '—')}</td>
      <td style="${s.balance > 0 ? 'color:var(--err);font-weight:700' : ''}">${fmt(s.balance)}</td>
      <td><button class="btn sm ghost" onclick="supplierForm(${s.id})">تعديل</button>
          ${canPay && s.balance > 0 ? '<button class="btn sm ok" onclick="payForm(\'supplier\',' + s.id + ',\'' + esc(s.name).replace(/'/g, '') + '\',' + s.balance + ')">سداد</button>' : ''}</td>
    </tr>`).join('')}
    </tbody></table>`;
  window.__suppliers = rows;
}

function supplierForm(id) {
  const s = id ? window.__suppliers.find((x) => x.id === id) : null;
  openModal(s ? 'تعديل مورد' : 'إضافة مورد', `
    <div class="form-grid">
      <div class="field full"><label>الاسم</label><input id="s-name" value="${s ? esc(s.name) : ''}"></div>
      <div class="field"><label>الهاتف</label><input id="s-phone" value="${s ? esc(s.phone || '') : ''}"></div>
      <div class="field"><label>العنوان</label><input id="s-addr" value="${s ? esc(s.address || '') : ''}"></div>
    </div>
    <button class="btn primary" style="margin-top:14px" onclick="saveSupplier(${id || 0})">حفظ</button>`);
}

async function saveSupplier(id) {
  try {
    const body = {
      name: document.getElementById('s-name').value.trim(),
      phone: document.getElementById('s-phone').value.trim(),
      address: document.getElementById('s-addr').value.trim() };
    if (id) await api('/api/suppliers/' + id, { method: 'PUT', body });
    else await api('/api/suppliers', { method: 'POST', body });
    closeModal(); toast('تم الحفظ'); vSuppliers();
  } catch (ex) { toast(ex.message, 'err'); }
}

function payForm(type, id, name, balance) {
  openModal((type === 'customer' ? 'تحصيل من: ' : 'سداد إلى: ') + name, `
    <p class="muted">الرصيد المستحق: <b>${fmt(balance)}</b></p>
    <div class="field" style="margin-top:10px"><label>المبلغ</label>
      <input id="pay-amt" type="number" step="0.01" max="${balance}" value="${balance}"></div>
    <div class="field" style="margin-top:10px"><label>ملاحظة</label><input id="pay-note"></div>
    <button class="btn primary" style="margin-top:14px" onclick="doPay('${type}', ${id})">تنفيذ</button>`);
}

async function doPay(type, id) {
  try {
    await api('/api/payments', { method: 'POST', body: {
      partyType: type, partyId: id,
      amount: Number(document.getElementById('pay-amt').value),
      note: document.getElementById('pay-note').value } });
    closeModal(); toast('تمت العملية'); route();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- الصندوق ------------------------- */

const TX_NAMES = { deposit: 'إيداع', withdraw: 'سحب', sale: 'تحصيل بيع', purchase: 'سداد شراء',
  'sale-return': 'رد مرتجع', 'purchase-return': 'تحصيل مرتجع شراء', expense: 'مصروف',
  'payment-in': 'تحصيل من عميل', 'payment-out': 'سداد لمورد' };
const TX_DIR = { deposit: 1, withdraw: -1, sale: 1, purchase: -1, 'sale-return': -1,
  'purchase-return': 1, expense: -1, 'payment-in': 1, 'payment-out': -1 };

async function vCashbox() {
  const d = await api('/api/cashbox');
  const canManage = PERMS.indexOf('cashbox.manage') !== -1;
  view.innerHTML = `
    <div class="cards">
      <div class="stat ok"><span class="muted">رصيد الصندوق الحالي</span><div class="v">${fmt(d.balance)}</div></div>
    </div>
    ${canManage ? `
    <div class="card">
      <b>حركة يدوية</b>
      <div class="row" style="margin-top:10px">
        <div class="field"><label>النوع</label><select id="cb-type">
          <option value="deposit">إيداع نقدي</option><option value="withdraw">سحب نقدي</option></select></div>
        <div class="field"><label>المبلغ</label><input id="cb-amt" type="number" step="0.01"></div>
        <div class="field"><label>ملاحظة</label><input id="cb-note"></div>
        <button class="btn primary" onclick="cbTx()">تنفيذ</button>
      </div>
    </div>
    <div class="card">
      <b>تسجيل مصروف</b>
      <div class="row" style="margin-top:10px">
        <div class="field"><label>البند</label><input id="ex-cat" placeholder="إيجار / كهرباء / نقل..."></div>
        <div class="field"><label>المبلغ</label><input id="ex-amt" type="number" step="0.01"></div>
        <button class="btn danger" onclick="addExpense()">تسجيل</button>
      </div>
    </div>` : ''}
    <table class="grid"><thead><tr>
      <th>التاريخ</th><th>النوع</th><th>المبلغ</th><th>البيان</th>
    </tr></thead><tbody>
    ${d.txs.map((t) => `<tr>
      <td>${dt(t.created_at)}</td><td>${esc(TX_NAMES[t.type] || t.type)}</td>
      <td style="font-weight:700;color:${TX_DIR[t.type] === -1 ? 'var(--err)' : 'var(--ok)'}">${TX_DIR[t.type] === -1 ? '−' : '+'} ${fmt(t.amount)}</td>
      <td>${esc(t.note || '')}</td>
    </tr>`).join('')}
    </tbody></table>`;
}

async function cbTx() {
  try {
    await api('/api/cashbox/tx', { method: 'POST', body: {
      type: document.getElementById('cb-type').value,
      amount: Number(document.getElementById('cb-amt').value),
      note: document.getElementById('cb-note').value } });
    toast('تمت الحركة'); vCashbox();
  } catch (ex) { toast(ex.message, 'err'); }
}

async function addExpense() {
  try {
    await api('/api/expenses', { method: 'POST', body: {
      category: document.getElementById('ex-cat').value,
      amount: Number(document.getElementById('ex-amt').value) } });
    toast('تم تسجيل المصروف'); vCashbox();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- التقارير ------------------------- */

async function vReports() {
  const [daily, products] = await Promise.all([api('/api/reports/daily'), api('/api/reports/products')]);
  view.innerHTML = `
    <div class="toolbar">
      <a class="btn ghost" href="/api/reports/daily?format=csv">تصدير المبيعات اليومية CSV</a>
      <a class="btn ghost" href="/api/reports/products?format=csv">تصدير تقرير الأصناف CSV</a>
      <a class="btn ghost" href="/api/reports/low-stock?format=csv">تصدير الأصناف الناقصة CSV</a>
    </div>
    <div class="card"><b>المبيعات اليومية (آخر 60 يومًا)</b>
      <table class="grid" style="margin-top:10px"><thead><tr>
        <th>اليوم</th><th>عدد الفواتير</th><th>الإجمالي</th><th>الربح</th>
      </tr></thead><tbody>
      ${daily.map((r) => `<tr><td>${r.day}</td><td>${r.invoices}</td><td>${fmt(r.total)}</td>
        <td style="color:var(--ok)">${fmt(r.profit)}</td></tr>`).join('')}
      </tbody></table></div>
    <div class="card"><b>أداء الأصناف (الأعلى إيرادًا)</b>
      <table class="grid" style="margin-top:10px"><thead><tr>
        <th>الصنف</th><th>الكمية المبيعة</th><th>الإيراد</th><th>التكلفة</th><th>الربح</th>
      </tr></thead><tbody>
      ${products.map((r) => `<tr><td>${esc(r.name)}</td><td>${r.qty_sold}</td><td>${fmt(r.revenue)}</td>
        <td>${fmt(r.cost)}</td><td style="color:var(--ok)">${fmt(r.profit)}</td></tr>`).join('')}
      </tbody></table></div>`;
}

/* ------------------------- المستخدمون ------------------------- */

async function vUsers() {
  const rows = await api('/api/users');
  view.innerHTML = `
    <div class="toolbar"><button class="btn primary" onclick="userForm()">إضافة مستخدم</button></div>
    <table class="grid"><thead><tr>
      <th>اسم المستخدم</th><th>الاسم</th><th>الدور</th><th>الحالة</th><th></th>
    </tr></thead><tbody>
    ${rows.map((u) => `<tr>
      <td>${esc(u.username)}</td><td>${esc(u.full_name)}</td>
      <td>${ROLE_NAMES[u.role] || u.role}</td>
      <td>${u.is_active ? '<span class="badge ok">نشط</span>' : '<span class="badge err">معطل</span>'}</td>
      <td><button class="btn sm ghost" onclick="userForm(${u.id})">تعديل</button></td>
    </tr>`).join('')}
    </tbody></table>`;
  window.__users = rows;
}

function userForm(id) {
  const u = id ? window.__users.find((x) => x.id === id) : null;
  openModal(u ? 'تعديل مستخدم' : 'إضافة مستخدم', `
    <div class="form-grid">
      <div class="field"><label>اسم المستخدم</label><input id="u-username" value="${u ? esc(u.username) : ''}" ${u ? 'disabled' : ''}></div>
      <div class="field"><label>الدور</label><select id="u-role">
        ${['admin', 'manager', 'cashier', 'accountant'].map((r) => '<option value="' + r + '"' + (u && u.role === r ? ' selected' : '') + '>' + ROLE_NAMES[r] + '</option>').join('')}
      </select></div>
      <div class="field full"><label>الاسم الكامل</label><input id="u-full" value="${u ? esc(u.full_name) : ''}"></div>
      <div class="field"><label>كلمة مرور جديدة (اختياري)</label><input id="u-pass" type="password"></div>
      <div class="field"><label>الحالة</label><select id="u-active">
        <option value="1">نشط</option><option value="0" ${u && !u.is_active ? 'selected' : ''}>معطل</option></select></div>
    </div>
    <button class="btn primary" style="margin-top:14px" onclick="saveUser(${id || 0})">حفظ</button>`);
}

async function saveUser(id) {
  try {
    const body = {
      username: document.getElementById('u-username').value.trim(),
      full_name: document.getElementById('u-full').value.trim(),
      role: document.getElementById('u-role').value,
      is_active: document.getElementById('u-active').value === '1',
      password: document.getElementById('u-pass').value || undefined };
    if (id) await api('/api/users/' + id, { method: 'PUT', body });
    else await api('/api/users', { method: 'POST', body });
    closeModal(); toast('تم الحفظ'); vUsers();
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- النسخ الاحتياطي ------------------------- */

async function vBackup() {
  const rows = await api('/api/backups');
  view.innerHTML = `
    <div class="toolbar">
      <button class="btn primary" onclick="makeBackup()">إنشاء نسخة احتياطية الآن</button>
    </div>
    <p class="muted">الاسترجاع يستبدل قاعدة البيانات الحالية بالنسخة المحددة بعد فحص سلامتها، ويُنصح بإعادة تشغيل الخادم بعدها.</p>
    <table class="grid" style="margin-top:12px"><thead><tr>
      <th>الملف</th><th>الحجم</th><th>بواسطة</th><th>التاريخ</th><th></th>
    </tr></thead><tbody>
    ${rows.map((b) => `<tr>
      <td>${esc(b.filename)}</td><td>${(b.size_bytes / 1024).toFixed(1)} ك.ب</td>
      <td>${esc(b.created_by)}</td><td>${dt(b.created_at)}</td>
      <td><button class="btn sm danger" onclick="restoreBackup('${esc(b.filename)}')">استرجاع</button></td>
    </tr>`).join('') || '<tr><td colspan="5" class="muted">لا نسخ بعد.</td></tr>'}
    </tbody></table>`;
}

async function makeBackup() {
  try {
    const r = await api('/api/backup', { method: 'POST' });
    toast('تم إنشاء ' + r.file); vBackup();
  } catch (ex) { toast(ex.message, 'err'); }
}

async function restoreBackup(file) {
  if (!confirm('سيتم استبدال البيانات الحالية بالنسخة ' + file + ' — هل أنت متأكد؟')) return;
  try {
    await api('/api/restore', { method: 'POST', body: { file: file } });
    toast('تم الاسترجاع — أعد تشغيل الخادم');
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- الإعدادات ------------------------- */

async function vSettings() {
  const s = await api('/api/settings');
  view.innerHTML = `
    <div class="card" style="max-width:640px">
      <div class="form-grid">
        <div class="field full"><label>اسم المتجر</label><input id="st-name" value="${esc(s.shop_name)}"></div>
        <div class="field"><label>الهاتف</label><input id="st-phone" value="${esc(s.phone)}"></div>
        <div class="field"><label>العنوان</label><input id="st-address" value="${esc(s.address)}"></div>
        <div class="field"><label>أقصى خصم مسموح %</label><input id="st-disc" type="number" value="${esc(s.max_discount_pct)}"></div>
        <div class="field"><label>السماح بالبيع بأقل من التكلفة (1 = نعم / 0 = لا)</label><input id="st-below" value="${esc(s.allow_below_cost)}"></div>
        <div class="field full"><label>تذييل الإيصال</label><input id="st-footer" value="${esc(s.receipt_footer)}"></div>
      </div>
      <button class="btn primary" style="margin-top:16px" onclick="saveSettings()">حفظ الإعدادات</button>
    </div>`;
}

async function saveSettings() {
  try {
    await api('/api/settings', { method: 'PUT', body: {
      shop_name: document.getElementById('st-name').value,
      phone: document.getElementById('st-phone').value,
      address: document.getElementById('st-address').value,
      max_discount_pct: document.getElementById('st-disc').value,
      allow_below_cost: document.getElementById('st-below').value,
      receipt_footer: document.getElementById('st-footer').value } });
    SETTINGS = await api('/api/settings');
    document.getElementById('shop-name').textContent = SETTINGS.shop_name;
    toast('تم حفظ الإعدادات');
  } catch (ex) { toast(ex.message, 'err'); }
}

/* ------------------------- سجل التدقيق ------------------------- */

async function vAudit() {
  const rows = await api('/api/audit');
  view.innerHTML = `
    <div class="toolbar">
      <input id="a-q" placeholder="بحث..." oninput="filterTable('a-tbl','a-q')">
      <a class="btn ghost" href="/api/audit?format=csv">تصدير CSV</a>
    </div>
    <table class="grid" id="a-tbl"><thead><tr>
      <th>التاريخ</th><th>المستخدم</th><th>الإجراء</th><th>الكيان</th><th>التفاصيل</th>
    </tr></thead><tbody>
    ${rows.map((a) => `<tr>
      <td>${dt(a.created_at)}</td><td>${esc(a.username || '')}</td><td>${esc(a.action)}</td>
      <td>${esc((a.entity || '') + (a.entity_id ? ' #' + a.entity_id : ''))}</td>
      <td class="muted">${esc(String(a.details || '').slice(0, 80))}</td>
    </tr>`).join('')}
    </tbody></table>`;
}

/* ------------------------- الإقلاع ------------------------- */

const view = document.getElementById('view');
const VIEWS = { dashboard: vDashboard, pos: vPOS, products: vProducts, inventory: vInventory,
  sales: vSales, purchases: vPurchases, returns: vReturns, customers: vCustomers,
  suppliers: vSuppliers, cashbox: vCashbox, reports: vReports, users: vUsers,
  backup: vBackup, settings: vSettings, audit: vAudit };

document.getElementById('login-form').addEventListener('submit', doLogin);
document.getElementById('logout-btn').addEventListener('click', async () => {
  try { await api('/api/logout', { method: 'POST' }); } catch (e) {}
  ME = null; PERMS = []; cart = [];
  showLogin();
});
document.getElementById('modal-close').addEventListener('click', closeModal);
document.getElementById('modal').addEventListener('click', (e) => {
  if (e.target.id === 'modal') closeModal();
});
window.addEventListener('hashchange', route);
setInterval(() => {
  document.getElementById('clock').textContent =
    new Date().toLocaleString('ar-EG', { dateStyle: 'medium', timeStyle: 'short' });
}, 1000);

(async function boot() {
  try {
    ME = await api('/api/me');
    await afterLogin();
  } catch (e) { showLogin(); }
})();
