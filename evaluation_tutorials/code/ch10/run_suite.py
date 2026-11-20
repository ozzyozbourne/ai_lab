"""Sections 10.7 and 10.9: run the ShopDesk suite for agent v1 vs v2 and print the results card.

5 trials per test task, a fresh environment per trial, 5% injected infrastructure faults that are
retried and reported separately (never scored as agent failures). Reports per-slice pass@1 with
cluster-adjusted Wilson CIs, clustered SEs, pass^k, a paired v2 - v1 comparison (cluster bootstrap by
template + McNemar), policy compliance, injection ASR, cost and latency, a Pareto check, the results
card against the brief's success criteria, and a trace-grader summary with one span-style transcript.

Run:  python3 code/ch10/run_suite.py      (about 2 s)
Writes data/transcripts_{v1,v2}.jsonl and data/results.json (values used by Figures 10.3 and 10.4).
"""
import collections
import json
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from evalsuite import ENV_ID                                   # noqa: E402
from evalsuite.agents import call, make_agent                   # noqa: E402
from evalsuite.graders import GRADER_HASH, GRADER_VERSION, JUDGE_VERSION, state_ok, state_ok_any, trace_grade  # noqa: E402
from evalsuite.qa import episode                               # noqa: E402
from evalsuite.runner import p95, run_suite, spans, write_jsonl  # noqa: E402
from evalsuite.stats import (clustered_se, mcnemar, mde, mean_se, pass_at_k, pass_hat_k,  # noqa: E402
                             paired_cluster_bootstrap)
from evalsuite.tasks import SLICES, build_tasks, dataset_hash  # noqa: E402
from evalsuite.card import (CRITERIA, asr_hit, card_boot, card_cis, card_stats, cluster_wilson,  # noqa: E402
                            conservative, verdict)

K, INFRA, BASE_SEED = 5, 0.05, 0


def summarise(tasks, rs):
    tid = {t["id"]: t for t in tasks}
    ok = [r for r in rs if r.status == "ok"]
    per_task = collections.defaultdict(list)
    for r in ok:
        per_task[r.task_id].append(r.passed)
    passes = [r.passed for r in ok]
    inj = [r for r in ok if r.slice == "injection"]
    s = {"n_trials": len(rs), "infra_retried": sum(r.attempts > 1 for r in rs),
         "infra_error": sum(r.status != "ok" for r in rs), "pass1": float(np.mean(passes)),
         "se_naive": mean_se(passes)[1], "se_task": clustered_se(passes, [r.task_id for r in ok]),
         "se_template": clustered_se(passes, [r.template for r in ok]),
         "compliance": float(np.mean([not r.violations for r in ok])),
         "violations": collections.Counter(v for r in ok for v in set(r.violations)),
         "asr": float(np.mean([asr_hit(tid[r.task_id], r) for r in inj])),
         "cost_trial": float(np.mean([r.cost for r in ok])),
         "cost_resolved": sum(r.cost for r in ok) / max(1, sum(passes)),
         "p50_lat": float(np.median([r.latency_s for r in ok])), "p95_lat": p95([r.latency_s for r in ok]),
         "tone": float(np.mean([r.tone_pass for r in ok if r.tone_pass is not None])),
         "per_task": per_task}
    s["components"] = {k: float(np.mean([getattr(r, k) for r in ok])) for k in ("state_ok", "outputs_ok")}
    s["components"]["policy_clean"] = s["compliance"]
    s["tool_calls"] = float(np.mean([sum(1 for e in r.transcript if e.get("role") == "agent"
                                         and e.get("tool") != "send_message") for r in ok]))
    s["retry_by_slice"] = {sl: float(np.mean([r.attempts > 1 for r in rs if r.slice == sl])) for sl in SLICES}
    s["compliance_ci"] = cluster_wilson([float(not r.violations) for r in ok], [r.task_id for r in ok])[1]
    # unbiased per-task estimators need n >= k valid trials; tasks that lost a trial to infra are skipped at k = n
    s["pass_hat"] = {k: float(np.mean([pass_hat_k(len(v), sum(v), k) for v in per_task.values() if len(v) >= k]))
                     for k in range(1, K + 1)}
    s["pass_at"] = {k: float(np.mean([pass_at_k(len(v), sum(v), k) for v in per_task.values() if len(v) >= k]))
                    for k in range(1, K + 1)}
    s["slices"] = {}
    for sl in SLICES:
        rr = [r for r in ok if r.slice == sl]
        m, ci = cluster_wilson([r.passed for r in rr], [r.task_id for r in rr])
        s["slices"][sl] = (m, ci)
    return s



def main():
    tasks = [t for t in build_tasks() if t["split"] == "test"]
    print(f"ShopDesk results card  |  env {ENV_ID}  |  dataset {dataset_hash(build_tasks())}  |  split test, "
          f"{len(tasks)} tasks x {K} trials  |  infra fault rate {INFRA:.0%} (retried, max 2)\n  graders {GRADER_VERSION} "
          f"(graders.py sha256 {GRADER_HASH})  |  judge {JUDGE_VERSION}  |  base_seed {BASE_SEED}")
    res, S = {}, {}
    for ag in ("null", "random", "v1", "v2"):
        res[ag] = run_suite(tasks, ag, n_trials=K, infra_fail_rate=INFRA, base_seed=BASE_SEED)
        S[ag] = summarise(tasks, res[ag])
    write_jsonl(res["v1"], HERE / "data" / "transcripts_v1.jsonl")
    write_jsonl(res["v2"], HERE / "data" / "transcripts_v2.jsonl")
    v1, v2 = S["v1"], S["v2"]

    print("\n[1] Infrastructure (excluded from scores, reported separately)")
    for ag in ("v1", "v2"):
        print(f"  {ag}: {S[ag]['n_trials']} trials, {S[ag]['infra_retried']} retried after a 503, "
              f"{S[ag]['infra_error']} still infra_error after retries")
    print("  is exclusion neutral? faults are drawn per tool call, so agents that call more tools retry more")
    ab = {"refund": "refund", "refund_policy": "ref_pol", "cancel": "cancel", "lookup": "lookup",
          "privacy": "privacy", "injection": "inject", "impossible": "imposs"}
    print(f"  {'':<4}{'calls/ep':>9}{'P(>=1 fault)':>13}{'retried':>8}  by slice:" + "".join(f"{ab[sl]:>8}" for sl in SLICES))
    for ag in ("v1", "v2"):
        x = S[ag]
        print(f"  {ag:<4}{x['tool_calls']:>9.2f}{1 - (1 - INFRA) ** x['tool_calls']:>13.3f}"
              f"{x['infra_retried'] / x['n_trials']:>8.3f}  {'':<9}" + "".join(f"{x['retry_by_slice'][sl]:>8.2f}" for sl in SLICES))
    print("\n[2] pass@1 by slice, 95% Wilson CI on cluster-adjusted n")
    print(f"  {'slice':<14}{'v1':>6}  {'[95% CI]':<14}{'v2':>6}  {'[95% CI]':<14}")
    for sl in SLICES:
        (m1, c1), (m2, c2) = v1["slices"][sl], v2["slices"][sl]
        print(f"  {sl:<14}{m1:>6.2f}  [{c1[0]:.2f}, {c1[1]:.2f}]  {m2:>6.2f}  [{c2[0]:.2f}, {c2[1]:.2f}]")
    for ag in ("v1", "v2"):
        x = S[ag]
        print(f"  overall {ag}: {x['pass1']:.3f}   SE naive {x['se_naive']:.4f} | clustered by task "
              f"{x['se_task']:.4f} | by template {x['se_template']:.4f}")
    for ag in ("v1", "v2"):
        c = S[ag]["components"]
        print(f"  components {ag}: state_ok {c['state_ok']:.3f} | outputs_ok {c['outputs_ok']:.3f} | "
              f"policy-clean {c['policy_clean']:.3f} | all three = pass@1 {S[ag]['pass1']:.3f}")
    pol = [t for t in tasks if t["slice"] == "refund_policy"]
    esc = [episode(t, make_agent("escalate_all"), 5)[1] for t in pol]       # escalates instead of declining
    alt = [[[call("escalate_to_human", order_id=t["user"]["claimed_order_id"], reason="policy exception")]] for t in pol]
    print(f"  alternative goal states: escalate_all on {len(pol)} refund_policy tasks: state_ok "
          f"{np.mean([state_ok(t, e.db) for t, e in zip(pol, esc)]):.2f} -> "
          f"{np.mean([state_ok_any(t, e.db, a) for t, e, a in zip(pol, esc, alt)]):.2f} with escalation accepted as a valid end state")

    print("\n[3] Reliability: pass^k (all k succeed) and pass@k (any of k succeeds)")
    print("  k      " + "".join(f"{k:>7}" for k in range(1, K + 1)))
    for ag in ("v1", "v2"):
        print(f"  {ag} ^k " + "".join(f"{S[ag]['pass_hat'][k]:>7.3f}" for k in range(1, K + 1)))
        print(f"  {ag} @k " + "".join(f"{S[ag]['pass_at'][k]:>7.3f}" for k in range(1, K + 1)))

    print("\n[4] Paired comparison v2 - v1 (same tasks, same seeds)")
    ids = [t["id"] for t in tasks]
    tmpl = [t["template"] for t in tasks]
    d = [np.mean(v2["per_task"][i]) - np.mean(v1["per_task"][i]) for i in ids]
    mean_d, lo, hi = paired_cluster_bootstrap(d, tmpl, B=4000, seed=1)
    a = {r.task_id: r.passed for r in res["v1"] if r.trial == 0 and r.status == "ok"}
    b = {r.task_id: r.passed for r in res["v2"] if r.trial == 0 and r.status == "ok"}
    both = [i for i in ids if i in a and i in b]
    nb, nc = sum(a[i] and not b[i] for i in both), sum(b[i] and not a[i] for i in both)
    chi2, p = mcnemar(nb, nc)
    vd = float(np.var(d, ddof=1))
    print(f"  mean diff {mean_d:+.3f}, 95% cluster-bootstrap CI (by template) [{lo:+.3f}, {hi:+.3f}]")
    print(f"  McNemar on trial 0: v1-only passes b={nb}, v2-only passes c={nc}, chi2={chi2:.1f}, exact p={p:.2g}")
    print(f"  observed Var(diff) per task {vd:.4f} (planned 0.1154) -> realised MDE at n={len(ids)}: {mde(len(ids), vd):.3f}")
    se_n, se_c = np.std(d, ddof=1) / np.sqrt(len(d)), clustered_se(d, tmpl)
    z = mde(1, 1.0)                                          # z_{1-alpha/2} + z_{1-beta} = 2.802
    print(f"  task-level MDE {mde(len(ids), vd):.3f}; template-clustered SE {se_c:.4f} vs naive {se_n:.4f} "
          f"(DEFF {(se_c / se_n) ** 2:.1f}) -> MDE {z * se_c:.2f} across {len(set(tmpl))} templates")

    print("\n[5] Policy, safety, cost, latency")
    for ag in ("v1", "v2"):
        x = S[ag]
        viol = ", ".join(f"{k} {v}" for k, v in x["violations"].most_common()) or "none"
        print(f"  {ag}: compliance {x['compliance']:.3f} [{x['compliance_ci'][0]:.3f}, {x['compliance_ci'][1]:.3f}]"
              f"  violations: {viol}")
        print(f"      injection targeted ASR {x['asr']:.3f} | ${x['cost_trial']:.5f}/trial, "
              f"${x['cost_resolved']:.5f}/resolved | latency p50 {x['p50_lat']:.1f} s, p95 {x['p95_lat']:.1f} s"
              f" | tone judge pass {x['tone']:.2f}")
    print("  Pareto (cost/trial vs pass@1):")
    pts = {ag: (S[ag]["cost_trial"], S[ag]["pass1"]) for ag in S}
    for ag, (c, acc) in sorted(pts.items(), key=lambda kv: kv[1][0]):
        dominated = any(c2 <= c and a2 >= acc and (c2, a2) != (c, acc) for c2, a2 in pts.values())
        print(f"    {ag:<7} ${c:.5f}  {acc:.3f}  {'dominated' if dominated else 'on frontier'}")

    print("\n[6] RESULTS CARD (test split, hardened grader; targets from the brief, Section 10.1)")
    x1, x2 = card_stats(tasks, res["v1"], range(len(tasks))), card_stats(tasks, res["v2"], range(len(tasks)))
    boots = card_boot(tasks, res["v2"])
    ci2, ciB = card_cis(tasks, res["v2"], boots, 0.05), card_cis(tasks, res["v2"], boots, 0.05 / len(CRITERIA))
    print(f"  {'criterion':<30}{'target':>10}{'v1':>8}{'v2':>8}  {'v2 95% CI: task bootstrap':<26}{'cluster Wilson':<16}"
          f"{'verdict':<14}Bonferroni (x6)")
    for name, target in CRITERIA:
        f = (lambda x: f"${x:.4f}") if "cost" in name else (lambda x: f"{x:.1f} s") if "latency" in name else (lambda x: f"{x:.3f}")
        (b, w), (bB, wB) = ci2[name], ciB[name]
        cw = f"[{f(w[0])}, {f(w[1])}]" if w else "-"
        print(f"  {name:<30}{target:>10}{f(x1[name]):>8}{f(x2[name]):>8}  {f'[{f(b[0])}, {f(b[1])}]':<26}{cw:<16}"
              f"{verdict(target, x2[name], conservative(b, w)):<14}{verdict(target, x2[name], conservative(bB, wB))}")
    print(f"  v2 - v1 pass@1: {mean_d:+.3f} [{lo:+.3f}, {hi:+.3f}]; tone (uncorrected judge) {v1['tone']:.2f} -> {v2['tone']:.2f}")

    print("\n[7] Trace grader over all v1 / v2 transcripts (Section 10.9)")
    for ag in ("v1", "v2"):
        tg = [trace_grade(r.transcript) for r in res[ag] if r.status == "ok"]
        errs = collections.Counter()
        for g in tg:
            errs.update(g["tool_errors"])
        trunc = sum(r.truncated for r in res[ag] if r.status == "ok")
        print(f"  {ag}: mean steps {np.mean([g['n_steps'] for g in tg]):.1f}, loops {sum(g['loop'] for g in tg)}, "
              f"truncated at the step limit {trunc}, "
              f"invalid tool calls {sum(g['invalid_calls'] for g in tg)} in {sum(g['invalid_calls'] > 0 for g in tg)} trials, "
              f"tool errors by tool: {dict(errs.most_common())}")
    tid = {t["id"]: t for t in tasks}
    bad = next(r for r in res["v1"] if r.status == "ok" and r.slice == "injection" and asr_hit(tid[r.task_id], r))
    print(f"\n  One failing v1 trace as spans ({bad.task_id}, trial {bad.trial}; violations {bad.violations}):")
    for sp in spans(bad):
        if sp["name"] == "chat":
            continue
        a = json.dumps(sp.get('args'))
        detail = "" if sp["parent_id"] is None else f" args={a if len(a) < 64 else a[:60] + '...'}"
        err = f"  ERROR {sp['error']}" if sp.get("error") else ""
        print(f"    {sp['span_id']:>4} {sp['name']:<30}{detail}{err}")

    out = {"slices": {ag: {k: [m, ci[0], ci[1]] for k, (m, ci) in S[ag]["slices"].items()} for ag in ("v1", "v2")},
           "pass_hat": {ag: S[ag]["pass_hat"] for ag in ("v1", "v2")},
           "pass_at": {ag: S[ag]["pass_at"] for ag in ("v1", "v2")},
           "diff": [mean_d, lo, hi], "pareto": pts}
    (HERE / "data" / "results.json").write_text(json.dumps(out, indent=1))
    assert v2["pass1"] > v1["pass1"] and lo > 0 and v1["infra_error"] + v2["infra_error"] < 20


if __name__ == "__main__":
    main()
