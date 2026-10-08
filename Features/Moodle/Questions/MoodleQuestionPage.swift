import Foundation

struct MoodleQuestionPage: Decodable, Equatable {
    struct Option: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let disabled: Bool
        /// Placeholder entries such as「選擇...」; choosing one clears the answer.
        var blank: Bool? = nil
    }
    struct Field: Decodable, Equatable, Identifiable {
        let id: String
        let kind: String
        let label: String
        let values: [String]
        let options: [Option]
        let required: Bool
        let disabled: Bool
        /// Question sentence shown once before blanks, stems or drop places.
        var context: String? = nil
        /// The quiz question (`questions[].id`) this field answers.
        var questionID: String? = nil
        /// Sub-label inside a question, e.g. a matching stem or「空格 1」.
        var part: String? = nil
    }
    struct Action: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let disabled: Bool
        let fieldIDs: [String]
        var isNavigation: Bool? = nil
        /// start, next, previous, finish, submit, resume, confirm, cancel, review or done.
        var role: String? = nil
    }

    /// One bubble of Moodle's quiz navigation (answer card), across all pages.
    struct NavigationItem: Decodable, Equatable, Identifiable {
        let id: String
        let number: String
        /// answered, unanswered, invalid or other.
        let state: String
        let status: String
        let flagged: Bool
        let current: Bool
    }

    struct Question: Decodable, Equatable, Identifiable {
        let id: String
        let number: String
        let text: String
        let state: String
    }

    struct ReviewQuestion: Decodable, Equatable, Identifiable {
        struct Choice: Decodable, Equatable, Identifiable {
            let id: String
            let text: String
            let selected: Bool
            let verdict: String?
            let feedback: String
        }
        let id: String
        let title: String
        let text: String
        let prompt: String
        let status: String
        let verdict: String?
        let mark: String
        let choices: [Choice]
        let responses: [String]
        let correctAnswer: String
        let feedback: String
        let generalFeedback: String
        let comment: String
        let webReason: String?
    }

    struct ResultSummary: Decodable, Equatable {
        struct Detail: Decodable, Equatable, Identifiable {
            let id: String
            let label: String
            let value: String
        }
        struct Attempt: Decodable, Equatable, Identifiable {
            let id: String
            let title: String
            let details: [Detail]
        }
        let grade: String?
        let gradeLabel: String?
        let information: [Detail]
        let attempts: [Attempt]
        let notices: [String]
    }

    let revision: String
    let title: String
    let text: String
    let fields: [Field]
    let actions: [Action]
    let webReason: String?
    /// Visible countdown; drafts are written to the school form as they change.
    var timer: String? = nil
    var timerSeconds: Int? = nil
    /// overview, attempt, summary, confirm, review or activity.
    var stage: String? = nil
    var navigation: [NavigationItem]? = nil
    var questions: [Question]? = nil
    var result: ResultSummary? = nil
    var reviewQuestions: [ReviewQuestion]? = nil
}

enum MoodleQuestionPageScript {
    // All actions resolve to live DOM elements. No endpoint, hidden token or
    // form payload is reconstructed or persisted by the native interface.
    static let install = #"""
    (() => {
        if (window.__niuQuestionsV1) return;
        const ids = new WeakMap();
        let nextID = 0;
        const documentID = Math.random().toString(36).slice(2);
        let controls = new Map(), actions = new Map(), navTargets = new Map();
        const key = element => {
            if (!ids.has(element)) ids.set(element, 'n' + (++nextID));
            return ids.get(element);
        };
        const clean = value => (value || '').replace(/\s+/g, ' ').trim();
        const visible = element => {
            if (!element || !element.isConnected) return false;
            const style = getComputedStyle(element);
            return !element.closest('[hidden], [aria-hidden="true"]') &&
                style.display !== 'none' && style.visibility !== 'hidden' &&
                element.getClientRects().length > 0;
        };
        const labelledBy = element => (element.getAttribute('aria-labelledby') || '').split(/\s+/)
            .map(id => id && document.getElementById(id)?.textContent).filter(Boolean).join(' ');
        const label = element => clean(
            element.getAttribute('aria-label') ||
            labelledBy(element) ||
            Array.from(element.labels || []).map(l => l.textContent).join(' ') ||
            element.closest('label')?.textContent ||
            element.getAttribute('placeholder') || ''
        );
        const disabled = element => element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true';
        // Quiz answers sit inside an inner fieldset whose legend is only "Select one".
        const contextLabel = element => {
            const group = element.closest('.que') || element.closest('fieldset, [role="group"], .fitem');
            const text = clean(group?.querySelector('.qtext, legend, .col-form-label, .fitemtitle')?.textContent);
            const number = group?.matches('.que') ? clean(group.querySelector('.info .no')?.textContent) : '';
            return number && text ? number + '：' + text : text;
        };
        // Question flags and "clear my choice" are school page chrome, not answers.
        const quizChrome = element => !!element.closest('.que .info, .questionflag, .qtype_multichoice_clearchoice');
        const safeURL = href => {
            try {
                const url = new URL(href, document.baseURI);
                return url.protocol === 'https:' && url.hostname === 'euni.niu.edu.tw' &&
                    (!url.port || url.port === '443') && !url.username && !url.password &&
                    /^\/mod\/(quiz|irs|choice|feedback|questionnaire|survey)\/(view|attempt|summary|review|complete)\.php$/.test(url.pathname) &&
                    !Array.from(url.searchParams.keys()).some(k => /delete|sesskey|confirm|submit|finish/i.test(k));
            } catch { return false; }
        };
        const safeForm = form => {
            try {
                const target = new URL(form.action || location.href, document.baseURI);
                return target.protocol === 'https:' && target.hostname === 'euni.niu.edu.tw' &&
                    (!target.port || target.port === '443') && !target.username && !target.password &&
                    /^\/mod\/(quiz|irs|choice|feedback|questionnaire|survey)\//.test(target.pathname);
            } catch { return false; }
        };
        const reviewText = element => {
            if (!element || !visible(element)) return '';
            const copy = element.cloneNode(true);
            const originals = Array.from(element.querySelectorAll('*'));
            const copies = Array.from(copy.querySelectorAll('*'));
            originals.forEach((node, i) => {
                if (!visible(node)) copies[i].remove();
            });
            copy.querySelectorAll('script, style, input, textarea, select, button, .accesshide, .sr-only, .visually-hidden, [aria-hidden="true"]').forEach(e => e.remove());
            copy.querySelectorAll('p, div, li, br, pre').forEach(e => e.appendChild(document.createTextNode('\n')));
            return (copy.textContent || '').split('\n').map(clean).filter(Boolean).join('\n');
        };
        const verdict = element => {
            if (!element) return null;
            return ['correct', 'partiallycorrect', 'incorrect'].find(value => element.classList.contains(value)) || null;
        };
        const reviewQuestions = root => Array.from(root.querySelectorAll('.que')).filter(visible).map((question, index) => {
            const read = selector => reviewText(question.querySelector(selector));
            const supported = ['multichoice', 'truefalse', 'shortanswer', 'numerical', 'essay', 'description']
                .some(type => question.classList.contains(type));
            let webReason = supported ? null : '此題包含特殊題型，請查看校方完整內容。';
            if (Array.from(question.querySelectorAll(
                'img:not(.icon), svg, math, .MathJax, .MathJax_Display, .filter_mathjaxloader, iframe, canvas, audio, video, object, embed, table, .attachments, a[href]'
            )).some(e => visible(e) && !e.closest('.info, .questionflag, .history'))) {
                webReason = '此題含圖片、公式、表格或附件，請搭配校方完整內容閱讀。';
            }
            const choices = Array.from(question.querySelectorAll('.answer input[type="radio"], .answer input[type="checkbox"]'))
                .filter(visible).map(input => {
                    const row = input.closest('.r0, .r1') || input.parentElement;
                    const labels = (input.getAttribute('aria-labelledby') || '').split(/\s+/)
                        .map(id => document.getElementById(id)).filter(e => e && question.contains(e));
                    const text = labels.map(reviewText).filter(Boolean).join('\n') ||
                        Array.from(input.labels || []).map(reviewText).filter(Boolean).join('\n') ||
                        reviewText(row.querySelector('[data-region="answer-label"]'));
                    if (!text) webReason ||= '此題選項無法完整呈現，請查看校方完整內容。';
                    return {id: key(input), text, selected: input.checked,
                        verdict: verdict(row), feedback: reviewText(row.querySelector('.specificfeedback'))};
                });
            const responses = Array.from(question.querySelectorAll(
                '.answer input:not([type="hidden"]):not([type="radio"]):not([type="checkbox"]), .answer textarea, .qtype_essay_response'
            )).filter(visible).map(e => e.matches('input, textarea') ? e.value : reviewText(e));
            // Short-answer inputs may be placed directly in the formulation.
            if (!responses.length && (question.classList.contains('shortanswer') || question.classList.contains('numerical'))) {
                responses.push(...Array.from(question.querySelectorAll('.formulation input[type="text"], .formulation input[type="number"]'))
                    .filter(visible).map(e => e.value));
            }
            const responseText = question.querySelector('.answer');
            if (!choices.length && !responses.length && responseText && supported && !question.classList.contains('description')) {
                const text = reviewText(responseText);
                if (text) responses.push(text);
            }
            if (question.querySelector('.answer select, .formulation [contenteditable="true"]')) {
                webReason ||= '此題的作答格式需查看校方完整內容。';
            }
            const feedback = Array.from(question.querySelectorAll('.specificfeedback'))
                .filter(e => !e.closest('.answer')).map(reviewText).filter(Boolean).join('\n');
            return {id: key(question), title: read('.info .no') || '題目 ' + (index + 1),
                text: read('.qtext'), prompt: read('.prompt'), status: read('.info .state'),
                verdict: verdict(question), mark: read('.info .grade'),
                choices, responses, correctAnswer: read('.rightanswer'), feedback,
                generalFeedback: read('.generalfeedback'), comment: read('.comment'),
                webReason};
        });
        const resultSummary = (root, currentURL) => {
            if (!/\/mod\/quiz\/(view|review)\.php(?:[?#]|$)/.test(currentURL)) return null;
            const tables = Array.from(root.querySelectorAll('table.quizreviewsummary, table.quizattemptsummary')).filter(visible);
            if (!tables.length) return null;
            const consumed = new Set();
            const content = element => {
                const copy = element.cloneNode(true);
                copy.querySelectorAll('script, style, .sr-only, .accesshide, [hidden]').forEach(e => e.remove());
                return clean(copy.textContent);
            };
            const detail = (element, label, value) => ({id: key(element), label: clean(label).replace(/[：:]\s*$/, ''), value});
            const attempts = [];
            for (const table of tables) {
                const previousCount = attempts.length;
                if (table.classList.contains('quizattemptsummary')) {
                    const headers = Array.from(table.querySelectorAll('thead th')).map(content);
                    for (const row of table.querySelectorAll('tbody tr')) {
                        const cells = Array.from(row.cells);
                        const details = cells.map((cell, i) => detail(cell, headers[i] || '紀錄', content(cell)))
                            .filter(d => d.value);
                        if (details.length) attempts.push({id: key(row), title: '作答紀錄 ' + (attempts.length + 1), details});
                    }
                } else {
                    const details = Array.from(table.querySelectorAll('tbody tr')).flatMap(row => {
                        const heading = row.querySelector('th'), value = row.querySelector('td');
                        return heading && value && content(heading) && content(value)
                            ? [detail(row, content(heading), content(value))] : [];
                    });
                    const cardTitle = table.closest('.card')?.querySelector('.card-title');
                    if (details.length) attempts.push({
                        id: key(table), title: cardTitle ? content(cardTitle) : '作答紀錄 ' + (attempts.length + 1), details
                    });
                    if (cardTitle) consumed.add(cardTitle);
                }
                // Unknown/empty markup must remain available in the source notes.
                if (attempts.length > previousCount) consumed.add(table);
            }
            if (!attempts.length) return null;
            const pageHeading = root.querySelector('h1, h2');
            if (pageHeading && !pageHeading.closest('.que')) consumed.add(pageHeading);
            const information = [], notices = [];
            const addNotice = text => { if (text && !notices.includes(text)) notices.push(text); };
            for (const element of root.querySelectorAll('.activity-dates strong, [data-region="activity-dates"] strong')) {
                const row = element.parentElement;
                const label = content(element);
                const value = content(row).slice(label.length).trim();
                if (value) { information.push(detail(row, label, value)); consumed.add(row); }
            }
            for (const element of root.querySelectorAll('.quizinfo p, .quizattempt p, .quizattempt .quizattemptremaining')) {
                if (!visible(element)) continue;
                const text = content(element);
                const pair = text.match(/^([^：:]{1,60})[：:]\s*(.+)$/);
                if (pair) information.push(detail(element, pair[1], pair[2]));
                else addNotice(text);
                consumed.add(element);
            }
            let grade = null, gradeLabel = null;
            for (const heading of root.querySelectorAll('#feedback h2, #feedback h3, #feedback h4')) {
                const text = content(heading);
                const final = text.match(/^(?:.*?最後成績(?:是|為)?\s*[：:]?\s*|Your final grade (?:for this quiz )?is\s*)(.+)$/i);
                if (final) {
                    grade = final[1]; gradeLabel = '最後成績'; consumed.add(heading); break;
                }
                const best = text.match(/^(最高分數|平均分數|第一次作答|最後一次作答|Highest grade|Average grade)[：:]\s*(.+?)[。.]?$/i);
                if (best) {
                    grade = best[2]; gradeLabel = best[1]; consumed.add(heading); break;
                }
                if (/成績|grade/i.test(text)) {
                    grade = text; gradeLabel = '目前成績'; consumed.add(heading); break;
                }
            }
            for (const heading of root.querySelectorAll('h2, h3')) {
                if (/^([您你]的作答[紀記]錄|Summary of your previous attempts|Summary of attempts)$/i.test(content(heading))) {
                    consumed.add(heading);
                }
            }
            return {summary: {grade, gradeLabel, information, attempts, notices}, consumed};
        };
        // Inline blanks are shown as numbered markers in the question sentence.
        const blankContext = (container, blanks) => {
            if (!container) return '';
            const copy = container.cloneNode(true);
            const originals = Array.from(container.querySelectorAll('*'));
            const copies = Array.from(copy.querySelectorAll('*'));
            blanks.forEach((blank, i) => {
                const at = originals.indexOf(blank);
                if (at >= 0) copies[at].replaceWith(' ［' + (i + 1) + '］ ');
            });
            originals.forEach((node, i) => { if (!visible(node) && copy.contains(copies[i])) copies[i].remove(); });
            copy.querySelectorAll('script, style, input, textarea, select, button, label, .accesshide, .sr-only, .visually-hidden, .draghome, .feedbacktrigger, .validationerror, .ablock, .answer').forEach(e => e.remove());
            copy.querySelectorAll('p, div, li, br, tr').forEach(e => e.appendChild(document.createTextNode('\n')));
            return (copy.textContent || '').split('\n').map(clean).filter(Boolean).join('\n');
        };
        const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
        // Drag-and-drop text questions are driven through Moodle's own keyboard support,
        // so the school page and its hidden response fields stay consistent.
        const pressKey = (element, keyCode, name) => {
            const event = new KeyboardEvent('keydown', {key: name, bubbles: true, cancelable: true});
            Object.defineProperty(event, 'keyCode', {get: () => keyCode});
            Object.defineProperty(event, 'which', {get: () => keyCode});
            element.dispatchEvent(event);
        };
        const dragSettled = async () => {
            const deadline = Date.now() + 3000;
            do { await wait(60); } while (Date.now() < deadline &&
                (window.M?.util?.pending_js || []).some(id => /^qtype_ddwtos-animate/.test(String(id))));
            return Date.now() < deadline;
        };
        const ddwtosControls = (question, prefix, context) => {
            const readOnly = question.classList.contains('qtype_ddwtos-readonly');
            const drops = Array.from(question.querySelectorAll('.qtext span.drop'));
            return drops.flatMap((drop, index) => {
                const place = (drop.className.match(/\bplace(\d+)\b/) || [])[1];
                const group = (drop.className.match(/\bgroup(\d+)\b/) || [])[1];
                const input = place && question.querySelector('input.placeinput.place' + place);
                if (!input || !group) return [];
                const choices = new Map();
                for (const home of question.querySelectorAll('.draghome.group' + group)) {
                    const choice = (home.className.match(/\bchoice(\d+)\b/) || [])[1];
                    if (choice && !choices.has(choice)) choices.set(choice, home);
                }
                const id = key(drop);
                const options = Array.from(choices, ([choice, home]) => ({id: id + ':' + choice,
                    label: clean(home.textContent) || '選項 ' + choice, disabled: false,
                    choice, infinite: home.classList.contains('infinite')}));
                const value = String(input.value || '0');
                const field = {id, kind: 'single', label: prefix + '空格 ' + (index + 1),
                    values: options.filter(o => o.choice === value).map(o => o.id),
                    options: options.map(({id, label, disabled}) => ({id, label, disabled})),
                    required: false, disabled: readOnly, context: index === 0 ? context : null};
                return [{element: drop, group: [drop], options: [], field, custom: {
                    kind: 'ddwtos', question, drop, input, place, choices: options,
                    target: values => values.length ? options.find(o => o.id === values[0]).choice : '0',
                    validate: values => values.length > 1 || values.some(v => !options.some(o => o.id === v)) ? 'changed' : null
                }}];
            });
        };
        // A non-infinite word may only be in one place in the final answer.
        const dragTextProblem = staged => {
            const byQuestion = new Map();
            for (const {control, values} of staged) {
                if (!byQuestion.has(control.custom.question)) byQuestion.set(control.custom.question, []);
                byQuestion.get(control.custom.question).push({control, target: control.custom.target(values)});
            }
            for (const [question, changes] of byQuestion) {
                const final = new Map();
                for (const input of question.querySelectorAll('input.placeinput')) {
                    const place = (input.className.match(/\bplace(\d+)\b/) || [])[1];
                    const group = (input.className.match(/\bgroup(\d+)\b/) || [])[1];
                    if (place && !final.has(place)) final.set(place, [group, String(input.value || '0')]);
                }
                for (const {control, target} of changes) final.set(control.custom.place, [final.get(control.custom.place)?.[0], target]);
                const used = new Set();
                for (const [group, choice] of final.values()) {
                    if (choice === '0') continue;
                    const home = question.querySelector('.draghome.group' + group + '.choice' + choice);
                    if (home?.classList.contains('infinite')) continue;
                    if (used.has(group + ':' + choice)) return 'invalid';
                    used.add(group + ':' + choice);
                }
            }
            return null;
        };
        const applyDragText = async staged => {
            const pending = staged.map(({control, values}) => ({custom: control.custom, target: control.custom.target(values)}))
                .filter(({custom, target}) => String(custom.input.value || '0') !== target);
            // Empty changed places first, so every requested word is available.
            for (const {custom} of pending) {
                if (String(custom.input.value || '0') === '0') continue;
                pressKey(custom.drop, 27, 'Escape');
                if (!await dragSettled()) return 'changed';
            }
            for (const {custom, target} of pending) {
                for (let step = 0; target !== '0' && String(custom.input.value || '0') !== target; step++) {
                    if (step > custom.choices.length + 1 || !custom.drop.isConnected) return 'changed';
                    pressKey(custom.drop, 39, 'ArrowRight');
                    if (!await dragSettled()) return 'changed';
                }
            }
            return null;
        };
        const orderingControl = (question, prefix, context) => {
            const list = question.querySelector('ul.sortablelist');
            if (!list) return [];
            const items = () => Array.from(list.querySelectorAll('li.sortableitem'));
            const current = items();
            if (!current.length) return [];
            const itemLabel = item => clean((item.querySelector('[data-itemcontent]') || item).textContent) || '項目';
            const field = {id: key(list), kind: 'order', label: prefix + '排序', values: current.map(key),
                options: current.map(item => ({id: key(item), label: itemLabel(item), disabled: false})),
                required: false, disabled: !list.classList.contains('active'), context};
            return [{element: list, group: [list], options: [], field, custom: {
                kind: 'ordering',
                validate: values => values.length !== current.length || new Set(values).size !== values.length ||
                    values.some(v => !current.some(item => key(item) === v)) ? 'changed' : null,
                // Moodle's move buttons update its hidden response field synchronously.
                apply: values => {
                    for (let i = 0; i < values.length; i++) {
                        const item = items().find(e => key(e) === values[i]);
                        for (let guard = 0; item && items().indexOf(item) > i; guard++) {
                            const button = Array.from(item.querySelectorAll('[data-action="move-backward"]')).find(visible);
                            if (!button || guard > values.length) return 'changed';
                            button.click();
                        }
                    }
                    return items().map(key).join() === values.join() ? null : 'changed';
                }
            }}];
        };
        const escapeHTML = text => text.replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);
        const editorControl = (question, textarea, prefix, context) => {
            const editor = textarea.id && window.tinyMCE?.get?.(textarea.id);
            if (!editor || !editor.initialized) return null;
            const html = editor.getContent();
            // Only plain paragraphs can round-trip through a native text editor.
            if (/<(?!\/?(?:p|br)\b)[a-z]/i.test(html)) return {richContent: true};
            const text = editor.getContent({format: 'text'}).replace(/\u00a0/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
            const field = {id: key(textarea), kind: 'longText', label: prefix + (context ? '作答' : '申論作答'),
                values: [text], options: [], required: false,
                disabled: editor.mode?.isReadOnly?.() || textarea.disabled || textarea.readOnly, context};
            return {element: textarea, group: [textarea], options: [], field, custom: {
                kind: 'editor',
                validate: values => values.length > 1 ? 'changed' : null,
                apply: values => {
                    const value = (values[0] || '').replace(/\r\n?/g, '\n').trim();
                    if (value === text) return null;
                    editor.setContent(value.split(/\n{2,}/).map(p => '<p>' + escapeHTML(p).replace(/\n/g, '<br>') + '</p>').join(''));
                    editor.save();
                    return null;
                }
            }};
        };
        const snapshot = () => {
            controls = new Map(); actions = new Map();
            const modal = Array.from(document.querySelectorAll('[role="dialog"], .modal.show, .moodle-dialogue')).find(visible);
            const root = modal || document.querySelector('#region-main, main[role="main"], main');
            const currentURL = location.href === 'about:blank' ? document.baseURI : location.href;
            const modulePath = /^https:\/\/euni\.niu\.edu\.tw(?::443)?\/mod\/(quiz|irs|choice|feedback|questionnaire|survey)\//;
            if (!root || !modulePath.test(currentURL)) {
                return {revision: documentID, title: '', text: '', fields: [], actions: [],
                        webReason: '需要在校方頁面完成登入或開啟此活動。'};
            }
            const result = modal ? null : resultSummary(root, currentURL);
            const isReview = !modal && /\/mod\/quiz\/review\.php(?:[?#]|$)/.test(currentURL);
            const questions = isReview ? reviewQuestions(root) : null;
            let webReason = null;
            // Timed activities may submit independently of native button taps, so the
            // native screen stages every change into the school DOM (see stage()).
            // Moodle always renders a hidden quiz timer, so only a visible running one counts.
            const timerElement = Array.from(document.querySelectorAll(
                '[role="timer"], [id*="timer" i], [class*="timer" i], [id*="countdown" i], [class*="countdown" i]'
            )).find(element => visible(element) && /\d/.test(element.textContent || ''));
            const timer = timerElement ? clean(timerElement.textContent).replace(/\s*隱藏$/, '') : null;
            const timeLeft = timer && timer.match(/(?:(\d+):)?(\d+):(\d{2})\s*$/);
            const timerSeconds = timeLeft ? (+(timeLeft[1] || 0)) * 3600 + (+timeLeft[2]) * 60 + (+timeLeft[3]) : null;
            const quizPage = modal ? null : (currentURL.match(/\/mod\/quiz\/(view|attempt|summary|review)\.php/) || [])[1];
            const stage = modal ? 'confirm' : ({view: 'overview', attempt: 'attempt', summary: 'summary', review: 'review'})[quizPage] || 'activity';
            // Composite questions: blanks, matching stems, drag places, ordering and essays.
            const overrides = new Map(), customControls = [], editorQuestions = new Set();
            const contextQuestions = new Set();
            for (const question of isReview || modal ? [] : Array.from(root.querySelectorAll('.que')).filter(visible)) {
                const number = clean(question.querySelector('.info .no')?.textContent);
                const prefix = number ? number + '：' : '';
                const textRoot = question.querySelector('.qtext') || question.querySelector('.formulation');
                if (question.matches('.gapselect, .multianswer')) {
                    const blanks = Array.from(textRoot?.querySelectorAll('select, input[type="text"], input:not([type])') || []).filter(visible);
                    const context = blankContext(textRoot, blanks);
                    blanks.forEach((blank, i) => overrides.set(blank, {label: prefix + '空格 ' + (i + 1), context: i === 0 ? context : null}));
                    if (blanks.length) contextQuestions.add(question);
                } else if (question.matches('.match')) {
                    const rows = Array.from(question.querySelectorAll('table.answer tr')).filter(row => row.querySelector('select'));
                    const context = blankContext(question.querySelector('.qtext'), []);
                    rows.forEach((row, i) => overrides.set(row.querySelector('select'), {
                        label: prefix + (blankContext(row.querySelector('td.text'), []).replace(/\n/g, ' ') || '配對 ' + (i + 1)),
                        context: i === 0 ? context : null}));
                    if (rows.length) contextQuestions.add(question);
                } else if (question.matches('.ddwtos')) {
                    const drops = Array.from(question.querySelectorAll('.qtext span.drop'));
                    customControls.push(...ddwtosControls(question, prefix, blankContext(textRoot, drops)));
                    contextQuestions.add(question);
                } else if (question.matches('.ordering')) {
                    customControls.push(...orderingControl(question, prefix, blankContext(textRoot, [])));
                    contextQuestions.add(question);
                } else if (question.matches('.essay')) {
                    // Moodle renders an empty attachments container when uploads are off.
                    if (Array.from(question.querySelectorAll('.filemanager, input[type="file"], .attachments > *')).some(visible)) {
                        webReason ||= '此題需要上傳附件，請使用校方頁面作答。';
                    }
                    const context = blankContext(question.querySelector('.qtext'), []);
                    for (const textarea of question.querySelectorAll('.answer textarea, .qtype_essay_editor textarea')) {
                        if (visible(textarea)) { overrides.set(textarea, {label: prefix + '申論作答', context}); contextQuestions.add(question); continue; }
                        const control = editorControl(question, textarea, prefix, context);
                        if (control?.richContent) webReason ||= '此題已有格式化內容，請使用校方編輯器以免格式遺失。';
                        else if (control) { customControls.push(control); editorQuestions.add(question); contextQuestions.add(question); }
                        else if (question.querySelector('.tox')) webReason ||= '編輯器仍在載入，請稍候或使用校方頁面。';
                    }
                }
            }
            const unsupported = root.querySelectorAll(
                'input[type="password"], input[type="file"], [contenteditable="true"], iframe, canvas, audio, video, math, .MathJax, .MathJax_Display, img'
            );
            if (Array.from(unsupported).some(el => visible(el) && !(isReview && el.closest('.que')) && !quizChrome(el) &&
                !(el.closest('.tox') && editorQuestions.has(el.closest('.que'))) &&
                !(el.tagName === 'IMG' && (el.classList.contains('icon') || el.closest('.userpicture'))))) {
                webReason = '此頁包含圖片、公式、上傳或特殊互動，請使用校方頁面，避免遺漏題目內容。';
            }
            // Image drag-and-drop positions only make sense on the picture itself.
            if (!isReview && Array.from(root.querySelectorAll('.que.ddimageortext, .que.ddmarker')).some(visible)) {
                webReason ||= '此題需要在圖片上拖放，請使用校方頁面作答。';
            }
            const customElements = new Set(customControls.map(c => c.element));
            // The footer「跳至...」select navigates to another activity on change; it is not an answer.
            const allInputs = Array.from(root.querySelectorAll('input, textarea, select'))
                .filter(e => !(isReview && e.closest('.que')) && !quizChrome(e) && !customElements.has(e) &&
                    !e.closest('.activity-navigation, .urlselect, form[action*="/course/jumpto.php"]'));
            if (allInputs.some(element => element.type !== 'hidden' && !disabled(element) &&
                !visible(element) && Array.from(element.labels || []).some(visible))) {
                webReason ||= '此頁使用特殊選項控制項，請使用校方頁面完成作答。';
            }
            const elements = allInputs.filter(visible);
            const fields = [], groups = new Map();
            for (const element of elements) {
                const type = (element.type || '').toLowerCase();
                if (['hidden', 'submit', 'button', 'reset', 'image'].includes(type)) continue;
                if (!['radio', 'checkbox', 'text', 'number', 'email', 'url', 'tel', 'search', 'textarea', 'select-one', 'select-multiple'].includes(type)) {
                    webReason ||= '此題的輸入方式尚需使用校方頁面。';
                    continue;
                }
                const isChoice = type === 'radio' || type === 'checkbox';
                const answerGroup = type === 'checkbox' ? element.closest('.que .answer') : null;
                const groupID = answerGroup ? key(answerGroup) + ':checkbox' :
                    isChoice && element.name ? key(element.form || root) + ':' + type + ':' + element.name : key(element);
                if (groups.has(groupID)) { groups.get(groupID).push(element); continue; }
                groups.set(groupID, [element]);
            }
            const fieldOrder = [...groups.values(), ...customControls.map(c => c.element)]
                .sort((a, b) => ((Array.isArray(a) ? a[0] : a).compareDocumentPosition(Array.isArray(b) ? b[0] : b) &
                    Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1);
            for (const entry of fieldOrder) {
                if (!Array.isArray(entry)) {
                    const control = customControls.find(c => c.element === entry);
                    fields.push(control.field);
                    controls.set(control.field.id, control);
                    continue;
                }
                const group = entry;
                const element = group[0], type = element.type;
                const override = overrides.get(element);
                const id = key(element);
                const isChoice = type === 'radio' || type === 'checkbox';
                const options = isChoice ? group : element.tagName === 'SELECT' ? Array.from(element.options) : [];
                const field = {
                    id,
                    kind: type === 'radio' || type === 'select-one' ? 'single' :
                        type === 'checkbox' || type === 'select-multiple' ? 'multiple' :
                        type === 'textarea' ? 'longText' : 'text',
                    label: override?.label || (isChoice ? contextLabel(element) :
                        element.closest('.que') ? contextLabel(element) || label(element) :
                        label(element) || contextLabel(element)) || '作答',
                    values: options.length ? options.filter(o => o.selected || o.checked).map(key) : [element.value || ''],
                    options: options.map(o => ({id: key(o), label: label(o) || clean(o.textContent) || o.value || '選項',
                        blank: o.tagName === 'OPTION' && (o.value === '' || /^(選擇\.\.\.|請選擇|Choose\.\.\.)$/i.test(clean(o.textContent))),
                        disabled: disabled(o)})),
                    required: group.some(e => e.required),
                    disabled: group.every(e => disabled(e) || e.readOnly),
                    context: override?.context || null
                };
                fields.push(field);
                controls.set(id, {element, group, options, field});
            }
            const buttons = Array.from(root.querySelectorAll('button, input[type="submit"], input[type="button"], a[href]'));
            const actionList = [];
            for (const element of buttons) {
                if (!visible(element) || element.type === 'reset') continue;
                // Modal close icons duplicate「取消」; summary question links become the answer card.
                if (modal && element.matches('.btn-close, .close, .closebutton, [data-action="hide"]')) continue;
                if (element.closest('table.quizsummaryofattempt')) continue;
                if (isReview && (element.closest('.que') || element.tagName !== 'A')) continue;
                if (quizChrome(element)) continue;
                if (element.tagName === 'A' && !safeURL(element.href)) continue;
                // Moodle 4+ places the start/continue attempt form in tertiary navigation.
                const quizStart = !!element.closest('.quizstartbuttondiv') && !!element.form && safeForm(element.form);
                if (!quizStart && element.closest('.activity-header, .activity-information, [data-region="activity-information"], [data-region="completion-info"], .tertiary-navigation, .activity-navigation')) continue;
                // File-picker, navigation-menu and rich-editor controls require the web UI.
                // Ordering move buttons are driven by the native order field.
                if (element.closest('.editor_atto, .tox, .filemanager, .dropdown-menu, .que.ordering .sortablelist, #quiz-timer-wrapper') ||
                    element.getAttribute('data-toggle') === 'dropdown' ||
                    element.getAttribute('data-bs-toggle') === 'dropdown') continue;
                const text = clean(element.textContent || element.value || element.getAttribute('aria-label'));
                if (!text || (modal && /^(關閉|Close)$/i.test(text))) continue;
                if (result && disabled(element)) continue;
                if (result && element.form && !safeForm(element.form)) {
                    const target = new URL(element.form.action, document.baseURI);
                    // The course-return GET form is navigation, not a quiz action.
                    if (element.form.method.toLowerCase() === 'get' &&
                        target.origin === 'https://euni.niu.edu.tw' && target.pathname === '/course/view.php') continue;
                }
                if (element.form && !safeForm(element.form)) {
                    webReason ||= '此操作需要透過校方頁面完成。';
                }
                const fieldIDs = fields.filter(f => {
                    const owner = controls.get(f.id).element.form || controls.get(f.id).element.closest('form');
                    return element.tagName !== 'A' && (element.form ? owner === element.form : true);
                }).map(f => f.id);
                const targetPath = (() => {
                    try { return new URL(element.tagName === 'A' ? element.href : element.form?.action || '', document.baseURI).pathname; }
                    catch { return ''; }
                })();
                // Review pages reuse the next-nav class for「完成檢閱」back to view.php.
                const role = quizStart ? 'start' :
                    isReview && element.tagName === 'A' && targetPath === '/mod/quiz/view.php' ? 'done' :
                    element.matches('.mod_quiz-prev-nav') ? 'previous' :
                    element.matches('.mod_quiz-next-nav') ? (/完成作答|Finish attempt/i.test(text) ? 'finish' : 'next') :
                    element.closest('.btn-finishattempt') ? 'submit' :
                    modal && (element.matches('[data-action="cancel"]') || element.name === 'cancel') ? 'cancel' :
                    modal && element.matches('[data-action="save"], .btn-primary') ? 'confirm' :
                    stage === 'summary' && targetPath === '/mod/quiz/attempt.php' ? 'resume' :
                    element.tagName === 'A' && targetPath === '/mod/quiz/review.php' ? 'review' :
                    isReview && element.tagName === 'A' && targetPath === '/mod/quiz/view.php' ? 'done' : null;
                // Each attempt card has its own review link; name it after the card.
                const card = role === 'review' ? clean(element.closest('.card')?.querySelector('.card-title')?.textContent) : '';
                const action = {id: key(element), label: card ? text + '：' + card : text, role,
                    disabled: disabled(element), fieldIDs,
                    // Quiz page navigation saves drafts; finishing still needs the summary page.
                    isNavigation: (element.tagName === 'A' && safeURL(element.href)) ||
                        (element.matches('.mod_quiz-next-nav, .mod_quiz-prev-nav') && safeForm(element.form))};
                actions.set(action.id, element);
                actionList.push(action);
            }
            // Answer card: Moodle's navigation block lives in a drawer outside region-main.
            const navigation = [];
            if (stage === 'attempt' || stage === 'summary') {
                const stateOf = element => element.classList.contains('invalidanswer') ? 'invalid' :
                    ['answersaved', 'complete', 'answered'].some(c => element.classList.contains(c)) ? 'answered' :
                    element.classList.contains('notyetanswered') ? 'unanswered' : 'other';
                const nav = Array.from(document.querySelectorAll('#mod_quiz_navblock .qnbutton'));
                for (const button of nav) {
                    const copy = button.cloneNode(true);
                    copy.querySelectorAll('.accesshide, .sr-only, .visually-hidden').forEach(e => e.remove());
                    const number = clean(copy.textContent);
                    if (!number || !safeURL(button.href)) continue;
                    navigation.push({id: key(button), number, state: stateOf(button),
                        status: clean((button.title || '').replace(/^[^-]*-\s*/, '')),
                        flagged: button.classList.contains('flagged'), current: button.classList.contains('thispage')});
                    navTargets.set(key(button), button);
                }
                if (!nav.length) for (const row of root.querySelectorAll('table.quizsummaryofattempt tbody tr')) {
                    const link = row.querySelector('td.c0 a');
                    if (!link || !safeURL(link.href)) continue;
                    navigation.push({id: key(link), number: clean(link.textContent), state: stateOf(row),
                        status: clean(row.querySelector('td.c1')?.textContent), flagged: false, current: false});
                    navTargets.set(key(link), link);
                }
            }
            const questionList = stage === 'attempt' && !webReason ? Array.from(root.querySelectorAll('.que')).filter(visible).map(question => ({
                id: key(question),
                number: clean(question.querySelector('.info .qno')?.textContent) ||
                    clean(question.querySelector('.info .no')?.textContent).replace(/^\D+/, ''),
                text: contextQuestions.has(question) ? '' : blankContext(question.querySelector('.qtext'), []),
                state: clean(question.querySelector('.info .state')?.textContent)
            })) : null;
            for (const field of fields) {
                const question = controls.get(field.id).element.closest('.que');
                if (!question) continue;
                field.questionID = key(question);
                const prefix = field.label.match(/^[^：]{1,24}：/);
                const part = prefix ? field.label.slice(prefix[0].length) : field.label;
                const info = questionList?.find(q => q.id === field.questionID);
                field.part = info && info.text && clean(part).startsWith(clean(info.text)) ? null : part;
            }
            if (fields.length > 60 || actionList.length > 40) webReason = '此頁內容較複雜，請使用校方頁面。';
            const actionElements = new Set(actions.values());
            const copy = root.cloneNode(true);
            const originals = Array.from(root.querySelectorAll('*'));
            const copies = Array.from(copy.querySelectorAll('*'));
            // Native fields already show these questions; keep the text only for web fallback.
            const nativeQuestions = new Set(webReason ? [] :
                fields.map(f => controls.get(f.id).element.closest('.que')).filter(Boolean));
            originals.forEach((element, index) => {
                if (!visible(element) || result?.consumed.has(element) || (isReview && element.matches('.que')) ||
                    // Native controls and the answer card already present these.
                    (result && element.tagName === 'A' && actionElements.has(element)) ||
                    (stage === 'summary' && element.matches('table.quizsummaryofattempt, h2, h3')) ||
                    (element.matches('.que .info, .que .qtext, .que .ablock, .que .answer, .que .answercontainer, .que .drags') &&
                        nativeQuestions.has(element.closest('.que'))) ||
                    // Fields carry this sentence as context; keep it out of the page summary.
                    (!webReason && element.matches('.que .formulation') && contextQuestions.has(element.closest('.que')))) copies[index].remove();
            });
            if (result) {
                copy.querySelectorAll('h1, .activity-completion, [data-region="completion-info"], .tertiary-navigation').forEach(e => e.remove());
            }
            // Tertiary navigation holds start/back controls, which are actions, not content.
            copy.querySelectorAll('script, style, noscript, input, textarea, select, button, label, nav, .tertiary-navigation, .activity-navigation, .accesshide, .visually-hidden, [hidden], [aria-hidden="true"], [role="timer"], [id*="timer" i], [class*="timer" i], [id*="countdown" i], [class*="countdown" i], time').forEach(e => e.remove());
            copy.querySelectorAll('p, div, tr, h1, h2, h3, li, br').forEach(e => e.appendChild(document.createTextNode('\n')));
            const fullText = (copy.textContent || '').split('\n').map(clean).filter(Boolean).join('\n');
            if (fullText.length > 16000) webReason = '題目內容較長，此處僅顯示摘要。請使用校方頁面閱讀完整題目並作答。';
            const text = fullText.slice(0, 16000);
            const title = clean(root.querySelector(modal ? '.modal-title, .moodle-dialogue-hd, h1, h2, h3, h4, h5' : 'h1, h2')?.textContent);
            // Changing a question, control or action invalidates pending native confirmation.
            const structure = JSON.stringify([fields.map(f => [f.id, f.kind, f.label, f.options, f.disabled, f.context]),
                actionList, text, webReason, result?.summary, questions]);
            return {revision: documentID + ':' + structure, title, text, fields, actions: actionList, webReason, timer,
                timerSeconds, stage, navigation, questions: questionList,
                result: result?.summary || null, reviewQuestions: questions};
        };
        const applyAnswers = async (answers, allowedFields) => {
            // Validate the full payload before touching any input.
            const dragText = [];
            for (const [id, values] of Object.entries(answers)) {
                const control = controls.get(id);
                if (!allowedFields.includes(id) || !control || !Array.isArray(values) || !values.every(v => typeof v === 'string')) return 'changed';
                if (control.field.disabled) continue;
                if (control.custom) {
                    const problem = control.custom.validate(values);
                    if (problem) return problem;
                    if (control.custom.kind === 'ddwtos') dragText.push({control, values});
                    continue;
                }
                if (control.options.length && values.some(v => !control.options.some(o => key(o) === v &&
                    (!disabled(o) || control.field.values.includes(v))))) return 'changed';
                if (control.field.kind === 'single' && values.length > 1) return 'changed';
                if (!control.options.length && control.element.maxLength >= 0 &&
                    (values[0] || '').length > control.element.maxLength) return 'invalid';
            }
            if (dragText.length && dragTextProblem(dragText)) return 'invalid';
            for (const [id, values] of Object.entries(answers)) {
                const control = controls.get(id);
                if (control.field.disabled || control.custom?.kind === 'ddwtos') continue;
                if (control.custom) {
                    const problem = control.custom.apply(values);
                    if (problem) return problem;
                    continue;
                }
                if (control.options.length) {
                    for (const option of control.options) {
                        if (disabled(option)) continue;
                        if (option.tagName === 'OPTION') option.selected = values.includes(key(option));
                        else option.checked = values.includes(key(option));
                    }
                } else {
                    control.element.value = values[0] || '';
                }
            }
            if (dragText.length) {
                const problem = await applyDragText(dragText);
                if (problem) return problem;
            }
            return 'staged';
        };
        // Both return promises; WebKit's callAsyncJavaScript awaits them.
        const stage = async (revision, answers) => {
            const page = snapshot();
            if (page.revision !== revision || page.webReason) return 'changed';
            return applyAnswers(answers, page.fields.map(f => f.id));
        };
        const perform = async (revision, actionID, answers) => {
            const page = snapshot();
            if (page.revision !== revision || page.webReason) return 'changed';
            // Answer-card bubbles sit in Moodle's hidden drawer; its own handler saves the page first.
            const jump = navTargets.get(actionID);
            const action = actions.get(actionID) || jump;
            if (!action || (!jump && !visible(action)) || disabled(action)) return 'changed';
            const allowedFields = jump ? page.fields.map(f => f.id) : page.actions.find(a => a.id === actionID).fieldIDs;
            const result = await applyAnswers(answers, allowedFields);
            if (result !== 'staged') return result;
            if (!action.isConnected || (!jump && !visible(action)) || disabled(action)) return 'changed';
            if (action.form && !action.form.noValidate && !action.formNoValidate && !action.form.checkValidity()) return 'invalid';
            // Click the actual school control to preserve its validation and JS.
            // Do not dispatch change events: some activities auto-submit on change.
            action.click();
            return 'invoked';
        };
        const focusQuestion = id => {
            const question = Array.from(document.querySelectorAll('.que')).find(e => key(e) === id);
            if (!question || !visible(question)) return false;
            question.scrollIntoView({block: 'start'});
            return true;
        };
        window.__niuQuestionsV1 = {snapshot, stage, perform, focusQuestion};
    })();
    """#

    static let snapshot = "JSON.stringify(window.__niuQuestionsV1.snapshot())"
}
