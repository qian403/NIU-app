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

const fillSection = source.slice(source.indexOf('private func fillModernLoginForm'));
const fillTemplate = fillSection.match(/let script = """\n([\s\S]*?)\n\s*"""/)[1];
function fill({ automatic, alreadyFilled = false, disabled = false, observed = false,
    location = { protocol: 'https:', hostname: 'ccsys1.niu.edu.tw', pathname: '/SSO/login' } }) {
    const script = fillTemplate
        .replace(String.raw`\(json)`, JSON.stringify(['synthetic', 'fixture-password']))
        .replace(String.raw`\(shouldFill)`, String(!alreadyFilled))
        .replace(String.raw`\(shouldSubmit)`, String(automatic));
    class Input {
        constructor(value) { this._value = value; this.writes = 0; }
        get value() { return this._value; }
        set value(value) { this._value = value; this.writes++; }
        checkValidity() { return true; }
        dispatchEvent() {}
    }
    const username = new Input('user-edit');
    const password = new Input('manual-password');
    let clicks = 0;
    const submit = { disabled, click() { clicks++; } };
    const form = { addEventListener() {} };
    const state = vm.runInNewContext(script, {
        HTMLInputElement: Input, Event: class {}, location,
        window: { __niuAppSubmitObserved: observed },
        document: { querySelector(selector) {
            return ({
                '#username': username, '#password': password,
                'form.login-form': form, 'form.login-form button[type="submit"]': submit,
            })[selector];
        } },
    });
    return { state, clicks, writes: username.writes + password.writes, username: username.value };
}
assert.deepEqual(fill({ automatic: true }),
    { state: 'submitted', clicks: 1, writes: 2, username: 'synthetic' });
assert.deepEqual(fill({ automatic: true, disabled: true }),
    { state: 'waiting_verification', clicks: 0, writes: 2, username: 'synthetic' });
assert.deepEqual(fill({ automatic: false }),
    { state: 'manual', clicks: 0, writes: 2, username: 'synthetic' });
assert.deepEqual(fill({ automatic: false, alreadyFilled: true }),
    { state: 'manual', clicks: 0, writes: 0, username: 'user-edit' });
assert.deepEqual(fill({ automatic: false, alreadyFilled: true, observed: true }),
    { state: 'submitted', clicks: 0, writes: 0, username: 'user-edit' });
for (const location of [
    { protocol: 'https:', hostname: 'evil.example', pathname: '/SSO/login' },
    { protocol: 'https:', hostname: 'ccsys1.niu.edu.tw.evil.example', pathname: '/SSO/login' },
    { protocol: 'http:', hostname: 'ccsys1.niu.edu.tw', pathname: '/SSO/login' },
    { protocol: 'https:', hostname: 'ccsys1.niu.edu.tw', pathname: '/SSO/dashboard' },
]) {
    assert.deepEqual(fill({ automatic: true, location }),
        { state: 'waiting', clicks: 0, writes: 0, username: 'user-edit' });
}
console.log('PASS: automatic submit, blocked verification, manual prefill, preserved user edits, no duplicate submit, no off-origin fill');
