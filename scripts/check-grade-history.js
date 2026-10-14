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
    const cells = (values, header = false) => ({ querySelectorAll: selector => {
        const wanted = selector === 'th,td' || selector === (header ? 'th' : 'td');
        return wanted ? values.map(value => ({ innerText: '', textContent: value })) : [];
    } });
    const table = (rows, inAccordion) => ({
        closest: selector => selector === '#accordion修課紀錄' && inAccordion ? {} : null,
        querySelectorAll: selector => selector === 'tr' ? rows : []
    });
    // Mirrors the real page: the summary and every course table sit in div.row,
    // and course rows start with the same 學年期 value as summary rows.
    const summary = table([
        cells(['學年期', '系排名(名次/人數)', '班排名(名次/人數)', '學業平均成績'], true),
        cells(['1111', '12 / 90', '46 / 55', '70.36'])
    ], false);
    const tables = [0, 1, 2].map(index => table([
        cells(['學年期', '選別', '學分數', '課程名稱', '修課成績'], true),
        cells(['1111', '必修', '3', `Fixture course ${index + 1}`, '80'])
    ], true));
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
            if (selector === 'table.table') return [summary, ...tables];
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
        collapsedRemaining: expanded.filter(value => !value).length, parsedRows: rows.length,
        ranks: [...new Set(rows.map(row => `${row.classRank}|${row.departmentRank}|${row.averageText}`))] };
}

const results = [exercise(false), exercise(true)];
for (const result of results) console.log(JSON.stringify(result));
for (const result of results) {
    assert.equal(result.clickCount, 0, 'Parsing must not toggle the school accordion');
    assert.equal(result.parsedRows, 3,
        `History must parse fixture rows even with exclusiveAccordion=${result.exclusiveAccordion}`);
    // Course rows (credits 3, course name) must never overwrite the summary.
    assert.deepEqual(result.ranks, ['46 / 55|12 / 90|70.36'],
        'Class rank, department rank and average must come from the summary table by header');
}
console.log('PASS: history parsing works for independent and mutually exclusive accordion panels');
console.log('PASS: class/department rank and average are read from the summary table, not course rows');

// Academic menu: slow frames wait, branches are not re-clicked on every poll, leaves match by label or code.
{
    const menuSection = source.slice(source.indexOf('private func openAcadeMenuTarget'));
    const menuTemplate = menuSection.match(/let js = """\n([\s\S]*?)\n\s*"""/)[1].replace(/\\\\/g, '\\');
    const menuScript = (label, code) => menuTemplate
        .replace(String.raw`\(targetLabel)`, label).replace(String.raw`\(targetCode)`, code);
    const link = (text, href = '') => ({ innerText: text, clicks: 0,
        getAttribute: name => name === 'href' ? href : null, click() { this.clicks++; } });
    function run(script, top, now) {
        return vm.runInNewContext(script, { window: top, Date: { now: () => now } });
    }
    const historyScript = menuScript('學生歷年學期成績及排名查詢', '');
    assert.equal(run(historyScript, { frames: {} }, 0), 'missing-menu-frame');
    const menuDoc = { readyState: 'loading', links: [] , querySelectorAll() { return this.links; } };
    const top = { frames: { menuFrame: { document: menuDoc } } };
    assert.equal(run(historyScript, top, 0), 'loading-menu');
    menuDoc.readyState = 'complete';
    const branch = link('成績查詢作業');
    menuDoc.links = [link('成績及計分冊'), branch];
    assert.equal(run(historyScript, top, 1000), 'clicked-branch');
    assert.equal(run(historyScript, top, 1350), 'waiting-branch');
    assert.equal(run(historyScript, top, 3000), 'waiting-branch');
    assert.equal(branch.clicks, 1, 'A loading branch must not be toggled on every poll');
    assert.equal(run(historyScript, top, 5100), 'clicked-branch');
    const leaf = link('學生歷年學期成績\n及排名查詢');
    menuDoc.links.push(leaf);
    assert.equal(run(historyScript, top, 5400), 'clicked-leaf');
    assert.equal(leaf.clicks, 1);
    const byCode = link('期中成績', '/NIU/Application/GRD/GRD51/GRD5131_.aspx?progcd=GRD5131');
    const codeTop = { frames: { menuFrame: { document: { readyState: 'complete',
        querySelectorAll: () => [byCode] } } } };
    assert.equal(run(menuScript('學生查詢期中成績', 'GRD5131'), codeTop, 0), 'clicked-leaf');
    const emptyTop = { frames: { menuFrame: { document: { readyState: 'complete', querySelectorAll: () => [] } } } };
    assert.equal(run(historyScript, emptyTop, 0), 'missing-target');
    console.log('PASS: academic menu waits for slow frames, throttles branch clicks, matches wrapped labels and program codes');
}
