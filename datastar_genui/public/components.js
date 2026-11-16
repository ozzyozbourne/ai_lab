// The component half of the hybrid: a small fixed catalogue the model picks
// from. Each is a Rocket (Datastar) web component with a shadow root, so the
// model supplies only attributes and children and never touches the styling.
//
// Importing the bundle also starts Datastar for the page.
import { rocket } from './vendor/datastar-rocket.js'

const base = `
  :host { display: block; font: inherit; color: inherit; }
  * { box-sizing: border-box; }
`

rocket('ui-grid', {
  props: ({ number }) => ({ cols: number }),
  render: ({ html, props }) => {
    const cols = Math.min(4, Math.max(1, Math.round(props.cols) || 3))
    return html`
      <style>
        ${base}
        .grid { display: grid; gap: 12px; grid-template-columns: repeat(var(--cols), minmax(0, 1fr)); }
        @media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
      </style>
      <div class="grid" style="--cols:${cols}"><slot></slot></div>
    `
  },
})

rocket('ui-card', {
  props: ({ string }) => ({ title: string }),
  render: ({ html, props }) => html`
    <style>
      ${base}
      .card { border: 1px solid var(--line); border-radius: 12px; background: var(--surface); padding: 16px; }
      h3 { margin: 0 0 12px; font-size: 13px; font-weight: 600; color: var(--muted); letter-spacing: .02em; }
    </style>
    <div class="card">
      <h3>${props.title}</h3>
      <slot></slot>
    </div>
  `,
})

rocket('ui-stat', {
  props: ({ string }) => ({ label: string, value: string, delta: string }),
  render: ({ html, props }) => {
    const delta = props.delta.trim()
    const tone = delta.startsWith('-') ? 'down' : delta ? 'up' : 'none'
    return html`
      <style>
        ${base}
        .stat { border: 1px solid var(--line); border-radius: 12px; background: var(--surface); padding: 14px 16px; }
        .label { font-size: 13px; color: var(--muted); }
        .value { font-size: 28px; font-weight: 650; line-height: 1.2; font-variant-numeric: tabular-nums; }
        .delta { font-size: 13px; font-weight: 600; }
        .up { color: var(--good); } .down { color: var(--bad); } .none { display: none; }
      </style>
      <div class="stat">
        <div class="label">${props.label}</div>
        <div class="value">${props.value}</div>
        <div class="delta ${tone}">${delta}</div>
      </div>
    `
  },
})

rocket('ui-bars', {
  props: ({ json }) => ({ series: json }),
  render: ({ html, props }) => {
    const rows = (Array.isArray(props.series) ? props.series : [])
      .filter((d) => d && Number.isFinite(Number(d.value)))
      .slice(0, 24)
    const max = Math.max(1, ...rows.map((d) => Number(d.value)))
    return html`
      <style>
        ${base}
        .bars { display: flex; align-items: flex-end; gap: 10px; height: 170px; }
        .col { flex: 1; height: 100%; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; gap: 4px; min-width: 0; }
        .bar { width: 100%; max-width: 56px; border-radius: 6px 6px 0 0; background: var(--accent); transform-origin: bottom; animation: grow .5s ease-out both; }
        .num { font-size: 12px; font-variant-numeric: tabular-nums; }
        .lab { font-size: 12px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
        @keyframes grow { from { transform: scaleY(0); } }
        @media (prefers-reduced-motion: reduce) { .bar { animation: none; } }
      </style>
      <div class="bars">
        ${rows.map(
          (d) => html`
            <div class="col">
              <span class="num">${String(d.value)}</span>
              <div class="bar" style="height:${Math.max(2, (Number(d.value) / max) * 78)}%"></div>
              <span class="lab">${String(d.label ?? '')}</span>
            </div>
          `,
        )}
      </div>
    `
  },
})

rocket('ui-callout', {
  props: ({ string }) => ({ tone: string }),
  render: ({ html, props }) => {
    const tone = ['good', 'warn'].includes(props.tone) ? props.tone : 'info'
    return html`
      <style>
        ${base}
        .callout { border-left: 4px solid var(--accent); border-radius: 8px; background: var(--surface); padding: 12px 14px; }
        .good { border-color: var(--good); } .warn { border-color: var(--warn); }
      </style>
      <div class="callout ${tone}"><slot></slot></div>
    `
  },
})
