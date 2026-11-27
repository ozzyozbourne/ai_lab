# Work in progress: paused

This course is being produced by a multi-agent workflow. It was paused on request.

## Status

| Stage | State |
|---|---|
| Research (10 areas) | Done: `research/*.md` |
| Plan + 2 gap-review rounds | Done: `PLAN.md` (final plan v3, 30 chapters), machine-readable copy in `_workflow/plan.json` |
| Foundation (shared CSS/JS, template, build scripts) | Done: `assets/`, `_template/`, `common/` |
| Chapters 01, 02 | Partly written when paused, not yet reviewed. Redo or finish them |
| Chapters 03 to 30 | Not started |
| Review/verify/fix x2, index.html, README.md, run_all.sh, final check | Not started |

## How to resume

- Same Claude Code session: the workflow cache is still there, so resume run `wf_e84dbd94-201`
  with the script in `_workflow/dpdk-course.workflow.js`. Finished agents (research, plan, foundation)
  are replayed from cache, and work continues from the chapter-writing phase.
- New session: the cache is gone. Rebuild DPDK with `common/build_dpdk.sh`, then run the
  implementation part of `_workflow/dpdk-course.workflow.js` with the plan loaded from
  `_workflow/plan.json` instead of re-running research and planning. The script's paths point at the
  old session's scratchpad and must be updated.
