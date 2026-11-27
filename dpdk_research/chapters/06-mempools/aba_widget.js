/* Chapter 6: the lock-free stack ABA step-through widget.
 * Owned by ch06; ch14 embeds it with:
 *   <script src="../06-mempools/aba_widget.js"></script>
 *   Ch06ABA.mount('#some-widget-div');
 * The root element needs: an <svg viewBox="0 0 680 330"> inside .widget-body and
 * optional mode buttons with data-aba-mode="ptr" / "cnt".
 * Requires ../../assets/course.js (CourseJS.Stepper, CourseJS.svg). */
(function (global) {
  'use strict';

  function mount(rootSel) {
    var CJ = global.CourseJS, S = CJ.svg;
    var root = CJ.$(rootSel);
    if (!root) return null;
    var svg = root.querySelector('svg');
    var mode = 'ptr';                       /* 'ptr' = plain pointer CAS, 'cnt' = {ptr,cnt} CAS */

    /* Static layout ------------------------------------------------------ */
    S.clear(svg);
    var X0 = 30;
    S.text(svg, X0, 22, 'shared stack head', 'svg-label bold');
    var headBox = S.rect(svg, X0, 32, 150, 46, 'svg-box c5');
    var headTxt = S.text(svg, X0 + 75, 55, '', 'svg-label center mono');

    S.text(svg, 220, 22, 'linked list (top first)', 'svg-label bold');
    S.path(svg, 'M180,55 L216,55', 'svg-arrow c5');
    var listG = S.group(svg);

    /* three threads */
    var thr = [];
    var names = ['T1 (pop, gets preempted)', 'T2 (pops twice)', 'T3 (pushes)'];
    for (var i = 0; i < 3; i++) {
      var y = 130 + i * 62;
      var b = S.rect(svg, X0, y, 260, 50, 'svg-box c1');
      var t1 = S.text(svg, X0 + 10, y + 18, names[i], 'svg-label bold small');
      var t2 = S.text(svg, X0 + 10, y + 37, '', 'svg-label mono small');
      thr.push({ box: b, title: t1, txt: t2 });
    }
    S.text(svg, 330, 122, 'elements in someone\'s hands / free list', 'svg-label bold small');
    var handG = S.group(svg);
    var verdictBg = S.rect(svg, 330, 262, 330, 56, 'svg-box c7');
    var verdict = S.text(svg, 495, 290, '', 'svg-label center small');

    function nodeBox(g, x, y, name, data, cls) {
      S.rect(g, x, y, 64, 40, 'svg-box ' + cls);
      S.text(g, x + 32, y + 14, name, 'svg-label center bold');
      S.text(g, x + 32, y + 30, data, 'svg-label center small mono');
    }

    function draw(st) {
      headTxt.textContent = mode === 'cnt'
        ? '{top=' + (st.top || 'NULL') + ', cnt=' + st.cnt + '}'
        : 'top=' + (st.top || 'NULL');
      headBox.setAttribute('class', 'svg-box ' + (st.bad ? 'c4' : 'c5'));
      S.clear(listG);
      var x = 220, n = st.top, seen = {}, k = 0;
      while (n && !seen[n] && k < 5) {
        seen[n] = 1;
        var e = st.el[n];
        nodeBox(listG, x, 36, n, e.data, st.bad && e.owner ? 'c4' : 'c2');
        var nx = e.next;
        if (nx) S.arrow(listG, x + 64, 56, x + 86, 56, 'c2');
        else S.text(listG, x + 70, 60, 'NULL', 'svg-label small muted');
        x += 90; n = nx; k++;
      }
      if (!st.top) S.text(listG, 220, 60, '(empty)', 'svg-label muted');
      S.clear(handG);
      var hx = 330;
      Object.keys(st.el).forEach(function (k2) {
        var e = st.el[k2];
        if (!e.owner) return;
        nodeBox(handG, hx, 134, k2, e.data, 'c3');
        S.text(handG, hx + 32, 192, e.owner, 'svg-label center small');
        hx += 80;
      });
      for (var j = 0; j < 3; j++) {
        thr[j].txt.textContent = st.t[j] || '';
        thr[j].box.setAttribute('class', 'svg-box ' + (st.active === j ? 'c3' : 'c1'));
      }
      verdict.textContent = st.verdict || '';
      verdictBg.setAttribute('class', 'svg-box ' + (st.vcls || 'c7'));
    }

    function init(ctx) {
      ctx.data.st = {
        top: 'A', cnt: 7, bad: false, active: -1, t: ['', '', ''], verdict: 'stack: A -> B -> C',
        el: { A: { data: 'pkt#1', next: 'B' }, B: { data: 'pkt#2', next: 'C' }, C: { data: 'pkt#3', next: null } }
      };
    }

    var steps = [
      { caption: 'Start: the stack holds A &rarr; B &rarr; C. The head is one machine word <code>top</code> (left) and, in the safe version, a modification counter next to it.' },
      { caption: 'T1 starts a pop: it reads the head (A) and <code>A-&gt;next</code> (B), and computes the new head B. Before its compare-and-swap (CAS) runs, the OS preempts it.',
        run: function (ctx) { var s = ctx.data.st; s.active = 0;
          s.t[0] = mode === 'cnt' ? 'read {A,7}; want {B,8}; preempted' : 'read top=A; want top=B; preempted'; s.verdict = 'T1 holds a snapshot: expected=A, new=B'; } },
      { caption: 'T2 pops A. Its CAS succeeds; the head is now B. A belongs to T2 (in a mempool: an object handed to the application).',
        run: function (ctx) { var s = ctx.data.st; s.active = 1; s.top = 'B'; s.cnt = 8; s.el.A.owner = 'T2'; s.t[1] = 'pop -> A'; s.verdict = 'head moved A -> B'; } },
      { caption: 'T2 pops B as well. The head is C; A and B are both in use by T2.',
        run: function (ctx) { var s = ctx.data.st; s.top = 'C'; s.cnt = 9; s.el.B.owner = 'T2'; s.t[1] = 'pop -> A, pop -> B'; s.verdict = 'head moved B -> C'; } },
      { caption: 'T3 pushes a recycled element: the very same list node A (in DPDK the LF stack reuses its fixed set of list elements), now carrying new data. A&rarr;next = C, head = A again.',
        run: function (ctx) { var s = ctx.data.st; s.active = 2; s.el.A = { data: 'pkt#9', next: 'C' }; s.top = 'A'; s.cnt = 10; s.t[2] = 'push A(pkt#9)'; s.verdict = 'head is A again: the "A-B-A" in ABA'; } },
      { caption: '', /* filled in by onStep, depends on mode */
        predict: { question: 'T1 wakes up and runs CAS(head, expected = what it read in step 2, new = B). Does the CAS succeed?',
          options: ['Yes: the head matches what T1 expects', 'No: the CAS fails and T1 retries'], answer: 0, explain: '' },
        run: function (ctx) { var s = ctx.data.st; s.active = 0;
          if (mode === 'ptr') {
            s.top = 'B'; s.bad = true; s.el.B.owner = 'T2';
            s.t[0] = 'CAS(top: A==A) OK -> top=B';
            s.verdict = 'CORRUPT: head -> B, which T2 owns; pkt#9 lost'; s.vcls = 'c4';
          } else {
            s.t[0] = 'CAS {A,7} vs {A,10}: FAIL';
            s.verdict = 'counter 10 != 7: T1 sees the change'; s.vcls = 'c2';
          }
        } },
      { caption: '',
        run: function (ctx) { var s = ctx.data.st;
          if (mode === 'ptr') {
            s.t[0] = 'popped A(pkt#1)? stale data';
            s.verdict = 'stack and T2 share B: a double allocation'; s.vcls = 'c4';
          } else {
            s.t[0] = 'reload {A,10}; next=C; CAS -> {C,11}';
            s.top = 'C'; s.cnt = 11; s.el.A.owner = 'T1';
            s.verdict = 'correct: T1 popped A(pkt#9); head = C'; s.vcls = 'c2';
          }
        } }
    ];

    function setTexts() {
      var p = steps[5].predict;
      if (mode === 'ptr') {
        p.answer = 0;
        p.explain = 'The CAS only compares the pointer, and the pointer is A again. It cannot tell that A was popped, reused and pushed in between.';
        steps[5].caption = '<strong>Plain pointer CAS succeeds.</strong> The head becomes B, but B is in T2\'s hands. T1 also returns the stale <code>pkt#1</code> it read in step 2.';
        steps[6].caption = 'Result: the shared stack points to an element that is in use, and pkt#9 has vanished from the list. In a mempool this means the same object is handed out twice.';
      } else {
        p.answer = 1;
        p.explain = 'The CAS compares 128 bits: the pointer AND the counter. The pointer matches (A), but the counter went 7 &rarr; 10 because three operations happened.';
        steps[5].caption = '<strong>128-bit CAS fails:</strong> top matches but cnt is 10, not 7. <code>rte_atomic128_cmp_exchange()</code> also hands T1 the current head.';
        steps[6].caption = 'T1 retries with the fresh head: it reads A&rarr;next = C and swings the head to {C, 11}. Every push and pop bumps the counter, so a recycled pointer is never mistaken for an unchanged one.';
      }
    }

    setTexts();
    var stepper = new CJ.Stepper(root, {
      reset: function (ctx) { init(ctx); },
      steps: steps,
      interval: 2600,
      onStep: function (i, ctx) { draw(ctx.data.st); }
    });
    draw(stepper.ctx.data.st);

    CJ.$$('[data-aba-mode]', root).forEach(function (b) {
      b.setAttribute('aria-pressed', b.getAttribute('data-aba-mode') === mode ? 'true' : 'false');
      b.addEventListener('click', function () {
        mode = b.getAttribute('data-aba-mode');
        CJ.$$('[data-aba-mode]', root).forEach(function (x) {
          x.setAttribute('aria-pressed', x === b ? 'true' : 'false');
        });
        setTexts();
        stepper.pause();
        stepper.answered = {};
        stepper.go(0);
      });
    });
    return stepper;
  }

  global.Ch06ABA = { mount: mount };
})(window);
