// Turns raw model output into HTML that is safe to patch into the live page.
//
// Two zones:
//   1. Component zone: plain text tags plus the <ui-*> custom elements, with a
//      strict per-tag attribute allowlist. No style, class, id, on*, or data-*.
//   2. Free-form zone: anything inside <free-form>. The model may write its own
//      HTML and CSS there. It is moved into a sandboxed iframe (no scripts, no
//      network), so its CSS cannot touch the host page.
import { randomBytes } from 'node:crypto'
import sanitizeHtml from 'sanitize-html'

const TEXT_TAGS = [
  'h2', 'h3', 'h4', 'p', 'ul', 'ol', 'li', 'strong', 'em', 'b', 'i', 'code',
  'br', 'hr', 'span', 'div', 'table', 'thead', 'tbody', 'tr', 'th', 'td',
]

// The component catalogue. The system prompt is generated from this, so the
// model's menu and the sanitizer's allowlist cannot drift apart.
export const COMPONENTS = {
  'ui-grid': { attrs: ['cols'], doc: 'Lays its children out in equal columns. cols: 2-4.' },
  'ui-card': { attrs: ['title'], doc: 'A titled panel around its children.' },
  'ui-stat': { attrs: ['label', 'value', 'delta'], doc: 'One headline number. delta is optional, e.g. "+12%".' },
  'ui-bars': { attrs: ['series'], doc: 'Bar chart. series is a JSON array: [{"label":"Jan","value":10}].' },
  'ui-callout': { attrs: ['tone'], doc: 'A highlighted note around its children. tone: info | good | warn.' },
}

const COMPONENT_ATTRS = Object.fromEntries(
  Object.entries(COMPONENTS).map(([tag, c]) => [tag, c.attrs]),
)

const SVG_TAGS = [
  'svg', 'g', 'circle', 'ellipse', 'rect', 'line', 'path', 'polygon',
  'polyline', 'text', 'defs', 'lineargradient', 'radialgradient', 'stop',
]
const SVG_ATTRS = [
  'viewbox', 'width', 'height', 'x', 'y', 'x1', 'y1', 'x2', 'y2', 'cx', 'cy',
  'r', 'rx', 'ry', 'd', 'points', 'fill', 'stroke', 'stroke-width',
  'stroke-linecap', 'stroke-dasharray', 'opacity', 'transform', 'offset',
  'stop-color', 'gradientunits', 'text-anchor', 'font-size',
]

// Records what the allowlist is about to drop, for the demo's "blocked" panel.
const recorder = (allowedTags, allowedAttributes, blocked) => (tagName, attribs) => {
  if (!allowedTags.includes(tagName)) {
    blocked.add(`<${tagName}>`)
  } else {
    const ok = [...(allowedAttributes[tagName] ?? []), ...(allowedAttributes['*'] ?? [])]
    for (const name of Object.keys(attribs)) {
      if (!ok.includes(name)) blocked.add(`${name}= on <${tagName}>`)
    }
  }
  return { tagName, attribs }
}

function cleanComponentZone(html, blocked) {
  const allowedTags = [...TEXT_TAGS, ...Object.keys(COMPONENTS)]
  const allowedAttributes = { ...COMPONENT_ATTRS, td: ['colspan'], th: ['colspan'] }
  return sanitizeHtml(html, {
    allowedTags,
    allowedAttributes,
    transformTags: { '*': recorder(allowedTags, allowedAttributes, blocked) },
  })
}

function cleanFreeFormZone(html, blocked) {
  const allowedTags = [...TEXT_TAGS, 'style', 'h1', 'section', 'small', ...SVG_TAGS]
  const allowedAttributes = { '*': ['class', 'id', 'style', ...SVG_ATTRS] }
  return sanitizeHtml(html, {
    allowedTags,
    allowedAttributes,
    // <style> is deliberate here: this zone only ever renders inside the
    // sandboxed iframe built below.
    allowVulnerableTags: true,
    parseStyleAttributes: false,
    transformTags: { '*': recorder(allowedTags, allowedAttributes, blocked) },
  })
}

const escapeAttr = (s) =>
  s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')

const FRAME_HEAD =
  '<!doctype html><meta charset="utf-8">' +
  // No scripts, no network: only inline CSS and data: images load.
  `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">` +
  '<style>:root{color-scheme:light dark}html,body{margin:0;height:100%}' +
  'body{font:15px/1.5 system-ui,sans-serif;display:grid;place-items:center;overflow:hidden}</style>'

function freeFormFrame(inner, heightAttr, blocked) {
  const height = Math.min(480, Math.max(80, Number.parseInt(heightAttr, 10) || 200))
  const doc = FRAME_HEAD + cleanFreeFormZone(inner, blocked)
  // sandbox="" grants nothing: no scripts, no forms, no same-origin access,
  // no navigation of the parent page.
  return `<iframe class="free-form" sandbox="" title="Model-written visual" style="height:${height}px" srcdoc="${escapeAttr(doc)}"></iframe>`
}

const FREE_FORM = /<free-form\b([^>]*)>([\s\S]*?)<\/free-form\s*>/gi
const OPEN_FREE_FORM = /<free-form\b[\s\S]*$/i
const FENCE = /^\s*```[a-z]*\s*\n?|\n?```\s*$/gi

/**
 * @param {string} raw   model output so far (may be cut off mid-tag)
 * @param {boolean} done whether the stream has finished
 * @returns {{ html: string, blocked: string[] }}
 */
export function renderModelOutput(raw, done = true) {
  const blocked = new Set()
  const nonce = randomBytes(8).toString('hex')
  const frames = []
  let text = raw.replace(FENCE, '')

  // Finished free-form blocks become iframes. They are swapped for a token
  // first so the strict component-zone pass never sees their contents.
  text = text.replace(FREE_FORM, (_m, attrs, inner) => {
    const height = /\bheight\s*=\s*["']?(\d+)/i.exec(attrs)?.[1]
    frames.push(freeFormFrame(inner, height, blocked))
    return `[[frame:${nonce}:${frames.length - 1}]]`
  })

  // A free-form block that is still streaming shows a placeholder: rendering
  // it early would reload the iframe, and restart its animations, on every chunk.
  let pending = false
  text = text.replace(OPEN_FREE_FORM, () => {
    pending = !done
    return ''
  })

  // Drop a tag that is cut off mid-stream, e.g. `<ui-stat label="Rev`.
  const lastOpen = text.lastIndexOf('<')
  if (lastOpen > text.lastIndexOf('>')) text = text.slice(0, lastOpen)

  let html = cleanComponentZone(text, blocked)
  html = html.replace(
    new RegExp(`\\[\\[frame:${nonce}:(\\d+)\\]\\]`, 'g'),
    (_m, i) => frames[Number(i)],
  )
  if (pending) html += '<p class="pending">Drawing a custom visual…</p>'
  return { html, blocked: [...blocked] }
}
