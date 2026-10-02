import Foundation

nonisolated enum LeaveApplicationScript {
    static let helpers = #"""
    function find(path, w = window) {
      try {
        if (w.location.pathname.toLowerCase().endsWith(path.toLowerCase())) return w;
        for (let i = 0; i < w.frames.length; i++) { const f = find(path, w.frames[i]); if (f) return f; }
      } catch (_) {}
      return null;
    }
    function studentNumber(d) {
      const e = d.querySelector('#M_STNO');
      return ((e && (e.value || e.textContent)) || '').trim();
    }
    function form() {
      const w = find('/SEC2010_01.aspx');
      if (!w || !w.document.querySelector('#M_HOLIDAY_CODE')) throw Error('FORM_CHANGED');
      const studentID = studentNumber(w.document);
      if (!studentID || studentID.toLowerCase() !== account.toLowerCase()) throw Error('ACCOUNT_CHANGED');
      return w;
    }
    function set(w, id, value) {
      const e = w.document.getElementById(id); if (!e) throw Error('FORM_CHANGED');
      e.value = value;
    }
    function val(d, id) { const e = d.getElementById(id); return e ? String(e.value || '').trim() : ''; }
    // The school returns both `115/10/08` and `1151008` for saved dates.
    function roc(v) {
      const m = String(v || '').trim().match(/^(\d{2,3})\/?(\d{2})\/?(\d{2})$/);
      return m ? m[1].padStart(3, '0') + '/' + m[2] + '/' + m[3] : String(v || '').trim();
    }
    function formMode(d) { return val(d, 'Mode').toUpperCase(); }
    function cellText(c) { return String((c && c.innerText) || '').replace(/\s+/g, ' ').trim(); }
    // Rows of a school DataGrid keyed by header text.
    function gridRows(d, id) {
      const grid = d.getElementById(id || 'DataGrid');
      if (!grid || !grid.rows.length) return null;
      const head = [...grid.rows[0].cells].map(cellText);
      return [...grid.rows].filter(r => !r.querySelector('th')).map(r => ({row: r,
        get: name => { const i = head.indexOf(name); return i < 0 ? '' : cellText(r.cells[i]); }}));
    }
    // MainFrame preloads a hidden timeout page. Only the frame we opened (and its
    // children) can report that this leave session expired; its old document is skipped.
    function leaveExpired() {
      const target = window.__niuLeaveTarget;
      if (!target) return false;
      function scan(w) {
        try {
          if (w === target && w.document === window.__niuLeavePrevious) return false;
          if (/\/(?:TimeoutPage|Default|Login)\.aspx$/i.test(w.location.pathname)) return true;
          for (let i = 0; i < w.frames.length; i++) if (scan(w.frames[i])) return true;
        } catch (_) {}
        return false;
      }
      return scan(target);
    }
    """#

    // Same as the school's menu items (學生請假申請／修改、請假紀錄), whose handler is
    // `top.mainFrame.location.href = url; top.hideView()` (verified 2026-10-02).
    // The menu tree is populated lazily three levels deep, so it is not clicked.
    static let openPage = helpers + #"""
    const frame = window.frames['mainFrame'];
    if (!frame) return 'waiting';
    if (!/^\/NIU\/Application\/SEC\/SEC\d+\/SEC\d+_\.aspx\?progcd=SEC\d+$/.test(path)) throw Error('FORM_CHANGED');
    window.__niuLeaveTarget = frame;
    try { window.__niuLeavePrevious = frame.document; } catch (_) { window.__niuLeavePrevious = null; }
    window.__niuLeaveQuery = null;
    frame.location.href = path;
    try { if (typeof window.hideView === 'function') window.hideView(); } catch (_) {}
    return 'opened';
    """#

    // Runs the list page's own「查詢」(a partial postback) once, then parses its DataGrid.
    // Records come from 請假紀錄; actions only exist on 學生請假修改 rows.
    static let list = helpers + #"""
    const w = find(listPage);
    if (!w || w.document === window.__niuLeavePrevious) return JSON.stringify({kind: leaveExpired() ? 'expired' : 'waiting'});
    const d = w.document, q = window.__niuLeaveQuery;
    if (!q || q.doc !== d) {
      const button = d.getElementById('QUERY_BTN1');
      if (!button) throw Error('FORM_CHANGED');
      window.__niuLeaveQuery = {doc: d, at: Date.now()};
      button.click();
      return JSON.stringify({kind: 'waiting'});
    }
    const pager = ((d.body.innerText || '').match(/【[^】]*】/) || [''])[0];
    // Before a query the pager reads「共 頁」; afterwards it has a page count.
    const settled = /共\s*\d+\s*頁/.test(pager) || (Date.now() - q.at > 6000 && !d.querySelector('.blockUI'));
    if (!settled) return JSON.stringify({kind: 'waiting'});
    const rows = gridRows(d) || [];
    const records = rows.map(r => ({formNo: r.get('假單序號'), appliedDate: r.get('申請日期'), type: r.get('請假類別'),
      startDate: roc(r.get('請假起日')), endDate: roc(r.get('請假訖日')), startPeriod: r.get('起始節次'),
      endPeriod: r.get('迄止節次'), totalPeriods: r.get('請假總節數'), status: r.get('審核結果')})).filter(r => r.formNo);
    const actions = rows.map(r => {
      const cells = [...r.row.cells].map(c => c.getAttribute('onclick') || '');
      return {formNo: r.get('假單序號'), withdraw: !!r.row.querySelector('a[id$="_del"]'),
        modify: cells.some(c => /doEdit1_2\(.*'Mod'\)/.test(c)), supplement: listPage === '/SEC2015_01.aspx' && cells.some(c => /doEdit1_2\(.*'Detail'\)/.test(c))};
    }).filter(a => a.formNo && (a.withdraw || a.modify || a.supplement));
    return JSON.stringify({kind: 'list', records, actions});
    """#

    // Opens one form from the current list the way tapping its cell does: the school posts
    // Mode=MOD/DETAIL with PKNO/FORM_NO into viewFrame (SEC2010_01.aspx).
    static let openRecord = helpers + #"""
    const w = find(listPage);
    if (!w) throw Error('FORM_CHANGED');
    const row = (gridRows(w.document) || []).find(r => r.get('假單序號') === formNo);
    if (!row) throw Error('RECORD_MISSING');
    const cell = [...row.row.cells].find(c => (c.getAttribute('onclick') || '').includes("'" + mode + "'"));
    if (!cell) throw Error('RECORD_MISSING');
    const view = find('/SEC2010_01.aspx');
    window.__niuLeaveViewPrevious = view ? view.document : null;
    cell.click();
    return 'opened';
    """#

    // Does what the row's「撤回」link does: `onclick="return doDelete();"` (the school's
    // 「確定刪除 1 筆資料??」confirm), then `href="javascript:__doPostBack('DataGrid$ctlNN$del','')"`.
    // The postback runs from a string timeout, the same global non-strict context as a
    // javascript: URL: it never passes the navigation filter, and MS Ajax's __doPostBack
    // inspects its caller and throws when called from strict code.
    static let withdraw = helpers + #"""
    const w = find('/SEC2015_01.aspx');
    if (!w) throw Error('FORM_CHANGED');
    const row = (gridRows(w.document) || []).find(r => r.get('假單序號') === formNo);
    const link = row && row.row.querySelector('a[id$="_del"]');
    if (!link) throw Error('RECORD_MISSING');
    const target = ((link.getAttribute('href') || '').match(/__doPostBack\('([^']+)'/) || [])[1];
    if (!target || !/^DataGrid\$ctl\d+\$del$/.test(target) || typeof w.doDelete !== 'function') throw Error('FORM_CHANGED');
    if (window.__niuLeaveWithdrawn === formNo) throw Error('ALREADY_SUBMITTED');
    if (!w.doDelete()) return 'declined';
    window.__niuLeaveWithdrawn = formNo;
    window.__niuLeaveWithdrawDocument = w.document;
    w.setTimeout("__doPostBack('" + target + "','')", 0);
    return 'posted';
    """#

    // Whether the withdraw postback finished: the page was replaced, or the grid was
    // re-rendered without the form once the school's busy overlay is gone.
    static let withdrawSettled = helpers + #"""
    const w = find('/SEC2015_01.aspx');
    if (!w || w.document !== window.__niuLeaveWithdrawDocument) return 'reloaded';
    if (w.document.querySelector('.blockUI')) return 'waiting';
    const row = (gridRows(w.document) || []).find(r => r.get('假單序號') === formNo);
    return row ? 'waiting' : 'removed';
    """#

    // 簽核流程: the same read-only page the form's「簽核流程」button opens
    // (FLO3020_01.aspx with FORM_CODE / APPROVE_FLOW_CODE / FORM_NO from the open form).
    static let flow = helpers + #"""
    const w = find('/SEC2010_01.aspx');
    if (!w) throw Error('FORM_CHANGED');
    const d = w.document;
    if (val(d, 'M_FORM_NO') !== formNo) throw Error('FORM_CHANGED');
    const formCode = val(d, 'H_FORM_CODE'), flowCode = val(d, 'H_APPROVE_FLOW_CODE');
    if (!formCode || !flowCode) throw Error('FORM_CHANGED');
    const url = '/NIU/Application/FLO/FLO30/FLO3020_01.aspx?FORM_CODE=' + encodeURIComponent(formCode)
      + '&APPROVE_FLOW_CODE=' + encodeURIComponent(flowCode) + '&FORM_NO=' + encodeURIComponent(formNo) + '&STAFF_ID=';
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    let page;
    try {
      const response = await w.fetch(url, {credentials: 'same-origin', signal: controller.signal});
      if (!/\/FLO3020_01\.aspx$/i.test(new URL(response.url).pathname) || response.status === 401) return JSON.stringify({kind: 'expired'});
      if (!response.ok) return JSON.stringify({kind: 'unavailable'});
      page = new w.DOMParser().parseFromString(await response.text(), 'text/html');
    } finally {
      clearTimeout(timeout);
    }
    const text = c => String((c && c.textContent) || '').replace(/\s+/g, ' ').trim();
    const cells = [...page.querySelectorAll('td')];
    const labelled = label => { const i = cells.findIndex(c => text(c) === label); return i < 0 ? '' : text(cells[i + 1]); };
    if (labelled('申請單編號：') && labelled('申請單編號：') !== formNo) throw Error('FORM_CHANGED');
    const grid = [...page.querySelectorAll('table')].find(t => t.rows.length && /簽核狀況/.test(text(t.rows[0])) && /關卡說明/.test(text(t.rows[0])));
    if (!grid) return JSON.stringify({kind: 'unavailable'});
    const head = [...grid.rows[0].cells].map(text);
    const get = (r, name) => { const i = head.indexOf(name); return i < 0 ? '' : text(r.cells[i]); };
    const steps = [...grid.rows].slice(1).map(r => ({status: get(r, '簽核狀況'), date: get(r, '簽核日期'), stage: get(r, '關卡說明'),
      unit: get(r, '簽核單位'), person: get(r, '簽核人'), comment: get(r, '簽核意見')})).filter(s => s.status || s.stage);
    return JSON.stringify({kind: 'flow', name: labelled('簽核流程：').replace(/^\d+-\s*/, ''), steps});
    """#

    // Evaluated in a subframe before a cross-origin login redirect commits.
    static let isLeaveFrame = #"""
    (() => {
      try {
        const root = window.top;
        for (let w = window; w && w !== root; w = w.parent) {
          if (w === root.__niuLeaveTarget) return true;
          if (/\/SEC\d+_\d*\.aspx$/i.test(w.location.pathname)) return true;
        }
      } catch (_) {}
      return false;
    })()
    """#

    static let snapshot = helpers + #"""
    const notice = find('/SEC2010_02.aspx');
    if (notice) {
      const text = notice.document.body.innerText;
      const marker = '請假注意事項：';
      const start = text.indexOf(marker);
      const end = text.indexOf('Server:', start);
      // Keep the school's wording; drop its heading, padding lines and the trailing
      // server timestamp (e.g. 10/02/2026 18:15:34) that the page prints under the notice.
      const body = text.slice(start < 0 ? 0 : start + marker.length, end < 0 ? undefined : end)
        .replace(/[ \t\u00a0\u3000]+$/gm, '').replace(/\n{3,}/g, '\n\n').trim()
        .replace(/\n*\s*\d{1,4}[\/-]\d{1,2}[\/-]\d{1,4}\s+\d{1,2}:\d{2}(?::\d{2})?\s*$/, '').trim();
      return JSON.stringify({kind:'notice', notice: body});
    }
    const w = find('/SEC2010_01.aspx');
    if (!w) return JSON.stringify({kind: leaveExpired() ? 'expired' : 'waiting'});
    if (w.document === window.__niuLeaveViewPrevious || !w.document.getElementById('M_HOLIDAY_CODE'))
      return JSON.stringify({kind: 'waiting'});
    const d = w.document;
    const studentID = studentNumber(d);
    const options = [...(d.querySelector('#M_HOLIDAY_CODE')?.options || [])]
      .filter(o => o.value).map(o => ({id:o.value, title:o.text.trim()}));
    const upload = find('/UploadFile_HasUseId.aspx', w);
    const attachmentNames = upload ? [...upload.document.querySelectorAll('#UploadGrid tr')]
      .filter(r => r.querySelector('a')).map(r => r.innerText.replace(/\s+/g,' ').trim()) : [];
    const type = d.getElementById('M_HOLIDAY_CODE'), later = d.getElementById('CheckBox1');
    const current = {leaveType: type.value || '', startDate: roc(val(d, 'M_HOLIDAY_DATE_S')), endDate: roc(val(d, 'M_HOLIDAY_DATE_E')),
      reason: val(d, 'M_APP_ORIGIN'), supplementLater: !!(later && later.checked)};
    // 「本次請假日期與節次明細」: the grid whose header has 請假日期 and 授課教師.
    const detail = [...d.querySelectorAll('table')].find(t => t.rows.length && /請假日期/.test(cellText(t.rows[0])) && /授課教師/.test(cellText(t.rows[0])));
    const existingPeriods = detail ? (gridRows(d, detail.id) || []).map(r => ({date: roc(r.get('請假日期')), period: r.get('請假節次'),
      course: r.get('課程名稱'), courseNo: r.get('課號'), teacher: r.get('授課教師')})).filter(p => p.date) : [];
    return JSON.stringify({kind:'form', studentID, options, attachmentNames, selected:d.querySelector('#CLASS_INFO')?.value || '',
      mode: formMode(d), formNo: val(d, 'M_FORM_NO'), submitLabel: val(d, 'SEND_BTN1'), editable: !type.disabled, current, existingPeriods});
    """#

    static let acceptNotice = helpers + #"""
    const w = find('/SEC2010_02.aspx');
    const button = w?.document.getElementById('SAVE_BTN2');
    if (!button || button.value !== '同意') throw Error('FORM_CHANGED');
    button.click(); return 'accepted';
    """#

    static let openPeriods = helpers + #"""
    const w = form();
    set(w, 'M_HOLIDAY_DATE_S', startDate); set(w, 'M_HOLIDAY_DATE_E', endDate);
    window.__niuLeavePreviousPickerDocument = find('/SEC2010_03.aspx')?.document || null;
    window.__niuLeavePeriodRange = [startDate, endDate];
    if (w.document.querySelector('.fancybox-iframe')) w.jQuery.fancybox.close();
    w.document.getElementById('OPENCLASS').click(); return 'opened';
    """#

    static let periods = helpers + #"""
    const w = find('/SEC2010_03.aspx');
    if (!w || !w.document.getElementById('table2') || w.document === window.__niuLeavePreviousPickerDocument)
      return JSON.stringify({kind:'waiting'});
    if (window.__niuLeavePeriodRange) {
      const query = new URLSearchParams(w.location.search);
      if (query.get('SDATE') !== window.__niuLeavePeriodRange[0] || query.get('EDATE') !== window.__niuLeavePeriodRange[1])
        return JSON.stringify({kind:'waiting'});
    }
    const periods = [...w.document.querySelectorAll('input[name="chkBox"]')].filter(e=>!e.disabled).map(e => {
      const parts = e.value.split('|'), td = e.closest('td');
      const lines = td.innerText.split('\n').map(t=>t.trim()).filter(Boolean);
      const raw = parts[0];
      return {id:e.value, date:raw.slice(0,3)+'/'+raw.slice(3,5)+'/'+raw.slice(5,7),
        period:td.parentElement.cells[0].innerText.trim(), teacher:lines[0] || '', course:lines[1] || '', room:lines[2] || ''};
    });
    return JSON.stringify({kind:'periods', periods});
    """#

    static let bindPeriods = helpers + #"""
    form();
    const w = find('/SEC2010_03.aspx');
    if (!w) throw Error('FORM_CHANGED');
    const inputs = [...w.document.querySelectorAll('input[name="chkBox"]')];
    if (!selected.length || selected.some(id=>!inputs.some(e=>e.value===id && !e.disabled))) throw Error('FORM_CHANGED');
    inputs.forEach(e=>{e.checked=selected.includes(e.value);});
    w.document.getElementById('BACK_BTN1').click(); return 'binding';
    """#

    static let closePeriods = helpers + #"""
    const w = form();
    if (w.document.querySelector('.fancybox-iframe')) w.jQuery.fancybox.close();
    return 'closed';
    """#

    static let upload = helpers + #"""
    const root = form(), w = find('/UploadFile_HasUseId.aspx', root);
    const input = w?.document.getElementById('tmpfile');
    if (!input || !w.document.getElementById('attach')) throw Error('FORM_CHANGED');
    const binary = atob(base64), bytes = Uint8Array.from(binary, c=>c.charCodeAt(0));
    const file = new w.File([bytes], filename, {type:mime});
    const transfer = new w.DataTransfer(); transfer.items.add(file); input.files = transfer.files;
    set(w, 'remark', filename.replace(/\.[^.]+$/, '').slice(0,200));
    w.document.getElementById('attach').click(); return 'uploading';
    """#

    static let submit = helpers + #"""
    if (!acknowledged || !reason.trim() || !selected.length) throw Error('NOT_CONFIRMED');
    const w = form(), d = w.document;
    if (window.__niuLeaveSubmitted) throw Error('ALREADY_SUBMITTED');
    if (expectedFormNo ? val(d, 'M_FORM_NO') !== expectedFormNo || formMode(d) !== 'MOD'
        : ['MOD', 'DETAIL'].includes(formMode(d))) throw Error('FORM_CHANGED');
    const actual = (d.getElementById('CLASS_INFO')?.value || '').split(',').filter(Boolean);
    if (selected.length !== actual.length || selected.some(id=>!actual.includes(id))) throw Error('PERIODS_CHANGED');
    if (![...d.getElementById('M_HOLIDAY_CODE').options].some(o=>o.value===leaveType)) throw Error('FORM_CHANGED');
    set(w,'M_HOLIDAY_CODE',leaveType); set(w,'M_HOLIDAY_DATE_S',startDate); set(w,'M_HOLIDAY_DATE_E',endDate);
    set(w,'M_APP_ORIGIN',reason.trim());
    const later = d.getElementById('CheckBox1'), button = d.getElementById('SEND_BTN1');
    if (!later || !button || button.value !== expectedButton) throw Error('FORM_CHANGED');
    later.checked = supplementLater;
    window.__niuLeaveSubmitted = true;
    button.click(); return 'attempted';
    """#

    // 補檔: every field is locked (Mode=DETAIL); only attachments change, then「送出」.
    static let submitSupplement = helpers + #"""
    if (!acknowledged) throw Error('NOT_CONFIRMED');
    const w = form(), d = w.document;
    if (window.__niuLeaveSubmitted) throw Error('ALREADY_SUBMITTED');
    if (formMode(d) !== 'DETAIL' || val(d, 'M_FORM_NO') !== expectedFormNo) throw Error('FORM_CHANGED');
    const button = d.getElementById('SEND_BTN1');
    if (!button || button.disabled || button.value !== '送出') throw Error('FORM_CHANGED');
    window.__niuLeaveSubmitted = true;
    button.click(); return 'attempted';
    """#
}
