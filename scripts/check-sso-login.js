// Run: node Scripts/check-sso-login.js
// Exercise the actual WebView polling script without an account or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
    '../Features/Authentication/Services/SSOLoginWebView.swift'), 'utf8');
const section = source.slice(source.indexOf('private func checkModernLoginState'));
const script = section.match(/let script = """\n([\s\S]*?)\n\s*"""/)[1];

function element(text, icon, visible = true, loading = false) {
    return {
        innerText: text,
        getClientRects: () => visible ? [{}] : [],
        getAttribute: name => name === 'data-icon' ? icon : null,
        querySelector: selector => selector.split(',').some(part =>
            part.includes(`.swal2-${icon}`)) ? {} : null,
        loading,
    };
}

function poll({ popup, danger, token = '' } = {}) {
    return JSON.parse(vm.runInNewContext(script, {
        sessionStorage: { getItem: () => token },
        getComputedStyle: () => ({ visibility: 'visible' }),
        document: {
            querySelector: selector => {
                if (selector.includes('.swal2-popup') && popup) return popup;
                if (selector.includes('.alert-danger') && danger) return danger;
                return null;
            },
            querySelectorAll: selector => selector === '.alert-danger' && danger ? [danger] : [],
        },
    }));
}

// The school calls Swal.fire + showLoading before the login API returns.
// Multiple polling ticks must keep waiting, rather than end the login.
for (let tick = 0; tick < 4; tick++) {
    assert.equal(poll({ popup: element('登入中...', null, true, true) }).error, '');
}
assert.deepEqual(poll({ popup: element('登入成功', 'success'), token: 'fixture-token' }),
    { token: 'fixture-token', error: '' });
assert.equal(poll({ popup: element('登入成功', 'success') }).error, '');
assert.equal(poll({ popup: element('系統公告', 'info') }).error, '');
assert.equal(poll({ popup: element('一般注意事項', 'warning') }).error, '');
assert.equal(poll({ popup: element('密碼即將到期', 'warning') }).error, '');
assert.equal(poll({ popup: element('帳號或密碼不正確', 'error') }).error, '帳號或密碼不正確');
assert.equal(poll({ popup: element('密碼已過期', 'warning') }).error, '密碼已過期');
assert.equal(poll({ popup: element('請變更預設密碼', 'warning') }).error, '請變更預設密碼');
assert.equal(poll({ popup: element('帳號已鎖定', 'warning') }).error, '帳號已鎖定');
assert.equal(poll({ popup: element('上次失敗', 'error', false) }).error, '');
assert.equal(poll({ danger: element('登入失敗', null) }).error, '登入失敗');
assert.equal(poll({ danger: element('上次失敗', null, false) }).error, '');
console.log('PASS: login loading → token; success/info/warnings; actual and hidden errors');
