// Offline regression of the production registration parser; synthetic data only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Features/EnrollmentCertificate/Models/EnrollmentCertificateModels.swift'), 'utf8');
const script = source.match(/static let snapshot = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const menuScript = source.match(/static let openRegistrationMenu = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const scopeScript = source.match(/static let isRegistrationFrame = #"""\n([\s\S]*?)\n\s*"""#/)[1];
let clicked = [];
function link(label, href = '') {
    return {innerText: label, getAttribute: name => name === 'target' ? 'mainFrame' : href, click: () => clicked.push(label)};
}
const initialTarget = {name: 'mainFrame', document: {}};
const menuWindow = {frames: {menuFrame: {document: {querySelectorAll: () => menuLinks}}, mainFrame: initialTarget}};
let menuLinks = [link('學籍及畢審')];
assert.equal(vm.runInNewContext(menuScript, {window: menuWindow}), 'opening-menu');
menuLinks.push(link('註冊作業'));
assert.equal(vm.runInNewContext(menuScript, {window: menuWindow}), 'opening-menu');
menuLinks.push(link('查詢註冊', '/NIU/Application/ENR/ENR50/ENR5020_.aspx?progcd=ENR5020'));
assert.equal(vm.runInNewContext(menuScript, {window: menuWindow}), 'opened-registration');
assert.deepEqual(clicked, ['學籍及畢審', '註冊作業', '查詢註冊']);
assert.equal(menuWindow.__niuEnrollmentTarget, 'mainFrame');
assert.equal(menuWindow.__niuEnrollmentTargetWindow, initialTarget);
assert.equal(menuWindow.__niuEnrollmentPreviousDocument, initialTarget.document);
assert.equal(vm.runInNewContext(menuScript, {window: {frames: {}}}), 'waiting-menu');
const headers = ['註冊學年期', '學號', '姓名', '系所', '年級', '班別', '在學狀態', '註冊狀態', '註冊日期', '備註'];
const values = ['1151', 'T0000001', '測試學生', '測試學系', '3', '', '在學', '已註冊(繳費)', '115/08/31', ''];
function page({names = headers, data = [values], disabled = false, table = true, text = ''} = {}) {
    const rows = data.map(values => ({cells: values.map(innerText => ({innerText})), querySelector: () => null, innerText: values.join(' ')}));
    return {location: {pathname: '/NIU/Application/ENR/ENR50/ENR5020_01.aspx'}, frames: [], document: {
        body: {innerText: text},
        getElementById(id) {
            if (id === 'GoToPrint') return {disabled};
            if (id === 'DataGrid' && table) return {rows, querySelectorAll: () => names.map(innerText => ({innerText: innerText + ' ↓'}))};
            return null;
        }
    }};
}
const run = window => vm.runInNewContext(script, {window});
// Same-URL reloads must wait for a new Document, including an entire old outer tree.
const oldInner = page();
const oldOuter = {name: 'mainFrame', location: {pathname: '/NIU/Application/ENR/ENR50/ENR5020_.aspx'}, frames: [oldInner], document: {}};
const pendingRoot = {location: {pathname: '/NIU/MainFrame.aspx'}, frames: [oldOuter], __niuEnrollmentTargetWindow: oldOuter, __niuEnrollmentPreviousDocument: oldOuter.document};
assert.equal(run(pendingRoot), null, 'Do not parse an old child while the outer frame is navigating');
oldOuter.document = {};
assert.equal(JSON.parse(run(pendingRoot)).records[0].studentID, 'T0000001');
const oldResult = page();
const pendingResult = {...pendingRoot, frames: [oldResult], __niuEnrollmentTargetWindow: oldResult, __niuEnrollmentPreviousDocument: oldResult.document};
assert.equal(run(pendingResult), null);
oldResult.document = page().document;
assert.equal(JSON.parse(run(pendingResult)).records.length, 1, 'Same URL with a new document is accepted');
const oldLogin = {name: 'mainFrame', location: {pathname: '/NIU/Default.aspx'}, document: {}, frames: []};
const pendingLogin = {...pendingRoot, frames: [oldLogin], __niuEnrollmentTargetWindow: oldLogin, __niuEnrollmentPreviousDocument: oldLogin.document};
assert.equal(run(pendingLogin), null, 'A pre-existing login page is not the new query response');
oldLogin.document = {};
assert.equal(run(pendingLogin), 'session-expired');

const rootFrame = {};
rootFrame.top = rootFrame;
const targetFrame = {top: rootFrame, parent: rootFrame, location: {pathname: '/NIU/Blank.aspx'}};
rootFrame.__niuEnrollmentTargetWindow = targetFrame;
const nestedFrame = {top: rootFrame, parent: targetFrame, location: {pathname: '/NIU/Blank.aspx'}};
const unrelatedFrame = {top: rootFrame, parent: rootFrame, location: {pathname: '/NIU/Default.aspx'}};
assert.equal(vm.runInNewContext(scopeScript, {window: targetFrame}), true);
assert.equal(vm.runInNewContext(scopeScript, {window: nestedFrame}), true);
assert.equal(vm.runInNewContext(scopeScript, {window: unrelatedFrame}), false);
assert.equal(vm.runInNewContext(scopeScript, {window: rootFrame}), false);
let parsed = JSON.parse(run(page()));
assert.equal(parsed.records[0].studentID, 'T0000001');
assert.equal(parsed.records[0].registrationStatus, '已註冊(繳費)');
assert.equal(parsed.records[0].registrationDate, '115/08/31');
assert.equal(parsed.canPrint, true);
parsed = JSON.parse(run(page({names: [...headers].reverse(), data: [[...values].reverse()]})));
assert.equal(parsed.records[0].studentStatus, '在學');
assert.equal(parsed.records[0].name, '測試學生');
assert.equal(JSON.parse(run(page({disabled: true}))).canPrint, false);
assert.deepEqual(JSON.parse(run(page({data: []}))), {records: [], canPrint: false});
assert.deepEqual(JSON.parse(run(page({table: false, text: '查無資料'}))), {records: [], canPrint: false});
assert.equal(run(page({table: false, text: '正在載入'})), null);
assert.equal(run(page({names: headers.slice(1)})), 'invalid');
assert.equal(run(page({data: [values.slice(1)]})), 'invalid');
const noOwner = [...values]; noOwner[1] = '';
assert.equal(run(page({data: [noOwner]})), 'invalid');
const crossOrigin = {get location() {throw new Error('cross-origin');}};
const loginFrame = {location: {pathname: '/NIU/TimeoutPage.aspx'}, frames: [], document: {}};
assert.equal(run({location: {pathname: '/NIU/MainFrame.aspx'}, frames: [loginFrame, crossOrigin]}), null);
parsed = JSON.parse(run({location: {pathname: '/NIU/MainFrame.aspx'}, frames: [loginFrame, crossOrigin, page()]}));
assert.equal(parsed.records.length, 1);
assert.equal(run({location: {pathname: '/NIU/MainFrame.aspx'}, __niuEnrollmentTarget: 'mainFrame', frames: [loginFrame, {...loginFrame, name: 'mainFrame'}]}), 'session-expired');
assert.equal(run({location: {pathname: '/NIU/MainFrame.aspx'}, frames: [loginFrame, {...loginFrame, frameElement: {getAttribute: () => '/NIU/Application/ENR/ENR50/ENR5020_.aspx?progcd=ENR5020'}}]}), 'session-expired');
const unpaid = [...values]; unpaid[7] = '未註冊'; unpaid[8] = '';
parsed = JSON.parse(run(page({data: [unpaid]})));
assert.equal(parsed.records[0].registrationStatus, '未註冊');
assert.equal(parsed.records[0].registrationDate, '');
console.log('PASS: registration fields, reordered headers, empty/malformed data, frames, disabled print, source status');
