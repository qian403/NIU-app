// Run: node Scripts/check-sso-login.js
// Exercise the actual WebView polling script without an account or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
    '../Features/Authentication/Services/SSOLoginWebView.swift'), 'utf8');
const section = source.slice(source.indexOf('private func checkModernLoginState'));

// WKWebView's default user agent carries no Safari token; Cloudflare Turnstile
// then demands interactive human verification far more often. The login webview
// must identify as Safari on both platforms.
function makeViewBody(marker) {
    const view = source.slice(source.indexOf(marker));
    return view.slice(0, view.indexOf('public func update'));
}
assert.match(makeViewBody('public func makeNSView'), /webView\.customUserAgent = ssoLoginSafariUserAgent/,
    'macOS login webview must present the Safari user agent');
assert.match(makeViewBody('public func makeUIView'), /webView\.customUserAgent = ssoLoginSafariUserAgent/,
    'iOS login webview must present the Safari user agent');
assert.match(source, /Safari\/604\.1/, 'user agent must contain the mobile Safari token');
assert.match(source, /Safari\/605\.1\.15/, 'user agent must contain the desktop Safari token');
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
function fill({ automatic, afterVerification = false, alreadyFilled = false, disabled = false,
    observed = false, initial = ['user-edit', 'manual-password'], filledBefore = false, widget = null, shown = false, location = { protocol: 'https:', hostname: 'ccsys1.niu.edu.tw', pathname: '/SSO/login' } }) {
    const script = fillTemplate
        .replace(String.raw`\(json)`, JSON.stringify(['synthetic', 'fixture-password']))
        .replace(String.raw`\(shouldFill)`, String(!alreadyFilled))
        .replaceAll(String.raw`\(shouldSubmit)`, String(automatic))
        .replaceAll(String.raw`\(shouldSubmitAfterVerification)`, String(afterVerification));
    class Input {
        constructor(value) { this._value = value; this.writes = 0; }
        get value() { return this._value; }
        set value(value) { this._value = value; this.writes++; }
        checkValidity() { return true; }
        dispatchEvent() {}
    }
    const username = new Input(initial[0]);
    const password = new Input(initial[1]);
    let clicks = 0;
    const submit = { disabled, click() { clicks++; } };
    const form = { addEventListener() {} };
    const state = vm.runInNewContext(script, {
        HTMLInputElement: Input, Event: class {}, location,
        window: { __niuAppSubmitObserved: observed, __niuAppFormFilled: filledBefore, __niuAppVerificationShown: shown },
        document: { querySelector(selector) {
            return ({
                '#username': username, '#password': password,
                'form.login-form': form, 'form.login-form button[type="submit"]': submit,
            })[selector] ?? (selector.includes('cf-turnstile') ? widget : undefined);
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
// Visible page shown only for verification: resume with untouched saved credentials.
const saved = ['synthetic', 'fixture-password'];
assert.deepEqual(fill({ automatic: false, afterVerification: true, alreadyFilled: true, initial: saved, disabled: true }),
    { state: 'waiting_verification', clicks: 0, writes: 0, username: 'synthetic' });
assert.deepEqual(fill({ automatic: false, afterVerification: true, alreadyFilled: true, initial: saved }),
    { state: 'submitted', clicks: 1, writes: 0, username: 'synthetic' });
assert.deepEqual(fill({ automatic: false, afterVerification: true, alreadyFilled: true }),
    { state: 'manual', clicks: 0, writes: 0, username: 'user-edit' });
assert.deepEqual(fill({ automatic: false, afterVerification: true, alreadyFilled: true,
    initial: ['synthetic', 'manual-correction'] }),
    { state: 'manual', clicks: 0, writes: 0, username: 'synthetic' });
assert.deepEqual(fill({ automatic: false, afterVerification: true, alreadyFilled: true, initial: ['', ''] }),
    { state: 'submitted', clicks: 1, writes: 2, username: 'synthetic' });
assert.deepEqual(fill({ automatic: false, afterVerification: true, alreadyFilled: true, initial: ['', ''],
    filledBefore: true }),
    { state: 'manual', clicks: 0, writes: 0, username: '' });
assert.deepEqual(fill({ automatic: false, alreadyFilled: true, initial: saved }),
    { state: 'manual', clicks: 0, writes: 0, username: 'synthetic' });
// Visible verification page: scroll the widget into view once; never click inside it.
{
    const widget = { scrolls: 0, clicks: 0, scrollIntoView() { this.scrolls++; }, click() { this.clicks++; } };
    const saved = ['synthetic', 'fixture-password'];
    assert.equal(fill({ automatic: false, afterVerification: true, alreadyFilled: true, initial: saved,
        disabled: true, widget }).state, 'waiting_verification');
    assert.equal(widget.scrolls, 1);
    assert.equal(widget.clicks, 0, 'The app must never click the verification widget');
    // Later polls on the same document do not scroll again (the page keeps the flag).
    assert.equal(fill({ automatic: false, afterVerification: true, alreadyFilled: true, initial: saved,
        disabled: true, widget, shown: true }).state, 'waiting_verification');
    assert.equal(widget.scrolls, 1, 'Scroll only once per page');
    const hidden = { scrolls: 0, scrollIntoView() { this.scrolls++; } };
    fill({ automatic: true, disabled: true, widget: hidden });
    assert.equal(hidden.scrolls, 0, 'Hidden background login does not scroll');
}
for (const location of [
    { protocol: 'https:', hostname: 'evil.example', pathname: '/SSO/login' },
    { protocol: 'https:', hostname: 'ccsys1.niu.edu.tw.evil.example', pathname: '/SSO/login' },
    { protocol: 'http:', hostname: 'ccsys1.niu.edu.tw', pathname: '/SSO/login' },
    { protocol: 'https:', hostname: 'ccsys1.niu.edu.tw', pathname: '/SSO/dashboard' },
]) {
    assert.deepEqual(fill({ automatic: true, location }),
        { state: 'waiting', clicks: 0, writes: 0, username: 'user-edit' });
}
console.log('PASS: automatic submit, blocked verification, resume after verification, widget into view (no click), manual prefill, preserved user edits, no duplicate submit, no off-origin fill');
