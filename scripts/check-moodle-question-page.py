#!/usr/bin/env python3
"""Exercise the production native-question DOM bridge in offline WebKit fixtures.

No account, Keychain or school requests. All form submissions stay in synthetic HTML.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import AppKit
import WebKit

@MainActor final class Checks: NSObject, WKNavigationDelegate {
    let web: WKWebView
    var index = 0
    var previousRevision = ""
    let cases: [(String, String, String)] = [
        ("completed quiz keeps grades, dates and attempt fields structured", #"""
        <main id="region-main"><h2>(09/23) AI PC 是甚麼?</h2>
        <div class="activity-dates"><div><strong>開始：</strong>2026年 09月 23日 (週三) 15:30</div>
        <div><strong>結束：</strong>2026年 09月 23日 (週三) 16:11</div></div>
        <div class="quizinfo"><p>允許作答幾次： 1</p></div>
        <div id="feedback"><h3>這個測驗您的最後成績是 87.50/100.00</h3></div>
        <h3>您的作答記錄</h3><div class="card"><h4 class="card-title">作答記錄 1</h4>
        <table class="quizreviewsummary"><caption class="sr-only">嘗試 1 的摘要</caption><tbody>
        <tr><th>作答狀態</th><td>已經完成</td></tr>
        <tr><th>開始</th><td>2026年 09月 23日 (週三) 15:43</td></tr>
        <tr><th>完成於</th><td>2026年 09月 23日 (週三) 15:44</td></tr>
        <tr><th>作答時間</th><td>45 秒</td></tr>
        <tr><th>成績</th><td>得 87.50 分 (滿分為 100.00 分)</td></tr>
        </tbody></table></div>
        <div class="quizattempt"><p>不可以再作答了</p><form action="/course/view.php" method="get">
        <input type="hidden" name="id" value="100"><button>回到課程</button></form></div></main>
        """#, #"""
        const p=bridge.snapshot(), r=p.result;
        require(r && r.grade==='87.50/100.00' && r.gradeLabel==='最後成績','final grade');
        require(r.information.length===3 && r.information[2].value==='1','dates and attempt limit');
        require(r.attempts.length===1 && r.attempts[0].details.length===5,'all attempt fields');
        require(r.attempts[0].details[3].value==='45 秒','duration');
        require(r.notices.includes('不可以再作答了') && !p.webReason && !p.actions.length,'completion without unnecessary web fallback');
        require(!p.text.includes('87.50') && !p.text.includes('15:43'),'no repeated flattened result');
        """#),
        ("review separates questions, answers and permitted feedback without editable controls", #"""
        <main id="region-main"><form action="/mod/quiz/review.php" method="post">
        <div class="que multichoice incorrect">
        <div class="info"><h3 class="no">試題 1</h3><div class="state">不正確</div><div class="grade">得分 0.00 / 1.00</div></div>
        <div class="formulation"><div class="qtext"><p>哪個是題目的正確選項？</p></div>
        <div class="prompt">單選</div><div class="answer">
        <div class="r0 incorrect"><input type="radio" checked disabled aria-labelledby="option-a">
        <div id="option-a" data-region="answer-label">a. 選項甲</div><div class="specificfeedback">請再確認題意。</div></div>
        <div class="r1"><input type="radio" disabled aria-labelledby="option-b">
        <div id="option-b" data-region="answer-label">b. 選項乙</div></div></div></div>
        <div class="outcome"><div class="specificfeedback">你的答案不正確。</div>
        <div class="rightanswer">正確答案是：選項乙</div><div class="generalfeedback">這是老師提供的解析。</div></div></div>
        <div class="que shortanswer"><div class="info"><h3 class="no">試題 2</h3><div class="state">已作答</div></div>
        <div class="formulation"><div class="qtext">請輸入關鍵詞。</div><div class="answer"><input type="text" readonly value="學生的答案"></div></div>
        <div class="rightanswer" hidden>HIDDEN_CORRECT_ANSWER</div></div>
        <div class="que essay"><div class="info"><h3 class="no">試題 3</h3><div class="state">尚未評分</div></div>
        <div class="formulation"><div class="qtext">請說明原因。</div><div class="qtype_essay_response">這是我的說明。</div></div>
        <div class="comment">請補充例子。</div></div>
        <div class="que description"><div class="info"><h3 class="no">閱讀說明</h3></div>
        <div class="qtext">請參考圖片。<img width="30" height="30" alt="示意圖"
        src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='30' height='30'%3E%3C/svg%3E"></div></div>
        <button type="submit" onclick="window.sent=true">儲存標記</button></form>
        <a href="/mod/quiz/review.php?attempt=10&amp;page=1" onclick="event.preventDefault();window.nextPage=true">下一頁</a>
        <a href="/mod/quiz/view.php?id=100">結束複習</a></main>
        """#, #"""
        const p=bridge.snapshot(), q=p.reviewQuestions;
        require(q.length===4 && q[0].title==='試題 1' && q[0].mark==='得分 0.00 / 1.00','question structure');
        require(q[0].choices[0].selected && q[0].choices[0].verdict==='incorrect' && !q[0].choices[1].selected,'selected option');
        require(q[0].correctAnswer.includes('選項乙') && q[0].generalFeedback.includes('解析'),'permitted feedback');
        require(q[1].responses[0]==='學生的答案' && !q[1].correctAnswer && !JSON.stringify(q).includes('HIDDEN_CORRECT_ANSWER'),'hidden answers stay hidden');
        require(q[2].responses[0]==='這是我的說明。' && q[2].comment==='請補充例子。','essay and teacher comment');
        require(q[3].webReason && !p.webReason && !q[0].webReason,'fallback applies only to rich question');
        require(p.fields.length===0 && p.actions.length===2 && p.actions.every(a=>a.isNavigation),'read-only review');
        require(!p.text.includes('學生的答案') && !p.text.includes('正確選項'),'no repeated flattened questions');
        require(bridge.focusQuestion(q[3].id),'school question anchor');
        require(bridge.perform(p.revision,p.actions[0].id,{})==='invoked' && window.nextPage && !window.sent,'review pagination without submit');
        """#),
        ("single/multiple/text/select and real submit handler", #"""
        <main id="region-main"><h2>合成題目</h2><p class="qtext">請選擇答案</p>
        <div style="display:none">HIDDEN_ANSWER</div>
        <form action="/mod/irs/answer.php" onsubmit="event.preventDefault();window.submits=(window.submits||0)+1">
        <input type="hidden" name="sesskey" value="FIXTURE_SECRET">
        <fieldset><legend>單選題</legend><label><input type="radio" name="one" value="a">甲</label>
        <label><input type="radio" name="one" value="b">乙</label></fieldset>
        <fieldset><legend>多選題</legend><label><input type="checkbox" name="many[]" value="x">丙</label>
        <label><input type="checkbox" name="many[]" value="y">丁</label></fieldset>
        <label for="text">簡答</label><input id="text" name="text" required maxlength="8">
        <label for="select">下拉題</label><select id="select" required><option disabled selected value="">請選擇</option><option value="yes">同意</option></select>
        <button type="submit">送出答案</button></form></main>
        """#, #"""
        const p = bridge.snapshot();
        require(!p.webReason && p.fields.length === 4, 'supported controls');
        require(!p.text.includes('FIXTURE_SECRET') && !p.text.includes('HIDDEN_ANSWER'), 'hidden fields/text leaked');
        const one=p.fields.find(f=>f.label==='單選題'), many=p.fields.find(f=>f.label==='多選題');
        const text=p.fields.find(f=>f.label==='簡答'), select=p.fields.find(f=>f.label==='下拉題');
        const action=p.actions.find(a=>a.label==='送出答案');
        const answers={[one.id]:[one.options[1].id], [many.id]:many.options.map(o=>o.id),
                       [text.id]:['合成答案'], [select.id]:[select.options[1].id]};
        require(bridge.perform(p.revision,action.id,answers)==='invoked','submit');
        require(window.submits===1,'exactly one actual submit handler');
        require(document.querySelector('[name=one]:checked').value==='b','radio applied');
        require(document.querySelectorAll('[name="many[]"]:checked').length===2,'checkboxes applied');
        require(document.getElementById('text').value==='合成答案','text applied');
        require(document.getElementById('select').value==='yes','select applied');
        require(bridge.stage(p.revision,{[text.id]:['原生草稿']})==='staged' && window.submits===1,'interface switch must not submit');
        document.getElementById('text').value='網頁修改';
        require(bridge.snapshot().fields.find(f=>f.id===text.id).values[0]==='網頁修改','read web-side edits');
        require(bridge.perform('obsolete',action.id,answers)==='changed' && window.submits===1,'stale operation');
        """#),
        ("quiz attempt ignores hidden timer and flags, keeps option labels", #"""
        <main id="region-main"><div id="quiz-timer-wrapper" style="display:none">
        <div id="quiz-timer" role="timer">剩餘時間 <span id="quiz-time-left"></span></div></div>
        <form id="responseform" action="/mod/quiz/processattempt.php" method="post"
        onsubmit="event.preventDefault();window.submits=(window.submits||0)+1">
        <input type="hidden" name="sesskey" value="FIXTURE_SECRET">
        <div class="que multichoice"><div class="info"><h3 class="no">試題 <span class="qno">1</span></h3>
        <div class="state">尚未作答</div><div class="questionflag editable">
        <input type="checkbox" id="q1:1_:flaggedcheckbox" style="display:none">
        <label for="q1:1_:flaggedcheckbox"><img class="questionflagimage" alt="" width="16" height="16"
        src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16'%3E%3C/svg%3E">標記試題</label></div></div>
        <div class="content"><div class="formulation"><div class="qtext"><p>哪一個是合成答案？</p></div>
        <fieldset class="ablock"><legend class="prompt">請選擇一個：</legend><div class="answer">
        <div class="r0"><input type="radio" name="q1:1_answer" value="0" id="q1:1_answer0" aria-labelledby="q1:1_answer0_label">
        <div id="q1:1_answer0_label" data-region="answer-label"><span class="answernumber">a. </span>選項甲</div></div>
        <div class="r1"><input type="radio" name="q1:1_answer" value="1" id="q1:1_answer1" aria-labelledby="q1:1_answer1_label">
        <div id="q1:1_answer1_label" data-region="answer-label"><span class="answernumber">b. </span>選項乙</div></div>
        </div><div class="qtype_multichoice_clearchoice">
        <input type="radio" name="q1:1_answer" id="q1:1_answer-1" value="-1" style="display:none">
        <label for="q1:1_answer-1">清除我的選擇</label></div></fieldset></div></div></div>
        <div class="que shortanswer"><div class="info"><h3 class="no">試題 <span class="qno">2</span></h3></div>
        <div class="formulation"><div class="qtext">請輸入關鍵詞。</div><div class="ablock">
        <label for="q1:2_answer">答案：</label><input type="text" id="q1:2_answer" name="q1:2_answer"></div></div></div>
        <div class="submitbtns"><input type="submit" name="next" value="下一頁" class="mod_quiz-next-nav"></div>
        </form></main>
        """#, #"""
        const p=bridge.snapshot();
        require(!p.webReason,'hidden timer, flag and clear-choice chrome must not force web fallback: '+p.webReason);
        require(p.fields.length===2,'one choice field and one text field');
        const one=p.fields[0], text=p.fields[1];
        require(one.label==='試題 1：哪一個是合成答案？','question text instead of inner legend: '+one.label);
        require(one.options.length===2 && one.options[1].label==='b. 選項乙','aria-labelledby option text');
        require(text.label==='試題 2：請輸入關鍵詞。','short answer keeps question text');
        require(!p.text.includes('合成答案') && !p.text.includes('FIXTURE_SECRET'),'no duplicated question text');
        const next=p.actions.find(a=>a.label==='下一頁');
        require(p.actions.length===1 && next.isNavigation,'quiz page navigation without final-submit confirmation');
        require(bridge.perform(p.revision,next.id,{[one.id]:[one.options[1].id],[text.id]:['關鍵詞']})==='invoked','answer quiz page');
        require(window.submits===1 && document.getElementById('q1:1_answer1').checked,'actual school form');
        document.getElementById('quiz-timer-wrapper').style.display='block';
        document.getElementById('quiz-time-left').textContent='0:09:59';
        require(!!bridge.snapshot().webReason,'running timer still uses school page');
        """#),
        ("required fields, maxlength and refreshed question", #"""
        <main id="region-main"><p class="qtext">原本題目</p>
        <form action="/mod/quiz/processattempt.php" onsubmit="event.preventDefault();window.submits=(window.submits||0)+1">
        <label for="a">答案</label><input id="a" name="answer" required maxlength="3">
        <button>確認</button></form></main>
        """#, #"""
        const p=bridge.snapshot(), f=p.fields[0], a=p.actions[0];
        require(bridge.perform(p.revision,a.id,{[f.id]:['']})==='invalid','required validation');
        require(bridge.perform(p.revision,a.id,{[f.id]:['1234']})==='invalid','length validation');
        document.querySelector('.qtext').textContent='新題目';
        require(bridge.perform(p.revision,a.id,{[f.id]:['123']})==='changed','changed question');
        require(!window.submits,'invalid input must not submit');
        """#),
        ("multiple forms cannot mix answers", #"""
        <main id="region-main"><form action="/mod/irs/answer.php" onsubmit="event.preventDefault()">
        <label>第一題<input name="a"></label><button>第一個送出</button></form>
        <form action="/mod/irs/answer.php" onsubmit="event.preventDefault()">
        <label>第二題<input name="b"></label><button>第二個送出</button></form></main>
        """#, #"""
        const p=bridge.snapshot();
        require(p.actions[0].fieldIDs.length===1,'scope fields to selected form');
        require(bridge.perform(p.revision,p.actions[0].id,{[p.fields[1].id]:['wrong']})==='changed','cross-form payload');
        require(document.querySelector('[name=b]').value==='','no mutation before validation');
        """#),
        ("images require complete school presentation", #"""
        <main id="region-main"><p>依圖片作答</p><img alt="題目圖" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='30' height='30'%3E%3C/svg%3E">
        <button onclick="window.submits=1">答案A</button></main>
        """#, #"""
        const p=bridge.snapshot();
        require(!!p.webReason,'image fallback');
        require(bridge.perform(p.revision,p.actions[0].id,{})==='changed' && !window.submits,'no partial rendering submission');
        """#),
        ("source confirmation modal takes priority", #"""
        <main id="region-main"><p>原始測驗題</p><input name="old"><button>原始送出</button></main>
        <div role="dialog"><h2>確認交卷</h2><p>交卷後無法修改。</p>
        <button onclick="window.confirmed=true">全部送出並結束</button></div>
        """#, #"""
        const p=bridge.snapshot();
        require(p.title==='確認交卷' && p.fields.length===0,'modal snapshot');
        require(p.actions.length===1 && !p.text.includes('原始測驗題'),'only modal controls');
        require(bridge.perform(p.revision,p.actions[0].id,{})==='invoked' && window.confirmed,'modal button');
        """#),
        ("unsupported/captcha/external forms stay explicit", #"""
        <main id="region-main"><form action="https://example.test/collect">
        <input type="password" name="password" value="NEVER_EXPOSE">
        <button>送出</button></form></main>
        """#, #"""
        const p=bridge.snapshot();
        require(!!p.webReason && p.fields.length===0 && !p.text.includes('NEVER_EXPOSE'),'password privacy');
        require(bridge.perform(p.revision,p.actions[0].id,{})==='changed','external form');
        """#),
        ("timer ticks preserve drafts; options invalidate them", #"""
        <main id="region-main"><p>合成即時問題</p><span role="timer">00:30</span>
        <label><input type="radio" name="one">甲</label><button>送出</button></main>
        """#, #"""
        const before=bridge.snapshot();
        document.querySelector('[role=timer]').textContent='00:29';
        require(bridge.snapshot().revision===before.revision,'timer tick must not reset native drafts');
        document.querySelector('label').appendChild(document.createTextNode('更新'));
        require(bridge.snapshot().revision!==before.revision,'updated choice invalidates pending action');
        """#),
        ("disabled options retain server selection", #"""
        <main id="region-main"><form action="/mod/choice/view.php" onsubmit="event.preventDefault();window.submits=1">
        <label>答案<select><option disabled selected value="old">先前答案</option><option value="new">新答案</option></select></label>
        <button>送出</button></form></main>
        """#, #"""
        const p=bridge.snapshot(), f=p.fields[0];
        require(bridge.perform(p.revision,p.actions[0].id,{[f.id]:f.values})==='invoked','preserve disabled current selection');
        """#),
        ("long reading material cannot submit from an incomplete native summary",
        "<main id='region-main'><p>" + String(repeating: "長篇題目", count: 5000) +
        "</p><button onclick='window.submits=1'>作答</button></main>", #"""
        const p=bridge.snapshot();
        require(!!p.webReason,'explicit long-content fallback');
        require(bridge.perform(p.revision,p.actions[0].id,{})==='changed' && !window.submits,'no truncated-question submission');
        """#),
        ("custom hidden option controls require school UI", #"""
        <main id="region-main"><label for="custom">特殊選项</label>
        <input id="custom" type="radio" style="display:none"><button>確認</button></main>
        """#, #"""
        const p=bridge.snapshot();
        require(!!p.webReason,'do not omit a custom control then offer submission');
        """#),
    ]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 700), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }
    func next() {
        guard index < cases.count else {
            print("PASS: \(cases.count) real WebKit fixtures for native questions, validation, stale documents and explicit actions")
            exit(0)
        }
        web.loadHTMLString("<meta charset='utf-8'>" + cases[index].1,
                           baseURL: URL(string: "https://euni.niu.edu.tw/mod/" +
                               (cases[index].0.hasPrefix("review ") ? "quiz/review.php?attempt=10" :
                                index == 0 ? "quiz/view.php?id=100" : "irs/view.php?id=100")))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only loadHTMLString's initial navigation is allowed; fixture actions
        // can never navigate to an actual school endpoint.
        decisionHandler(action.navigationType == .other ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                _ = try await web.evaluateJavaScript(MoodleQuestionPageScript.install)
                let json = try await web.evaluateJavaScript(MoodleQuestionPageScript.snapshot) as! String
                let snapshot = try JSONDecoder().decode(MoodleQuestionPage.self, from: Data(json.utf8))
                precondition(snapshot.revision != previousRevision, "Reopening must create a new document identity")
                previousRevision = snapshot.revision
                let test = "(function(){const bridge=window.__niuQuestionsV1;function require(v,m){if(!v)throw Error(m);}" + cases[index].2 + "return true;})()"
                _ = try await web.evaluateJavaScript(test)
                print("PASS: \(cases[index].0)")
                index += 1
                next()
            } catch {
                print("FAIL: \(cases[index].0): \(error)")
                exit(1)
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let checks = MainActor.assumeIsolated { Checks() }
MainActor.assumeIsolated { checks.next() }
DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
    print("FAIL: offline WebKit fixture timed out")
    exit(1)
}
app.run()
'''

with tempfile.TemporaryDirectory(prefix="niu-native-question-page-") as directory:
    folder = Path(directory)
    swift = folder / "main.swift"
    swift.write_text(HARNESS)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-module-cache-path", str(folder / "modules"),
        str(ROOT / "Features/Moodle/Questions/MoodleQuestionPage.swift"), str(swift),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=45)
