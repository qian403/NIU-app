// Read-only production-JS regression. No browser, account, token or network.
// Usage: node scripts/check-grade-history.js [GradeHistoryView.swift]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sourcePath = process.argv[2] || path.join(__dirname, '../Features/GradeHistory/Views/GradeHistoryView.swift');
const source = fs.readFileSync(sourcePath, 'utf8');
const section = source.slice(source.indexOf('private func pollForHistoryCourses'));
const match = section.match(/let js = """\n([\s\S]*?)\n\s*"""/);
assert.ok(match, 'Expected production history polling JavaScript');
const script = match[1].replace(/\\\\/g, '\\');

function exercise(exclusive) {
    let expanded = [false, false, false];
    let tableReads = 0;
    let clickCount = 0;
    // Hidden panels need textContent; the parser must not depend on rendered text.
    const cells = values => ({ querySelectorAll: selector => selector === 'td'
        ? values.map(value => ({ innerText: '', textContent: value })) : [] });
    const tables = [0, 1, 2].map(index => ({
        querySelectorAll: selector => selector === 'tr' ? [cells([]), cells([
            '1111', '必修', '3', `Fixture course ${index + 1}`, '80'
        ])] : []
    }));
    const controls = expanded.map((_, index) => ({
        getAttribute: name => name === 'aria-expanded' ? String(expanded[index]) : null,
        click() {
            clickCount++;
            if (exclusive) expanded.fill(false);
            expanded[index] = true;
        }
    }));
    const document = {
        body: { innerText: '歷年學業成績及排名', textContent: '歷年學業成績及排名' },
        querySelector: selector => selector === '#accordion修課紀錄' ? {} : null,
        querySelectorAll(selector) {
            if (selector === '#accordion修課紀錄 [aria-expanded="false"]') {
                return controls.filter((_, index) => !expanded[index]);
            }
            if (selector === 'div.row table.table tr') {
                return [cells([]), cells(['1111', '', '1/3', '80'])];
            }
            if (selector === '#accordion修課紀錄 table.table.table-striped'
                || selector === 'table.table.table-striped') {
                tableReads++;
                return tables;
            }
            throw new Error(`Fixture lacks selector: ${selector}`);
        }
    };
    const window = { document, frames: [] };
    let result = '';
    let attempts = 0;
    while (attempts < 5 && !result) {
        attempts++;
        result = vm.runInNewContext(script, { window, document });
    }
    const rows = result ? JSON.parse(result) : [];
    return { exclusiveAccordion: exclusive, attempts, tableReads, clickCount,
        collapsedRemaining: expanded.filter(value => !value).length, parsedRows: rows.length };
}

const results = [exercise(false), exercise(true)];
for (const result of results) console.log(JSON.stringify(result));
for (const result of results) {
    assert.equal(result.clickCount, 0, 'Parsing must not toggle the school accordion');
    assert.equal(result.parsedRows, 3,
        `History must parse fixture rows even with exclusiveAccordion=${result.exclusiveAccordion}`);
}
console.log('PASS: history parsing works for independent and mutually exclusive accordion panels');
