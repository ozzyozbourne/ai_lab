# Chapter 3 code: Building Eval Datasets and Fighting Contamination

Standard library + NumPy only. No network, no API keys; every model, rater and corpus is a seeded mock.
Run any file from any directory, or all of them with `python3 code/run_all.py ch03`.
`_common.py` holds the mock benchmark generator, a count-based bigram LM and a rank-based AUROC (not run directly).
`golden_dataset.py` writes its JSONL files and manifests to `code/ch03/out/`.

| File | Section | What it shows | Command |
|---|---|---|---|
| `golden_dataset.py` | 3.2 `#golden` | `EvalRecord` dataclass, JSONL, sha256 of canonical JSON, per-version manifest, retire-don't-edit, immutability check catching a silent edit | `python3 code/ch03/golden_dataset.py` |
| `stratified_sampler.py` | 3.4 `#sampling`, Fig 3.1 | worked 84% +/- 5.1 points; 10,000 mock logs (faq .7 / billing .2 / legal .1); SRS, proportional, oversample+reweight, pooled-oversample, failure-biased over 1,000 repetitions | `python3 code/ch03/stratified_sampler.py` |
| `agreement.py` | 3.5 `#labelling`, Fig 3.2 | Cohen's kappa 0.659 worked example; kappa under skewed prevalence; Fleiss' kappa before/after a guide revision; adjudication queue | `python3 code/ch03/agreement.py` |
| `label_error_audit.py` | 3.5 `#label-audit` | 5% flipped gold labels, 3 mock models, consensus flagging (precision/recall), corrected labels flip the ranking of two close models | `python3 code/ch03/label_error_audit.py` |
| `sample_size.py` | 3.6 `#size` | 97/385/1068/9604 for +/-10/5/3/1 points; 1,247 per arm for 70 vs 75%; paired designs (independent systems disagree on 40% of items, so pairing gains nothing; 10% -> 306 items); rule of three; Monte-Carlo coverage of Wald vs Wilson | `python3 code/ch03/sample_size.py` |
| `synthetic_tuples.py` | 3.7 `#synthetic`, Fig 3.3 | persona x feature x scenario tuples, validity filter, templated mock LLM, Evol-style rewrites, distinct-n, Jaccard near-duplicate rate | `python3 code/ch03/synthetic_tuples.py` |
| `simpsons_slices.py` | 3.8 `#slices` | Simpson's paradox across slices and direct standardisation to the production mix | `python3 code/ch03/simpsons_slices.py` |
| `ngram_decontam.py` | 3.10 `#detect-corpus` | 13-gram overlap (copy 1.00, number swap 0.21, paraphrase 0.00), Janitor-style window removal, pure-Python MinHash, LSH banding (P(0.7)=0.613 for b=16, r=8) and bucket collisions | `python3 code/ch03/ngram_decontam.py` |
| `rephrase_detect.py` | 3.10 `#detect-rephrase` | retrieve-then-judge stage of the layered recipe: TF-IDF cosine retrieval puts the paraphrase at rank 1; a deterministic mock judge (stand-in for the strong-LLM judge of Yang et al.) confirms it and rejects the 3 distractors that pass cosine 0.1 | `python3 code/ch03/rephrase_detect.py` |
| `mock_lm_minkprob.py` | 3.11 `#detect-blackbox`, Fig 3.4 | PPL, zlib ratio, Min-K%, Min-K%++ and a blind baseline; AUROC on same-distribution vs shifted non-members; set-level test | `python3 code/ch03/mock_lm_minkprob.py` |
| `permutation_test.py` | 3.11 `#detect-blackbox` | Oren et al. sharded rank-comparison test: z and one-sided p for canonical-order, shuffled and clean models | `python3 code/ch03/permutation_test.py` |
| `canary.py` | 3.12 `#prevention` | BIG-bench-style canary stamping, corpus filter, header-less repost, canary-completion probe (rank among 101 GUIDs) | `python3 code/ch03/canary.py` |
| `time_split.py` | 3.12 `#prevention`, Fig 3.5 | accuracy by release month around a cutoff; pre/post gap with bootstrap CI; difference-in-differences vs a clean model; `gap_ci`/`did_ci` take an optional analysis `cutoff=` (Exercise 3.6) | `python3 code/ch03/time_split.py` |
| `twin_gap_constat.py` | 3.12 `#prevention` | worked GSM8K/GSM1k twin gap (z = 4.59); naive z-test vs simplified ConStat over 10 reference models | `python3 code/ch03/twin_gap_constat.py` |

Every script asserts the worked numbers quoted in the chapter, so a passing run means the text and the code agree.
