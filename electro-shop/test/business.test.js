'use strict';
/* =====================================================================
 * test/business.test.js — مشغل اختبارات محرك قواعد العمل
 * التشغيل: npm test  (أو: node test/business.test.js)
 * ===================================================================== */

const E = require('../engine.js');
const { buildScenarios } = require('./scenarios.js');

const scenarios = buildScenarios(E);
let pass = 0, fail = 0;
const failures = [];

console.log('');
console.log('  اختبارات محرك قواعد العمل — ' + scenarios.length + ' سيناريو');
console.log('  ' + '='.repeat(52));

for (const sc of scenarios) {
  try {
    sc.run();
    pass++;
    console.log('  [نجاح] ' + sc.id + ' — ' + sc.name);
  } catch (e) {
    fail++;
    failures.push({ id: sc.id, name: sc.name, error: e.message });
    console.log('  [فشل] ' + sc.id + ' — ' + sc.name);
    console.log('         ' + e.message);
  }
}

console.log('  ' + '='.repeat(52));
console.log('  النتيجة: ' + pass + '/' + scenarios.length + ' نجاح' +
            (fail > 0 ? ' — ' + fail + ' فشل' : ''));
console.log('');

if (fail > 0) process.exit(1);
