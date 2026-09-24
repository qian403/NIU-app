// Run: node scripts/check-attendance-login.js
// Exercise the production M campus login DOM scripts without an account/network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../Features/Moodle/Views/MoodleWebView.swift'), 'utf8');
const captureSection = source.slice(source.indexOf('private func captureAttendanceCaptcha'));
const captureScript = captureSection.match(/let script = """\n([\s\S]*?)\n\s*"""/)[1];
const submitSection = source.slice(source.indexOf('private func submitAttendanceLogin'));
let submitScript = submitSection.match(/let script = """\n([\s\S]*?)\n\s*"""/)[1];
submitScript = submitScript
    .replaceAll('\\(username)', JSON.stringify('fixture-user'))
    .replaceAll('\\(password)', JSON.stringify('fixture-password'))
    .replaceAll('\\(captchaLiteral)', JSON.stringify('95895'));

const image = {
    complete: true,
    naturalWidth: 180,
    naturalHeight: 40,
};
const canvas = {
    width: 0,
    height: 0,
    getContext: () => ({ drawImage() {} }),
    toDataURL: () => 'data:image/png;base64,ZmFrZQ==',
};
const captchaInput = { value: '', focus() {}, dispatchEvent() {} };
const dom = {
    querySelector: selector => {
        if (selector.includes('#captcha')) return captchaInput;
        if (selector.includes('#imgcode')) return image;
        return null;
    },
    createElement: type => type === 'canvas' ? canvas : null,
};
const capturePayload = JSON.parse(vm.runInNewContext(captureScript, { document: dom }));
assert.equal(capturePayload.hasInput, true);
assert.equal(capturePayload.hasImage, true);
assert.equal(capturePayload.dataURL, 'data:image/png;base64,ZmFrZQ==');

let submitted = false;
const submitButton = { click() { submitted = true; } };
const form = {
    requestSubmit() { submitted = true; },
    querySelector: selector => selector.includes('button') ? submitButton : null,
};
const fields = {
    'form[action*="login/index.php"]': form,
    'form#login': form,
    'input[name="username"]': { value: '', focus() {}, dispatchEvent() {} },
    'input#username': { value: '', focus() {}, dispatchEvent() {} },
    'input[name="password"]': { value: '', focus() {}, dispatchEvent() {} },
    'input#password': { value: '', focus() {}, dispatchEvent() {} },
    '#captcha, input[name="captcha"]': captchaInput,
};
const submitDom = {
    querySelector: selector => {
        if (selector.includes('form[action*="login/index.php"]')) return form;
        if (selector.includes('form#login')) return form;
        if (selector.includes('input[name="username"]')) return fields['input[name="username"]'];
        if (selector.includes('input[name="password"]')) return fields['input[name="password"]'];
        if (selector.includes('#captcha')) return captchaInput;
        return fields[selector] ?? null;
    },
};
const result = vm.runInNewContext(submitScript, { document: submitDom, Event: class Event {} });
assert.equal(result, 'submitted');
assert.equal(submitted, true);
assert.equal(fields['input[name="username"]'].value, 'fixture-user');
assert.equal(fields['input[name="password"]'].value, 'fixture-password');
assert.equal(captchaInput.value, '95895');

console.log('PASS: M campus captcha extraction and credential/captcha submission scripts');
