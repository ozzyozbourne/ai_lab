import assert from 'node:assert/strict'
import { test } from 'node:test'
import { renderModelOutput } from '../sanitize.mjs'
import { pickMock } from '../mock.mjs'

test('hostile output is defanged', () => {
  const { html, blocked } = renderModelOutput(pickMock('attack'))
  // Split the page-level HTML from the escaped iframe documents.
  const host = html.replace(/srcdoc="[^"]*"/g, '')
  const frames = [...html.matchAll(/srcdoc="([^"]*)"/g)].map((m) => m[1])

  for (const bad of ['<script', 'data-init', 'data-on', 'onerror', 'onclick', 'javascript:', '<img', '<a ', 'style="position']) {
    assert.ok(!host.includes(bad), `host HTML still contains ${bad}`)
  }
  assert.equal(frames.length, 1)
  for (const bad of ['script', 'form', 'input', 'parent.location']) {
    assert.ok(!frames[0].includes(`&lt;${bad}`), `frame still contains <${bad}>`)
  }
  assert.ok(host.includes('<ui-stat label="Balance" value="$0.00">'), 'the component survives with its allowed attributes')
  assert.ok(blocked.includes('<script>') && blocked.includes('data-init= on <div>'))
})

test('free-form becomes a locked-down iframe that keeps its CSS', () => {
  const { html } = renderModelOutput('<free-form height="9999"><style>@keyframes a{to{opacity:0}}</style><div class="x">hi</div></free-form>')
  assert.match(html, /^<iframe class="free-form" sandbox="" /)
  assert.ok(html.includes('height:480px'), 'height is clamped')
  assert.ok(html.includes('@keyframes a'))
  assert.ok(html.includes('default-src &#x27;none&#x27;') || html.includes("default-src 'none'"))
})

test('a free-form block cannot break out of its srcdoc attribute', () => {
  const { html } = renderModelOutput('<free-form><div class=\'"><script>x</script>\'>hi</div></free-form>')
  assert.equal([...html.matchAll(/<iframe/g)].length, 1)
  assert.ok(!html.replace(/srcdoc="[^"]*"/, '').includes('<script'))
})

test('mid-stream output is always renderable', () => {
  const full = pickMock('dashboard')
  for (let i = 0; i <= full.length; i += 7) {
    const { html } = renderModelOutput(full.slice(0, i), false)
    assert.ok(!/<ui-[a-z]+[^>]*$/.test(html), 'no half-written tag')
    assert.ok(!html.includes('<free-form'), 'free-form never reaches the page raw')
  }
  assert.ok(renderModelOutput('<p>a</p><free-form height="100"><style>.a{', false).html.endsWith('<p class="pending">Drawing a custom visual…</p>'))
  assert.equal(renderModelOutput('<p>Hi</p><ui-stat label="Rev', false).html, '<p>Hi</p>')
})

test('markdown code fences are stripped', () => {
  assert.equal(renderModelOutput('```html\n<p>Hi</p>\n```').html, '<p>Hi</p>')
})
