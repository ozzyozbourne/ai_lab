# Work in progress: paused

This course is being produced by a multi-agent workflow. It was paused on request.

## Status

| Stage | State |
|---|---|
| Research (10 areas) | Done: `research/*.md` |
| Plan + 2 gap-review rounds | Done: `PLAN.md` (final plan v3, 30 chapters), machine-readable copy in `_workflow/plan.json` |
| Foundation (shared CSS/JS, template, build scripts) | Done: `assets/`, `_template/`, `common/` |
| Chapters 01 to 14 | First draft done, not yet reviewed |
| Chapter 15 | Partly written when paused (writer agent interrupted). Redo or finish it |
| Chapters 16 to 30 | Not started |
| Review/verify/fix x2, index.html, README.md, run_all.sh, final check | Not started |

## How to resume

- Same Claude Code session: the workflow cache is still there, so resume run `wf_e84dbd94-201`
  with the script in `_workflow/dpdk-course.workflow.js`. Finished agents (research, plan, foundation)
  and chapters 1-14 are replayed from cache, and work continues with chapter 15.
- New session: the cache is gone. Rebuild DPDK with `common/build_dpdk.sh`, then run the
  implementation part of `_workflow/dpdk-course.workflow.js` with the plan loaded from
  `_workflow/plan.json` instead of re-running research and planning. The script's paths point at the
  old session's scratchpad and must be updated.
