// Exercise the production capture and submit scripts without accounts or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
    '../Features/Moodle/Views/MoodleWebView.swift'), 'utf8');
function scriptAfter(signature) {
    return source.slice(source.indexOf(signature)).match(/let script = """\n([\s\S]*?)\n\s*"""/)[1];
}
const capture = scriptAfter('private func captureAttendanceCaptcha');
const refresh = scriptAfter('private func refreshAttendanceCaptcha')
    .replace('\\(previousImage)', 'capturedImage');
const retry = scriptAfter('private func retryAttendanceLoginPage');
const submit = scriptAfter('private func submitAttendanceLogin')
    .replace('\\(username)', JSON.stringify('synthetic-student'))
    .replace('\\(password)', JSON.stringify('synthetic-password'))
    .replace('\\(captchaLiteral)', 'captchaCode')
    .replace('\\(imageLiteral)', 'capturedImage');

function page(options = {}) {
    let imageData = options.imageData ?? 'data:image/png;base64,fixture';
    const image = options.hasImage === false ? null
        : { complete: options.complete ?? true, naturalWidth: options.width ?? 180, naturalHeight: 40 };
    let refreshes = 0;
    if (image) {
        image.src = 'https://euni.niu.edu.tw/auth/posbosscaptcha/captcha.php';
        image.click = () => {
            refreshes += 1;
            if (options.clickError) throw new Error('Synthetic refresh failure');
            if (!options.noRefresh) image.src += '?t=synthetic';
        };
    }
    const input = options.hasInput === false ? null
        : { value: options.manualInput ?? '', focus() {}, dispatchEvent() {} };
    const field = () => ({ value: '', focus() {}, dispatchEvent() {} });
    const username = field();
    const password = field();
    let submissions = 0;
    const form = {
        method: options.method ?? 'post',
        enctype: options.enctype ?? 'application/x-www-form-urlencoded',
        action: 'https://euni.niu.edu.tw/login/index.php',
        checkValidity: () => options.valid ?? true,
        querySelector: () => ({}),
        requestSubmit: () => { submissions += 1; },
    };
    if (options.refreshOnInput && input) {
        input.dispatchEvent = () => { imageData = 'data:image/png;base64,replacement'; };
    }
    const context = {
        location: options.location ?? {
            protocol: 'https:', hostname: 'euni.niu.edu.tw', port: '', pathname: '/login/index.php',
        },
        captchaCode: options.captchaCode === undefined ? '12345' : options.captchaCode,
        capturedImage: options.capturedImage ?? 'data:image/png;base64,fixture',
        Event: class {},
        FormData: class extends Array {
            constructor() {
                super();
                this.push(['username', username.value], ['password', password.value],
                    ['logintoken', 'synthetic-csrf']);
                if (input) this.push(['captcha', input.value]);
            }
            append(name, value) { this.push([name, value]); }
        },
        URLSearchParams,
        document: {
            querySelector: selector => {
                if (selector.includes('imgcode')) return image;
                if (selector.includes('#captcha')) return input;
                if (selector.includes('username')) return username;
                if (selector.includes('password')) return password;
                if (selector.includes('form')) return options.hasForm === false ? null : form;
                throw new Error(`Unexpected selector: ${selector}`);
            },
            createElement: () => ({
                getContext: () => options.noContext ? null : {
                    drawImage() {
                        if (options.canvasError) throw new Error('Synthetic canvas failure');
                    },
                },
                toDataURL: () => imageData,
            }),
        },
    };
    return { context, input, username, password, refreshes: () => refreshes, submissions: () => submissions };
}

for (const options of [
    { hasImage: false }, { complete: false }, { width: 0 }, { noContext: true }, { canvasError: true },
]) {
    const fixture = page(options);
    assert.equal(JSON.parse(vm.runInNewContext(capture, fixture.context)).dataURL, null);
}
const captured = JSON.parse(vm.runInNewContext(capture, page().context));
assert.equal(captured.dataURL, 'data:image/png;base64,fixture');
assert.equal(captured.hasInput, true);
assert.equal(captured.hasImage, true);
assert.equal(captured.complete, true);
assert.equal(captured.width, 180);

for (const options of [
    { imageData: 'data:image/png;base64,replacement' },
    { complete: false }, { width: 0 }, { hasImage: false },
    { noContext: true }, { canvasError: true }, { refreshOnInput: true },
]) {
    const fixture = page(options);
    assert.equal(vm.runInNewContext(submit, fixture.context), 'stale-captcha');
    assert.equal(fixture.submissions(), 0, 'Changed or unreadable image must never submit');
}
const manual = page({ manualInput: '54321' });
assert.equal(vm.runInNewContext(submit, manual.context), 'manual-input');
assert.equal(manual.input.value, '54321');
assert.equal(manual.username.value, '');
assert.equal(manual.submissions(), 0);

const valid = page();
const prepared = JSON.parse(vm.runInNewContext(submit, valid.context));
assert.equal(prepared.status, 'ready');
assert.equal(prepared.action, 'https://euni.niu.edu.tw/login/index.php');
const fields = new URLSearchParams(prepared.body);
assert.equal(fields.get('logintoken'), 'synthetic-csrf');
assert.equal(fields.get('captcha'), '12345');
assert.equal(fields.get('username'), 'synthetic-student');
assert.equal(fields.get('password'), 'synthetic-password');
assert.equal(valid.username.value, 'synthetic-student');
assert.equal(valid.password.value, 'synthetic-password');
assert.equal(valid.input.value, '12345');
assert.equal(valid.submissions(), 0, 'Queued JavaScript must never submit; native code validates the generation');
const noCaptcha = page({ hasInput: false, hasImage: false, captchaCode: null });
assert.equal(JSON.parse(vm.runInNewContext(submit, noCaptcha.context)).status, 'ready');
const lateCaptcha = page({ captchaCode: null });
assert.equal(vm.runInNewContext(submit, lateCaptcha.context), 'missing-form');
assert.equal(lateCaptcha.submissions(), 0);
const missingForm = page({ hasForm: false });
assert.equal(vm.runInNewContext(submit, missingForm.context), 'missing-form');
assert.equal(missingForm.submissions(), 0);
for (const options of [{ method: 'get' }, { enctype: 'multipart/form-data' }, { valid: false }]) {
    const fixture = page(options);
    assert.equal(vm.runInNewContext(submit, fixture.context), 'unsupported-form');
    assert.equal(fixture.submissions(), 0);
}
for (const location of [
    { protocol: 'https:', hostname: 'evil.example', port: '', pathname: '/login' },
    { protocol: 'https:', hostname: 'euni.niu.edu.tw.evil.example', port: '', pathname: '/login/index.php' },
    { protocol: 'http:', hostname: 'euni.niu.edu.tw', port: '', pathname: '/login/index.php' },
    { protocol: 'https:', hostname: 'euni.niu.edu.tw', port: '8443', pathname: '/login/index.php' },
    { protocol: 'https:', hostname: 'euni.niu.edu.tw', port: '', pathname: '/my/' },
]) {
    const foreign = page({ location });
    assert.equal(vm.runInNewContext(submit, foreign.context), 'untrusted-origin');
    assert.equal(foreign.username.value, '', 'Credentials must never be written off-origin');
    assert.equal(foreign.password.value, '');
    assert.equal(foreign.submissions(), 0);
}
assert.equal(vm.runInNewContext(retry, page({ manualInput: '123' }).context), true);
assert.equal(vm.runInNewContext(retry, page().context), false);
console.log('PASS: capture readiness, stale images, manual input before submission/retry, form preparation without JS submission, no off-origin fill');

const refreshable = page();
assert.equal(vm.runInNewContext(refresh, refreshable.context), 'refreshed');
assert.equal(refreshable.refreshes(), 1);
assert.equal(refreshable.submissions(), 0);
for (const options of [{ imageData: 'data:image/png;base64,new' }, { complete: false }]) {
    const changed = page(options);
    assert.equal(vm.runInNewContext(refresh, changed.context), 'changed');
    assert.equal(changed.refreshes(), 0, 'Do not replace a user-requested image again');
}
for (const options of [{ manualInput: '12' },
    { location: { protocol: 'https:', hostname: 'evil.example', port: '', pathname: '/login/' } }]) {
    const manual = page(options);
    assert.equal(vm.runInNewContext(refresh, manual.context), 'manual');
    assert.equal(manual.refreshes(), 0);
}
for (const options of [{ hasInput: false }, { hasImage: false }, { width: 0 },
    { noContext: true }, { canvasError: true }, { noRefresh: true }, { clickError: true }]) {
    assert.equal(vm.runInNewContext(refresh, page(options).context), 'unavailable');
}
console.log('PASS: image-only click refresh, existing user refresh, manual input, trusted origin and unavailable handler');
