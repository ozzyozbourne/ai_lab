# Vendored third-party assets

Loaded from local files so the book renders fully offline (only the Three.js hero on index.html uses the CDN).

| Path | Source | Version | License |
|---|---|---|---|
| `prism/prism.min.js` | https://cdn.jsdelivr.net/npm/prismjs@1.30.0/prism.min.js | 1.30.0 | MIT |
| `prism/prism-{rust,zig,odin,bash}.min.js` | `prismjs@1.30.0/components/` | 1.30.0 | MIT |
| `fonts/inter-*.woff2` | `@fontsource-variable/inter@5.3.0/files/` (latin, latin-ext) | 5.3.0 | SIL OFL 1.1 |
| `fonts/jetbrains-mono-*.woff2` | `@fontsource/jetbrains-mono@5.3.0/files/` (latin 400/700/400-italic) | 5.3.0 | SIL OFL 1.1 |

`fonts/fonts.css` is a hand-written subset of the fontsource `index.css` pointing at these files.
