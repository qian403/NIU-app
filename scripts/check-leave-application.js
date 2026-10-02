#!/usr/bin/env node
// Offline checks for the production school DOM bridge. No accounts or requests.
const fs = require('fs');
const vm = require('vm');
const {URLSearchParams} = require('url');
const assert = require('assert/strict');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../Features/LeaveApplication/LeaveApplicationScript.swift'), 'utf8');
const blocks = Object.fromEntries([...source.matchAll(/static let (\w+) = (?:helpers \+ )?#"""\n([\s\S]*?)\n    """#/g)].map(m => [m[1], m[2]]));
const option = {value:'002', text:'病假'};
let sends = 0, binds = 0;
const nodes = {
  M_STNO: {textContent:'T0000001'}, M_HOLIDAY_CODE: {options:[{value:'',text:''},option], value:''},
  M_HOLIDAY_DATE_S: {value:''}, M_HOLIDAY_DATE_E: {value:''}, M_APP_ORIGIN: {value:''},
  CLASS_INFO: {value:'1151005|2|COURSE_A|1,1151005|3|COURSE_A|1'},
  CheckBox1: {checked:false}, SEND_BTN1: {value:'送出',click(){sends++;}}
};
const doc = {querySelector(s){return s.startsWith('#') ? nodes[s.slice(1)] : null;},
  querySelectorAll(){return [];}, getElementById(id){return nodes[id];}};
const form = {location:{pathname:'/NIU/Application/SEC/SEC20/SEC2010_01.aspx'},document:doc,frames:[]};
const top = {location:{pathname:'/NIU/MainFrame.aspx'},frames:[form]};
const args = {account:'t0000001',acknowledged:true,reason:'測試事由',selected:nodes.CLASS_INFO.value.split(','),leaveType:'002',supplementLater:true,startDate:'115/10/05',endDate:'115/10/05',expectedButton:'送出',expectedFormNo:''};
function run(name, overrides={}, root=top) {
  return vm.runInNewContext(`(function(){${blocks.helpers}\n${blocks[name]}})()`,{window:root,URLSearchParams,...args,...overrides});
}
assert.equal(JSON.parse(run('snapshot')).options[0].id,'002');
assert.throws(()=>run('submit',{acknowledged:false}),/NOT_CONFIRMED/);
assert.throws(()=>run('submit',{reason:'  '}),/NOT_CONFIRMED/);
assert.throws(()=>run('submit',{selected:[]}),/NOT_CONFIRMED/);
assert.throws(()=>run('submit',{account:'T0000002'}),/ACCOUNT_CHANGED/);
assert.throws(()=>run('submit',{selected:['1151005|8|OTHER|1']}),/PERIODS_CHANGED/);
assert.throws(()=>run('submit',{leaveType:'unknown'}),/FORM_CHANGED/);
const submitButton=nodes.SEND_BTN1; delete nodes.SEND_BTN1;
assert.throws(()=>run('submit'),/FORM_CHANGED/); nodes.SEND_BTN1=submitButton;
assert.equal(sends,0);
assert.equal(run('submit'),'attempted'); assert.equal(sends,1);
assert.equal(nodes.M_HOLIDAY_CODE.value,'002'); assert.equal(nodes.M_APP_ORIGIN.value,'測試事由');
assert.equal(nodes.CheckBox1.checked,true);
assert.throws(()=>run('submit'),/ALREADY_SUBMITTED/); assert.equal(sends,1);
const input = {value:'1151005|2|COURSE_A|1',disabled:false,checked:false,closest(){return {innerText:'測試教師\n測試課程\n教101',parentElement:{cells:[{innerText:'第二節'}]}};}};
const picker={location:{pathname:'/NIU/Application/SEC/SEC20/SEC2010_03.aspx'},frames:[],
  document:{getElementById(id){return id==='table2'?{}:{click(){binds++;}};},querySelectorAll(){return [input];}}};
top.frames.push(picker);
const periods=JSON.parse(run('periods')).periods;
assert.equal(periods[0].date,'115/10/05'); assert.equal(periods[0].course,'測試課程'); assert.equal(periods[0].period,'第二節');
assert.throws(()=>run('bindPeriods',{selected:['unknown']}),/FORM_CHANGED/);
input.disabled=true; assert.throws(()=>run('bindPeriods',{selected:[input.value]}),/FORM_CHANGED/);
input.disabled=false; assert.equal(run('bindPeriods',{selected:[input.value]}),'binding');
assert.equal(input.checked,true); assert.equal(binds,1);
top.__niuLeavePreviousPickerDocument=picker.document;
assert.equal(JSON.parse(run('periods')).kind,'waiting');
top.__niuLeavePreviousPickerDocument=null;
top.__niuLeavePeriodRange=['115/10/05','115/10/05'];
picker.location.search='?SDATE=115/10/06&EDATE=115/10/06';
assert.equal(JSON.parse(run('periods')).kind,'waiting');
picker.location.search='?SDATE=115/10/05&EDATE=115/10/05';
assert.equal(JSON.parse(run('periods')).periods.length,1);
input.disabled=true; assert.equal(JSON.parse(run('periods')).periods.length,0); input.disabled=false;
const inaccessible={get location(){throw Error('cross-origin');}};
top.frames.unshift(inaccessible);
assert.equal(JSON.parse(run('snapshot')).kind,'form');
// Opening mirrors the school's menu handler: load the leave page into mainFrame.
let hideCalls=0;
const mainFrame={name:'mainFrame',document:{},location:{pathname:'/NIU/portal.aspx',href:''},frames:[]};
const portal={location:{pathname:'/NIU/MainFrame.aspx'},frames:{mainFrame,length:0},hideView(){hideCalls++;}};
assert.equal(run('openPage',{path:'/NIU/Application/SEC/SEC20/SEC2010_.aspx?progcd=SEC2010'},portal),'opened');
assert.match(mainFrame.location.href,/\/NIU\/Application\/SEC\/SEC20\/SEC2010_\.aspx\?progcd=SEC2010$/);
assert.equal(portal.__niuLeaveTarget,mainFrame); assert.equal(hideCalls,1);
assert.equal(run('openPage',{path:'/NIU/Application/SEC/SEC40/SEC4030_.aspx?progcd=SEC4030'},{location:{pathname:'/NIU/MainFrame.aspx'},frames:{length:0}}),'waiting');
assert.throws(()=>run('openPage',{path:'https://example.com/'},portal),/FORM_CHANGED/);
// An unrelated frame outside the leave target is not an expired leave session.
const hidden={location:{pathname:'/NIU/TimeoutPage.aspx'},frames:[],document:{}};
const target={location:{pathname:'/NIU/Blank.aspx'},frames:[],document:{}};
const shell={location:{pathname:'/NIU/MainFrame.aspx'},frames:[hidden,target],__niuLeaveTarget:target,__niuLeavePrevious:target.document};
assert.equal(JSON.parse(run('snapshot',{},shell)).kind,'waiting');
// The target's old login document is skipped until a new document commits.
target.location.pathname='/NIU/Default.aspx';
assert.equal(JSON.parse(run('snapshot',{},shell)).kind,'waiting');
target.document={};
assert.equal(JSON.parse(run('snapshot',{},shell)).kind,'expired');
// TimeoutPage is a committed document, not an alert. Expiry wins over a still
// readable form/list/picker elsewhere, including viewFrame outside mainFrame.
for (const pathname of ['/NIU/TimeoutPage.aspx', '/NIU/Default.aspx', '/NIU/Login.aspx']) {
  for (const placement of ['mainFrame', 'viewFrame', 'picker']) {
    const expired = {location:{pathname}, document:{}, frames:[]};
    const main = placement === 'mainFrame' ? expired : {...form, frames:placement === 'picker' ? [expired] : []};
    const frames = [main]; frames.mainFrame = main;
    if (placement === 'viewFrame') { frames.push(expired); frames.viewFrame = expired; }
    const root = {location:{pathname:'/NIU/MainFrame.aspx'}, frames, __niuLeaveTarget:main};
    for (const script of ['periods', 'snapshot', 'list']) {
      assert.equal(JSON.parse(run(script, {listPage:'/SEC2015_01.aspx'}, root)).kind, 'expired', `${script}: ${pathname} in ${placement}`);
    }
    assert.equal(run('withdrawSettled', {formNo:'fixture'}, root), 'expired');
    for (const script of ['openRecord', 'acceptNotice', 'openPeriods', 'bindPeriods', 'upload', 'submit', 'submitSupplement', 'withdraw']) {
      assert.throws(() => run(script, {}, root), /SESSION_EXPIRED/, `${script} refuses expired documents`);
    }
  }
}
const overlay = {location:{pathname:'/NIU/timeout.aspx'}, document:{}, frames:[]};
const liveMain = {...form, frames:[overlay]};
const liveFrames = [liveMain, overlay, picker]; liveFrames.mainFrame = liveMain; liveFrames.timeoutFrame = overlay;
const liveRoot = {location:{pathname:'/NIU/MainFrame.aspx'}, frames:liveFrames, __niuLeaveTarget:liveMain};
assert.equal(JSON.parse(run('snapshot', {}, liveRoot)).kind, 'form', 'permanent timeoutFrame is harmless, even under mainFrame');
assert.equal(JSON.parse(run('periods', {}, liveRoot)).kind, 'periods');
const login = {location:{pathname:'/NIU/Login.aspx',search:'?GuId=synthetic'}, document:{}, frames:[]};
liveMain.frames = [login];
assert.equal(JSON.parse(run('snapshot', {}, liveRoot)).kind, 'form', 'GUID-bearing bridge is not expired');
login.location.search = '?GUID=';
assert.equal(JSON.parse(run('snapshot', {}, liveRoot)).kind, 'expired', 'empty GUID is expired');
for (const marker of ['__niuLeaveViewPrevious', '__niuLeavePreviousPickerDocument']) {
  liveRoot[marker] = login.document;
  for (const script of ['snapshot', 'periods']) assert.notEqual(JSON.parse(run(script, {}, liveRoot)).kind, 'expired', `${marker}: stale document skipped`);
  delete liveRoot[marker];
}
// A sibling's stale timeout document is skipped until record navigation commits.
liveMain.frames = [];
liveFrames.viewFrame = login; liveFrames.push(login);
liveRoot.__niuLeaveViewPrevious = login.document;
assert.equal(JSON.parse(run('snapshot', {}, liveRoot)).kind, 'form');
login.document = {};
assert.equal(JSON.parse(run('snapshot', {}, liveRoot)).kind, 'expired');
// The notice drops its heading, padding lines and the trailing server timestamp.
const noticePage={location:{pathname:'/NIU/Application/SEC/SEC20/SEC2010_02.aspx'},frames:[],
  document:{body:{innerText:'SEC2010_學生請假申請\n請假注意事項\n\n請假注意事項：\n一、考試週請假。\t\n\n\n\n十三、李先生，電話 03-931-7077。　\n\n\n\n\n10/02/2026 18:15:34\n'}}};
const notice=JSON.parse(run('snapshot',{},{location:{pathname:'/NIU/MainFrame.aspx'},frames:[noticePage]})).notice;
assert.equal(notice,'一、考試週請假。\n\n十三、李先生，電話 03-931-7077。');

// ---- 我的假單: synthetic DataGrid shaped like SEC4030/SEC2015 (verified headers, fake data).
function cell(text, attrs={}) { return {innerText:text, getAttribute:n=>attrs[n]||null, clicks:0, click(){this.clicks++;}}; }
function grid(head, rows) {
  const hr={cells:head.map(h=>cell(h)), innerText:head.join('\t'), querySelector:s=>s==='th'?{}:null};
  return {rows:[hr,...rows]};
}
const HEAD=['','','','假單序號','申請日期','請假類別','請假起日','請假訖日','起始節次','迄止節次','請假總節數','審核結果'];
let delClicks=0;
function manageRow(no, status, withActions) {
  const del={id:'DataGrid_ctl02_del', click(){delClicks++;},
    getAttribute:n=>n==='href'?"javascript:__doPostBack('DataGrid$ctl02$del','')":null};
  const cells=[cell('撤回'), cell('修改',{onclick:`doEdit1_2(this, 'PKNO|P1|FORM_NO|${no}|FROM|SEC2015', 'Mod')`}),
    cell('補檔',{onclick:`doEdit1_2(this, 'PKNO|P1|FORM_NO|${no}|FROM|SEC2015', 'Detail')`}),
    cell(no), cell('115/10/02'), cell('事假'), cell('1151008'), cell('115/10/08'), cell('10'), cell('10'), cell('1'), cell(status)];
  return {cells, querySelector:s=>s==='th'?null:(s==='a[id$="_del"]'&&withActions?del:null)};
}
let queryClicks=0, pagerText='【每頁 ，第 共 頁 0 筆】';
const manageGrid=grid(HEAD,[manageRow('1150005007','申請中',true)]);
const listDoc={body:{get innerText(){return pagerText;}}, querySelector:()=>null,
  getElementById:id=>id==='QUERY_BTN1'?{click(){queryClicks++; pagerText='【每頁 ，第 共 1 頁 1 筆】';}}:id==='DataGrid'?manageGrid:null};
const listFrame={location:{pathname:'/NIU/Application/SEC/SEC20/SEC2015_01.aspx'},document:listDoc,frames:[]};
const listTop={location:{pathname:'/NIU/MainFrame.aspx'},frames:[listFrame],__niuLeavePrevious:{}};
assert.equal(JSON.parse(run('list',{listPage:'/SEC2015_01.aspx'},listTop)).kind,'waiting','first poll runs the school query');
assert.equal(queryClicks,1);
const listed=JSON.parse(run('list',{listPage:'/SEC2015_01.aspx'},listTop));
assert.equal(queryClicks,1,'query runs once per page');
assert.equal(listed.kind,'list');
assert.deepEqual(listed.records[0],{formNo:'1150005007',appliedDate:'115/10/02',type:'事假',startDate:'115/10/08',endDate:'115/10/08',
  startPeriod:'10',endPeriod:'10',totalPeriods:'1',status:'申請中'},'unformatted 1151008 becomes 115/10/08');
assert.deepEqual(listed.actions[0],{formNo:'1150005007',withdraw:true,modify:true,supplement:true});
// A healthy list may coexist with the permanent timeout overlay.
listTop.__niuLeaveTarget = listFrame;
listFrame.frames.push(overlay);
assert.equal(JSON.parse(run('list',{listPage:'/SEC2015_01.aspx'},listTop)).kind,'list');
// A stale target document never reports expiry while navigation is committing.
for (const script of ['periods', 'list', 'snapshot']) {
  const stale = {location:{pathname:'/NIU/TimeoutPage.aspx'},document:{},frames:[]};
  const root = {frames:[stale], __niuLeaveTarget:stale, __niuLeavePrevious:stale.document};
  assert.equal(JSON.parse(run(script, {listPage:'/SEC2015_01.aspx'}, root)).kind, 'waiting');
}
// Parent form readiness must not fabricate an empty attachment list.
assert.equal(JSON.parse(run('snapshot')).attachmentNames, null);
const uploadNodes = {tmpfile:{}, attach:{}};
let attachmentRows = [];
const uploadFrame = {location:{pathname:'/NIU/UploadFile_HasUseId.aspx'}, frames:[],
  document:{readyState:'loading', getElementById:id=>uploadNodes[id], querySelectorAll:()=>attachmentRows}};
form.frames.push(uploadFrame);
assert.equal(JSON.parse(run('snapshot')).attachmentNames, null);
uploadFrame.document.readyState = 'complete';
assert.deepEqual(JSON.parse(run('snapshot')).attachmentNames, [], 'loaded empty uploader');
attachmentRows = [{querySelector:()=>({}), innerText:'proof.pdf'}];
assert.deepEqual(JSON.parse(run('snapshot')).attachmentNames, ['proof.pdf'], 'loaded attachments');
form.frames.pop();
// Opening a record taps the matching row's own cell; an unknown form is refused.
assert.equal(run('openRecord',{listPage:'/SEC2015_01.aspx',formNo:'1150005007',mode:'Mod'},listTop),'opened');
assert.equal(manageGrid.rows[1].cells[1].clicks,1);
assert.throws(()=>run('openRecord',{listPage:'/SEC2015_01.aspx',formNo:'999',mode:'Mod'},listTop),/RECORD_MISSING/);
// Withdraw runs the school's own confirm, then posts the row's own event target once,
// from a string timeout (global non-strict context, like the link's javascript: URL).
assert.throws(()=>run('withdraw',{formNo:'999'},listTop),/RECORD_MISSING/);
assert.throws(()=>run('withdraw',{formNo:'1150005007'},listTop),/FORM_CHANGED/,'no school doDelete, nothing posted');
const timeouts=[]; let confirmAnswer=false, confirms=0;
listFrame.doDelete=()=>{confirms++; return confirmAnswer;};
listFrame.setTimeout=(code,ms)=>timeouts.push([code,ms]);
assert.equal(run('withdraw',{formNo:'1150005007'},listTop),'declined'); assert.equal(timeouts.length,0);
confirmAnswer=true;
assert.equal(run('withdraw',{formNo:'1150005007'},listTop),'posted');
assert.deepEqual(timeouts,[["__doPostBack('DataGrid$ctl02$del','')",0]]); assert.equal(confirms,2);
assert.equal(delClicks,0,'the javascript: link itself is never clicked');
assert.throws(()=>run('withdraw',{formNo:'1150005007'},listTop),/ALREADY_SUBMITTED/); assert.equal(timeouts.length,1);
// Settled once the grid no longer lists the form (or the page was replaced).
assert.equal(run('withdrawSettled',{formNo:'1150005007'},listTop),'waiting');
manageGrid.rows.splice(1,1);
assert.equal(run('withdrawSettled',{formNo:'1150005007'},listTop),'removed');
assert.equal(run('withdrawSettled',{formNo:'1150005007'},{...listTop,__niuLeaveWithdrawDocument:{}}),'reloaded');
manageGrid.rows.push(manageRow('1150005007','申請中',true));
// 請假紀錄 rows offer no actions even though they have a Detail cell.
const recordsFrame={...listFrame,location:{pathname:'/NIU/Application/SEC/SEC40/SEC4030_01.aspx'}};
const recordsTop={location:{pathname:'/NIU/MainFrame.aspx'},frames:[recordsFrame],__niuLeavePrevious:{},__niuLeaveQuery:{doc:listDoc,at:Date.now()}};
const recordsList=JSON.parse(run('list',{listPage:'/SEC4030_01.aspx'},recordsTop));
assert.equal(recordsList.records.length,1);
assert.equal(recordsList.actions.filter(a=>a.supplement).length,0);

// ---- 修改 and 補檔 forms: mode, form number, saved values and existing periods.
let modSends=0;
const detailGrid=grid(['請假日期','請假節次','課程名稱','課號','授課教師'],
  [{cells:[cell('115/10/08'),cell('10'),cell('測試課程'),cell('C001'),cell('測試教師')],querySelector:()=>null}]);
detailGrid.id='DataGrid';
const modNodes={...nodes, Mode:{value:'MOD'}, M_FORM_NO:{value:'1150005007'},
  M_HOLIDAY_CODE:{options:[{value:'',text:''},{value:'023',text:'事假'}],value:'023'},
  M_HOLIDAY_DATE_S:{value:'1151008'}, M_HOLIDAY_DATE_E:{value:'115/10/08'}, M_APP_ORIGIN:{value:'原事由'},
  CheckBox1:{checked:true}, CLASS_INFO:{value:'1151008|10|C|1'}, SEND_BTN1:{value:'修改',click(){modSends++;}}, DataGrid:detailGrid};
const modDoc={querySelector:s=>s.startsWith('#')?modNodes[s.slice(1)]:null, querySelectorAll:s=>s==='table'?[detailGrid]:[], getElementById:id=>modNodes[id]};
const modForm={location:{pathname:'/NIU/Application/SEC/SEC20/SEC2010_01.aspx'},document:modDoc,frames:[]};
const modTop={location:{pathname:'/NIU/MainFrame.aspx'},frames:[modForm]};
const mod=JSON.parse(run('snapshot',{},modTop));
assert.equal(mod.mode,'MOD'); assert.equal(mod.formNo,'1150005007'); assert.equal(mod.submitLabel,'修改');
assert.deepEqual(mod.current,{leaveType:'023',startDate:'115/10/08',endDate:'115/10/08',reason:'原事由',supplementLater:true});
assert.deepEqual(mod.existingPeriods,[{date:'115/10/08',period:'10',course:'測試課程',courseNo:'C001',teacher:'測試教師'}]);
// A stale view document from an earlier open is not read as the new form.
assert.equal(JSON.parse(run('snapshot',{},{...modTop,__niuLeaveViewPrevious:modDoc})).kind,'waiting');
const modArgs={leaveType:'023',selected:['1151008|10|C|1'],startDate:'115/10/08',endDate:'115/10/08',expectedButton:'修改'};
assert.throws(()=>run('submit',{...modArgs,expectedFormNo:'1150009999'},modTop),/FORM_CHANGED/,'other form number');
assert.throws(()=>run('submit',{...modArgs,expectedFormNo:'',expectedButton:'送出'},modTop),/FORM_CHANGED/,'apply never saves into a MOD form');
assert.equal(modSends,0);
assert.equal(run('submit',{...modArgs,expectedFormNo:'1150005007'},modTop),'attempted'); assert.equal(modSends,1);
// 補檔 presses「送出」only on the expected DETAIL form, once.
let detailSends=0;
const detNodes={...modNodes, Mode:{value:'DETAIL'}, SEND_BTN1:{value:'送出',disabled:false,click(){detailSends++;}}};
const detTop={location:{pathname:'/NIU/MainFrame.aspx'},frames:[{...modForm,document:{...modDoc,getElementById:id=>detNodes[id],querySelector:s=>s.startsWith('#')?detNodes[s.slice(1)]:null}}]};
assert.throws(()=>run('submitSupplement',{acknowledged:false,expectedFormNo:'1150005007'},detTop),/NOT_CONFIRMED/);
assert.throws(()=>run('submitSupplement',{expectedFormNo:'1150009999'},detTop),/FORM_CHANGED/);
assert.throws(()=>run('submitSupplement',{expectedFormNo:'1150005007'},modTop),/FORM_CHANGED|ALREADY_SUBMITTED/);
assert.equal(run('submitSupplement',{expectedFormNo:'1150005007'},detTop),'attempted'); assert.equal(detailSends,1);
assert.throws(()=>run('submitSupplement',{expectedFormNo:'1150005007'},detTop),/ALREADY_SUBMITTED/); assert.equal(detailSends,1);

// ---- 簽核流程: parsed from the same read-only FLO3020_01 page the form's button opens.
(async () => {
  const td = t => ({textContent:t});
  const flowRows = [['簽核狀況','簽核日期','關卡說明','簽核單位','簽核人','簽核意見'],
    ['已簽核','115/03/26 20:06:28','填單','測試學系','測試學生','(申請送出)'],
    ['退回','115/03/31 14:05:00','承辦人歸檔','測試組','測試承辦','需檢附核准公文。'],
    ['簽核中','','填單','測試學系','測試學生','']];
  const flowGrid = {rows: flowRows.map(r => ({cells:r.map(td), textContent:r.join(' ')}))};
  const page = (formNo) => ({querySelectorAll: sel => sel === 'td'
      ? [td('申請單編號：'), td(formNo), td('簽核流程：'), td('01- 學生請假三日內(日間)')]
      : sel === 'table' ? [flowGrid] : []});
  let fetched = null, served = page('1150005007'), finalPath = '/NIU/Application/FLO/FLO30/FLO3020_01.aspx';
  let status = 200, stalled = false, abortRead, timerCleared = false;
  const flowNodes = {M_FORM_NO:{value:'1150005007'}, H_FORM_CODE:{value:'01'}, H_APPROVE_FLOW_CODE:{value:'01'}};
  const flowForm = {location:{pathname:'/NIU/Application/SEC/SEC20/SEC2010_01.aspx'}, frames:[],
    document:{getElementById:id=>flowNodes[id]},
    fetch: async (url, options) => {
      fetched = url;
      assert.equal(options.credentials, 'same-origin');
      if (stalled) return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('ABORTED'))));
      return {url:'https://acade.niu.edu.tw' + finalPath, status, ok:status === 200, text: async () => ''};
    },
    DOMParser: function () { this.parseFromString = () => served; }};
  const flowTop = {location:{pathname:'/NIU/MainFrame.aspx'}, frames:[flowForm]};
  const runAsync = (name, extra) => vm.runInNewContext(`(async function(){${blocks.helpers}\n${blocks[name]}})()`,
    {window:flowTop, URL, URLSearchParams, AbortController,
      setTimeout(callback, delay) { assert.equal(delay, 15000); abortRead = callback; timerCleared = false; return 1; },
      clearTimeout(timer) { assert.equal(timer, 1); timerCleared = true; }, ...args, ...extra});
  const flow = JSON.parse(await runAsync('flow', {formNo:'1150005007'}));
  assert.equal(fetched, '/NIU/Application/FLO/FLO30/FLO3020_01.aspx?FORM_CODE=01&APPROVE_FLOW_CODE=01&FORM_NO=1150005007&STAFF_ID=');
  assert.equal(flow.kind, 'flow'); assert.equal(flow.name, '學生請假三日內(日間)');
  assert.equal(flow.steps.length, 3);
  assert.deepEqual(flow.steps[1], {status:'退回', date:'115/03/31 14:05:00', stage:'承辦人歸檔', unit:'測試組', person:'測試承辦', comment:'需檢附核准公文。'});
  await assert.rejects(runAsync('flow', {formNo:'1150009999'}), /FORM_CHANGED/, 'only the open form');
  served = page('1150009999');
  await assert.rejects(runAsync('flow', {formNo:'1150005007'}), /FORM_CHANGED/, 'page for another form');
  served = page('1150005007'); finalPath = '/NIU/Default.aspx';
  assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'expired', 'login redirect is a lapsed session');
  assert.equal(timerCleared, true, 'redirect clears the timeout');
  finalPath = '/NIU/Application/FLO/FLO30/FLO3020_01.aspx'; status = 503;
  assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'unavailable', 'server failure is not expired login');
  status = 401;
  assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'expired');
  status = 200; served = {querySelectorAll: () => []};
  assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'unavailable', 'changed markup is not expired login');
  for (const pathname of ['/NIU/TimeoutPage.aspx', '/NIU/Login.aspx']) {
    finalPath = pathname;
    assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'expired');
  }
  finalPath = '/NIU/timeout.aspx';
  assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'unavailable', 'timeout overlay is not expiry');
  finalPath = '/NIU/Application/FLO/FLO30/FLO3020_01.aspx';
  flowTop.__niuLeaveTarget = flowForm;
  flowForm.frames = [{location:{pathname:'/NIU/TimeoutPage.aspx'},document:{},frames:[]}];
  fetched = null;
  assert.equal(JSON.parse(await runAsync('flow', {formNo:'1150005007'})).kind, 'expired');
  assert.equal(fetched, null, 'expired child prevents flow fetch');
  flowForm.frames = [];
  stalled = true;
  const pending = runAsync('flow', {formNo:'1150005007'});
  abortRead();
  await assert.rejects(pending, /ABORTED/, 'a stalled request is bounded');
  assert.equal(timerCleared, true, 'aborted request clears the timeout');
  console.log('PASS: approval flow request, parsing, form identity, lapsed-session redirect, failure distinction and bounded fetch.');
})().catch(error => { console.error(error); process.exitCode = 1; });
console.log('PASS: records/actions list, open record, one-shot withdraw via school confirm and postback, modify/supplement form checks, mainFrame entry, notice cleanup, scoped expiry, required acknowledgement, account identity, school options, exact periods, missing controls, one-attempt submission, course parsing and disabled selection.');
