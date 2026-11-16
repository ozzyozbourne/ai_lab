// Hybrid generative UI on Datastar.
//
//   browser --POST /generate (signals as JSON)--> this server --> model
//   browser <--SSE: datastar-patch-elements------ sanitizer  <-- text stream
//
// The model writes an HTML fragment. Every ~80ms the text so far is sanitized
// and sent as one Datastar element patch into #out.
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'
import Anthropic from '@anthropic-ai/sdk'
import { COMPONENTS, renderModelOutput } from './sanitize.mjs'
import { mockStream, pickMock } from './mock.mjs'

const PORT = Number(process.env.PORT ?? 8080)
const PUBLIC = fileURLToPath(new URL('./public/', import.meta.url))
const LIVE = Boolean(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN)
const MODEL = 'claude-opus-5-5'
const PATCH_INTERVAL_MS = 80

const SYSTEM_PROMPT = `You write the body of a UI panel as an HTML fragment. Your output is streamed straight into a web page, so reply with HTML only: no markdown, no code fences, no commentary.

Build the answer from these custom elements wherever one fits. They already match the page's design:
${Object.entries(COMPONENTS)
  .map(([tag, c]) => `- <${tag}${c.attrs.map((a) => ` ${a}=""`).join('')}>: ${c.doc}`)
  .join('\n')}

Around them you may use plain text tags: h2, h3, h4, p, ul, ol, li, strong, em, code, table, thead, tbody, tr, th, td. Attributes other than the ones listed above are removed, so do not add class, style or id out here.

When a custom visual or animation would help, and no component covers it, write one <free-form height="PIXELS"> block. Inside it you may write any HTML, inline SVG and a <style> block with your own CSS and @keyframes. It renders in an isolated frame of that height (80-480), full width, so size things relative to the frame. Scripts, forms, links, images and network requests do not work there: use CSS and SVG only.

Use realistic illustrative numbers when the user gives none. Keep it concise.`

const sseHeaders = {
  'Content-Type': 'text/event-stream',
  'Cache-Control': 'no-cache',
  Connection: 'keep-alive',
}

const patchElements = (res, selector, html) => {
  const lines = html.split('\n').map((l) => `data: elements ${l}`).join('\n')
  res.write(`event: datastar-patch-elements\ndata: mode inner\ndata: selector ${selector}\n${lines}\n\n`)
}

const patchSignals = (res, signals) => {
  res.write(`event: datastar-patch-signals\ndata: signals ${JSON.stringify(signals)}\n\n`)
}

async function readJson(req) {
  let body = ''
  for await (const chunk of req) {
    body += chunk
    if (body.length > 100_000) throw new Error('Request body too large')
  }
  return body ? JSON.parse(body) : {}
}

/** Yields text deltas from Claude. */
async function* liveStream(prompt, signal) {
  const client = new Anthropic()
  const stream = client.beta.messages.stream(
    {
      model: MODEL,
      max_tokens: 16000,
      // If the model declines a request, the API retries it on a fallback model.
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: { effort: 'low' },
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: prompt }],
    },
    { signal },
  )
  for await (const event of stream) {
    if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
      yield event.delta.text
    }
  }
  const message = await stream.finalMessage()
  if (message.stop_reason === 'refusal') throw new Error('The model declined this request.')
  if (message.stop_reason === 'max_tokens') throw new Error('The reply was cut off at the token limit.')
}

function describeError(err) {
  if (err instanceof Anthropic.AuthenticationError) return 'The API key was rejected.'
  if (err instanceof Anthropic.RateLimitError) return 'Rate limited. Try again in a moment.'
  if (err instanceof Anthropic.APIConnectionError) return 'Could not reach the Claude API.'
  if (err instanceof Anthropic.APIError) return `Claude API error ${err.status ?? ''}: ${err.message}`
  return err.message
}

async function generate(req, res) {
  const signals = await readJson(req)
  const prompt = String(signals.prompt ?? '').slice(0, 2000).trim()
  const unsafe = signals.unsafe === true
  res.writeHead(200, sseHeaders)
  if (!prompt) {
    patchSignals(res, { _status: 'Type a request first.' })
    return res.end()
  }

  const abort = new AbortController()
  res.on('close', () => abort.abort())

  let raw = ''
  let lastPatch = 0
  const flush = (done) => {
    // "unsafe" skips the sanitizer on purpose, to show what it prevents.
    const { html, blocked } = unsafe ? { html: raw, blocked: [] } : renderModelOutput(raw, done)
    patchElements(res, '#out', html)
    patchSignals(res, { _raw: raw, _blocked: blocked.join('\n') })
    lastPatch = Date.now()
  }

  canaryHits = 0
  patchSignals(res, { _busy: true, _status: 'Generating…', _raw: '', _blocked: '', _canary: 0 })
  patchElements(res, '#out', '')
  const started = Date.now()
  try {
    const source = LIVE ? liveStream(prompt, abort.signal) : mockStream(pickMock(prompt), abort.signal)
    for await (const delta of source) {
      raw += delta
      if (Date.now() - lastPatch >= PATCH_INTERVAL_MS) flush(false)
    }
    flush(true)
    const seconds = ((Date.now() - started) / 1000).toFixed(1)
    // Give anything the patched HTML triggered a moment to arrive, then report it.
    await new Promise((r) => setTimeout(r, 300))
    patchSignals(res, {
      _busy: false,
      _canary: canaryHits,
      _status: `Done in ${seconds}s, ${raw.length} characters from the model.`,
    })
  } catch (err) {
    if (!abort.signal.aborted) {
      console.error(err)
      patchSignals(res, { _busy: false, _status: describeError(err) })
    }
  }
  res.end()
}

// Stands in for a state-changing endpoint, e.g. "delete my account". The
// hostile mock tries to call it; with the sanitizer on, this count stays 0.
// One shared counter is enough for a single-user demo.
let canaryHits = 0
function canary(_req, res) {
  canaryHits += 1
  console.warn(`canary hit #${canaryHits}`)
  res.writeHead(200, sseHeaders)
  patchSignals(res, { _canary: canaryHits })
  res.end()
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.map': 'application/json' }

async function serveStatic(req, res) {
  const path = new URL(req.url, 'http://x').pathname
  const file = normalize(join(PUBLIC, path === '/' ? 'index.html' : path))
  if (!file.startsWith(PUBLIC)) return res.writeHead(403).end()
  try {
    const body = await readFile(file)
    res.writeHead(200, { 'Content-Type': `${MIME[extname(file)] ?? 'application/octet-stream'}; charset=utf-8` })
    res.end(body)
  } catch {
    res.writeHead(404).end('Not found')
  }
}

createServer(async (req, res) => {
  try {
    // Datastar adds its signals to GET requests as a query string, so match on the path.
    const { pathname } = new URL(req.url, 'http://localhost')
    if (req.method === 'POST' && pathname === '/generate') return await generate(req, res)
    if (req.method === 'POST' && pathname === '/canary') return canary(req, res)
    if (req.method === 'GET' && pathname === '/mode') {
      res.writeHead(200, sseHeaders)
      patchSignals(res, { _mode: LIVE ? `Live: ${MODEL}` : 'Mock mode (no API key set)' })
      return res.end()
    }
    if (req.method === 'GET') return await serveStatic(req, res)
    res.writeHead(405).end()
  } catch (err) {
    console.error(err)
    if (!res.headersSent) res.writeHead(500)
    res.end()
  }
}).listen(PORT, () => {
  console.log(`http://localhost:${PORT}  (${LIVE ? `live, ${MODEL}` : 'mock mode: set ANTHROPIC_API_KEY for live output'})`)
})
