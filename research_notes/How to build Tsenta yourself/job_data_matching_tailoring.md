# Job Discovery, Matching and Resume Tailoring Layer for an AI Job-Application Agent

## (a) Job data sources: ATS APIs, board-token discovery, aggregators, scraping and legal risk, freshness/dedupe/volume

### Takeaway
The cleanest high-volume, high-freshness source is the public, unauthenticated JSON job-board endpoints of the major ATSs (Greenhouse, Lever, Ashby, SmartRecruiters, plus Workday's undocumented `cxs` endpoint). The hard part is building and maintaining the list of company slugs. Paid aggregators (Fantastic.jobs, TheirStack, Coresignal and others) cover about 10M jobs a month for roughly $1.50–$9 per 1K jobs. Scraping LinkedIn or Indeed (for example with JobSpy) works technically but carries real breach-of-contract risk, as hiQ v. LinkedIn showed.

### Cited Findings
**Greenhouse Job Board API**
- `GET https://boards-api.greenhouse.io/v1/boards/{board_token}/jobs` needs no auth. Only the application POST needs Basic Auth. `?content=true` adds the full description, departments and offices. — [Greenhouse Job Board docs](https://docs.greenhouse.io/job-board.html) (formerly developers.greenhouse.io, which now 301-redirects)
- Default fields are `id`, `internal_job_id`, `title`, `updated_at`, `requisition_id`, `location.name`, `absolute_url`, `language`, `metadata` and `meta.total`. `pay_transparency` and `questions` are query params only on the single-job endpoint `GET /v1/boards/{board_token}/jobs/{job_id}`. — [Greenhouse docs](https://docs.greenhouse.io/job-board.html)
- No numeric rate limit is published. The docs say only that requests "may be rate limited for security and traffic reasons." — [Greenhouse docs](https://docs.greenhouse.io/job-board.html)

**Lever Postings API**
- `GET https://api.lever.co/v0/postings/{site}?mode=json`, with an EU host at `https://api.eu.lever.co/v0/postings/{site}`. It is HTTPS only. Params are `skip`, `limit`, `location`, `commitment`, `team`, `department`, `level` and `group`. Multiple filter values are OR'ed and case sensitive. — [lever/postings-api GitHub](https://github.com/lever/postings-api)
- Fields include `id`, `text`, `categories` (location, commitment, team, department, allLocations), `country`, `description`/`descriptionPlain`, `lists`, `additional`, `salaryRange` (currency, interval, min, max), `salaryDescription`, `workplaceType`, `hostedUrl` and `applyUrl`. — [lever/postings-api](https://github.com/lever/postings-api)
- Apply is `POST /v0/postings/{site}/{id}?key=APIKEY`. The key comes from the employer's Super Admin, so a third-party agent cannot use this path. POSTs are rate-limited to 2/sec with HTTP 429. No GET limit is stated. — [lever/postings-api](https://github.com/lever/postings-api)

**Ashby Posting API**
- `GET https://api.ashbyhq.com/posting-api/job-board/{JOB_BOARD_NAME}?includeCompensation=true`. The board name is the last segment of `jobs.ashbyhq.com/{name}`. — [Ashby docs](https://developers.ashbyhq.com/docs/public-job-posting-api)
- Fields include `title`, `department`, `team`, `publishedAt`, `isListed`, `location`, `address.postalAddress`, `secondaryLocations`, `workplaceType` (OnSite/Remote/Hybrid), `isRemote`, `employmentType`, `descriptionHtml`, `descriptionPlain`, `jobUrl`, `applyUrl` and `compensation` (tiers and summary). Auth and rate limits are not documented. — [Ashby docs](https://developers.ashbyhq.com/docs/public-job-posting-api)

**SmartRecruiters Posting API**
- `GET https://api.smartrecruiters.com/v1/companies/{companyIdentifier}/postings` and `/postings/{postingId}` support offset/limit paging and country/city filters. — [SmartRecruiters dev docs](https://developers.smartrecruiters.com/reference/v1listpostings.md)
- It works with no key for companies that enable the public feed. There is no cross-company directory, so identifiers must be known in advance. — [JobsPipe SmartRecruiters source page](https://jobspipe.dev/sources/smartrecruiters) (third-party, unverified)

**Workday (undocumented)**
- Community scrapers POST to `https://{tenant}.wd{N}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/jobs` with the JSON body `{"appliedFacets":{}, "limit":20, "offset":0, "searchText":""}`. They then GET `/job/{externalPath}` for the description and requisition ID. — [Apify Workday actors, e.g. arman-bd](https://apify.com/arman-bd/workday-jobs-scraper)
- Reports say `limit` above 20 returns HTTP 400, the `total` count is reliable only on the first page, and facet IDs are tenant-specific. Workday can change the endpoint without notice. — [Apify Workday scraper listings](https://apify.com/bovi/workday-jobs-scraper.md) (community, unverified)

**Discovering board tokens/slugs**
- Slugs are the path segment in the careers URL: `boards.greenhouse.io/<slug>`, `jobs.lever.co/<slug>`, `jobs.ashbyhq.com/<slug>`. They often differ from the company name, for example aircall.io is `aircallioinc` on Greenhouse. — [Apify multi-ATS actors](https://apify.com/wickfeed/ats-company-discovery)
- One discovery method queries the Common Crawl URL index (e.g. CC-MAIN-2026-25 and CC-MAIN-2026-21) for each vendor's host pattern. One actor found about 1,990 boards this way: Greenhouse 872, Workable 380, Ashby 373, Recruitee 300, EU-Lever 65. — [Apify ats-company-discovery](https://apify.com/wickfeed/ats-company-discovery.md)
- Slugs go stale. Boards 404 when a company switches vendor, so lists must be re-verified regularly. — [LastRound AI ATS directory](https://datahub.io/lastroundai-hiring-data/lastroundai-hiring-data/ats-directory)

**Aggregators / commercial APIs** (vendor and competitor sources; prices change, so verify live)
- Fantastic.jobs claims 200k+ career sites across 54 ATSs plus 10M+ LinkedIn/Wellfound/YC jobs a month, with each ATS polled hourly. — [fantastic.jobs/api](https://fantastic.jobs/api)
- TheirStack claims 16,000+ sources including LinkedIn, Indeed and ATSs, at about 9.8M jobs a month. It lists Fantastic.jobs at about 10M a month with freshness under 3 hours. — [TheirStack vs Fantastic.jobs](https://theirstack.com/en/comparisons/theirstack-vs-fantasticjobs.md) (biased vendor comparison)
- Reported pricing: Fantastic.jobs entry plan about $95 for 20K jobs (≈$4.75/1K), with per-ATS feeds at $1–9/1K. TheirStack starts at $59/month with 200 free credits, and its top tier is about $1.50/1K. — [Bright Data comparison](https://brightdata.com/blog/web-data/best-job-apis); [JobsPipe TheirStack alternatives](https://jobspipe.dev/blog/theirstack-alternatives)
- Apify actors for Greenhouse/Lever/Ashby/Workday cost about $0.90–$1.50 per 1K jobs. — [Apify bovi Greenhouse/Lever/Ashby](https://apify.com/bovi/greenhouse-lever-ashby-job-scraper)

**JobSpy (open-source scraper)**
- `pip install -U python-jobspy` (Python 3.10+). It also runs as an MCP server via `uvx mcp-jobspy@latest`. It supports LinkedIn, Indeed, ZipRecruiter, Glassdoor, SEEK, Naukri, HelloWork, Bayt and BDJobs. Google Jobs is listed but currently unavailable. — [speedyapply/JobSpy](https://github.com/speedyapply/JobSpy)
- Params are `results_wanted`, `hours_old`, `is_remote`, `proxies` (round-robin), `fetch_description` (replaces the deprecated `linkedin_fetch_description`) and `country_indeed`. — [JobSpy](https://github.com/speedyapply/JobSpy)
- Limits: most boards cap a search at about 1,000 jobs. LinkedIn returns 429 on bursts, which clears in about a minute, so proxies are recommended. Glassdoor rate-limits above about 2 requests/sec. Indeed is described as the best scraper with no rate limiting. — [JobSpy](https://github.com/speedyapply/JobSpy)
- Output fields include `id`, `site`, `job_url`, `job_url_direct`, `title`, `company`, `location`, `date_posted`, `job_type`, `min_amount`/`max_amount`/`interval`/`currency`, `is_remote`, `job_level`, `description`, company metadata and `skills`. — [JobSpy](https://github.com/speedyapply/JobSpy)

**Legal / ToS risk**
- hiQ v. LinkedIn (N.D. Cal., Nov 2022): the court held that anti-scraping and anti-fake-profile terms in the User Agreement are enforceable in contract. hiQ breached them through its scraping, its use of scraped data and its use of "turkers" running fake profiles. — [Proskauer New Media Law](https://newmedialaw.proskauer.com/2022/11/11/court-finds-hiq-breached-linkedins-terms-prohibiting-scraping-but-in-mixed-ruling-declines-to-grant-summary-judgment-to-either-party-as-to-certain-key-issues/)
- The case ended in Dec 2022 with a stipulated $500,000 judgment against hiQ and a confidential settlement. — [Morgan Lewis](https://www.morganlewis.com/blogs/sourcingatmorganlewis/2022/12/linkedin-v-hiq-landmark-data-scraping-suit-provides-guidance-to-data-scrapers-and-web-operators); [ZwillGen](https://www.zwillgen.com/alternative-data/hiq-v-linkedin-wrapped-up-web-scraping-lessons-learned/)

### Inferences
- Recommended architecture: a slug registry table (`ats_vendor`, `slug`, `last_ok_at`, `last_job_count`, `status`) seeded from Common Crawl, sitemaps and search-engine `site:` queries. Poll Greenhouse, Lever, Ashby and SmartRecruiters hourly to daily with conditional diffing, and poll Workday more gently (20/page plus a detail fetch per job). Use a paid aggregator for long-tail and LinkedIn-sourced jobs rather than scraping LinkedIn yourself.
- Dedupe in layers. First, exact match on (ats_vendor, slug, external_job_id). Then fuzzy match on normalized company, title and location, plus a MinHash/SimHash of the description, to catch the same job on LinkedIn, Indeed and the ATS. Prefer the ATS record as canonical because it carries the real apply URL. Mark a job closed when it disappears from the board feed, which is the strongest freshness signal available.
- The ATS feeds' native timestamps (Greenhouse `updated_at`, Ashby `publishedAt`) support "posted in the last 24h" filters. Lever's list response has no obvious published timestamp field in the docs (verify `createdAt` empirically).
- LinkedIn and Indeed scraping with logged-out sessions is lower risk than logged-in or fake-account scraping, which was the conduct penalized in hiQ. Neither is risk-free, and a commercial product should rely on licensed aggregators or ATS feeds.

### Gaps
- No official rate limits were found for the Greenhouse, Ashby or SmartRecruiters GET endpoints.
- No independent audit of aggregator coverage or freshness was found. All numbers are vendor claims.
- Adzuna, Coresignal and Google Jobs (via SerpApi and similar) were not individually verified in this pass. Indeed's and LinkedIn's current official partner APIs were not checked. Indeed's ToS text was not fetched.
- No open slug dataset on GitHub was confirmed.

## (b) Resume/profile parsing: LLM structured extraction vs libraries, JSON Resume schema

### Takeaway
The 2025–2026 default is to extract text (PDF/DOCX to text, layout-aware where possible) and then run LLM structured-output extraction into a JSON Resume-style schema. Commercial parsers like Affinda claim 95–99% field accuracy, but no independent benchmark versus LLMs exists. Older libraries like pyresparser (spaCy/NLTK-era) were not found to be competitive in any 2025+ source.

### Cited Findings
- JSON Resume schema v1.7.1 has the top-level sections basics, work, volunteer, education, awards, certificates, publications, skills, languages, interests, references, projects and meta. `work` has name, location, description, position, url, startDate, endDate, summary, highlights and keywords. `skills` has name, level and keywords. `basics` has name, label, email, phone, url, summary, location{city, countryCode, region…} and profiles[]. — [jsonresume.org/schema](https://jsonresume.org/schema)
- Affinda claims 95%+ accuracy, and elsewhere 99%+, on key fields, and "up to 50% greater accuracy" than competitors. These are vendor-reported and inconsistent across its own pages. — [Affinda job-board parser](https://www.affinda.com/resume-parser-for-job-boards); [Affinda NextGen press release](https://www.aap.com.au/aapreleases/cision20240408ae82776/)
- Independent benchmarks of resume parsers are scarce, and most accuracy figures are vendor-reported. LLM parsers handle context better, for example "Python" the language versus a company named Python. — [Pin.com comparison](https://ghost.pin.com/best-resume-parsing-tools/)
- A 2025 arXiv paper (2510.09722) proposes a layout-aware pipeline with a fine-tuned compact 0.6B LLM for resume extraction and reports top accuracy against baselines. It argues that rule-based and statistical parsers fail to generalize. — [arXiv 2510.09722](https://arxiv.org/html/2510.09722v1)
- RenderCV uses a YAML CV format with a published JSON Schema, which doubles as a canonical "master profile" format. — [rendercv GitHub](https://github.com/rendercv/rendercv)
- Resume Matcher keeps a "master resume" as the source of truth from which tailored versions are derived. — [Resume-Matcher](https://github.com/srbhr/Resume-Matcher)

### Inferences
- Pipeline:
  1. Extract text with pdfplumber/pymupdf (or docling or unstructured for layout).
  2. Call an LLM with JSON-schema-constrained output into JSON Resume, extended with `id` on each bullet, normalized dates, `skills_normalized` (mapped to ESCO/O*NET or Lightcast taxonomies) and `years_experience_by_skill`.
  3. Validate with Pydantic.
  4. Show a human-confirmation UI so the user owns the master profile.
- Add agent-specific profile fields JSON Resume lacks: work authorization/visa status per country, sponsorship need, salary floor, relocation and remote preference, target titles and seniority, and EEO answers. Application forms need these constantly.
- Giving every master bullet a stable ID is what makes anti-fabrication checking possible later, in section (d).

### Gaps
- No rigorous LLM-vs-Affinda/Textkernel/Sovren accuracy comparison was found.
- pyresparser maintenance status was not verified in this pass.

## (c) Matching and ranking: embeddings, hybrid search, filters, LLM re-ranking, explanations, feedback learning

### Takeaway
Use a multi-stage funnel. First apply hard filters (location/remote, visa, seniority, salary, recency) in SQL. Then run hybrid retrieval: BM25/tsvector plus a dense embedding, fused with RRF (k≈60). Then run an LLM listwise re-rank on the top 20–50 that emits a 0–100 score with a grounded explanation. Research in 2026 (ConFit v3) shows a fine-tuned 8–32B listwise re-ranker beats prompted GPT-5 and Claude Opus 4.5 by about 3.5 points on average, and beats pure embedding retrieval by about 7.8 points.

### Cited Findings
**Embedding models (snapshots vary; verify on the live MTEB board)**
- Gemini Embedding 001 is reported to top English MTEB at about 68.3 overall and 67.7 retrieval (Apr 2026 snapshot), at about $0.15 per 1M tokens. — [PremAI blog](https://blog.premai.io/best-embedding-models-for-rag-2026-ranked-by-mteb-score-cost-and-self-hosting)
- Qwen3-Embedding-8B is the usual self-hosting pick, with MTEB multilingual mean 70.58 per its model card. — [llmreference MTEB multilingual](https://www.llmreference.com/benchmark/mteb-multilingual-v2)
- Voyage-4 shipped on 15 Jan 2026, and Voyage-4-large is recommended for hosted retrieval quality. It is not posted on the public MTEB board. — [PremAI blog](https://blog.premai.io/best-embedding-models-for-rag-2026-ranked-by-mteb-score-cost-and-self-hosting)
- Conflicting snapshots put NV-Embed-v2 first on English MTEB (May 2026) and Nemotron 3 Embed 8B first on RTEB (Jul 2026). Leaderboards also may not reflect domain RAG performance. — [PremAI](https://www.premai.io/blog/best-embedding-models-for-rag-2026-ranked-by-mteb-score-cost-and-self-hosting/); [DEV: why leaderboards lie](https://dev.to/saaswithalex/embedding-models-why-leaderboards-lie-about-rag-performance-2465)

**Hybrid search in Postgres**
- Pattern: a generated `tsvector` column (`to_tsvector('english', content)`) with a GIN index, alongside a pgvector column. Rank keywords via `websearch_to_tsquery` + `ts_rank_cd` and vectors via the `<#>` inner product, then fuse with RRF `1/(k+rank)`. Supabase's `hybrid_search` exposes `rrf_k` (default 50) and per-method weights. `ts_rank_cd` cannot use an index, so rank only rows matched by `@@`. — [Supabase hybrid search guide](https://supabase.com/docs/guides/ai/hybrid-search)
- The usual RRF constant is k=60. — [OneUptime hybrid search guide](https://oneuptime.com/blog/post/2026-01-30-hybrid-search/view)

**Research on person-job fit**
- ConFit v2 (arXiv 2502.12361, 2025) is embedding-based. It uses an LLM to generate a hypothetical reference resume from the job post (HyDE-style) and builds the job embedding from it. — [arXiv 2502.12361](https://arxiv.org/pdf/2502.12361v3)
- ConFit v3 (arXiv 2605.09760, May 2026) retrieves the top-20 with ConFit v2, then runs a listwise Qwen3 re-ranker: window 4, stride 2, two passes. Training is SFT distillation from Claude Sonnet 4.5, then GRPO RL with the ReaRank reward, with noisy windows (reward below 0.4) pruned. — [arXiv 2605.09760](https://arxiv.org/html/2605.09760)
- ConFit v3 results on the Recruiting dataset (10,597 jobs, 49,398 resumes, 58,111 labels), nDCG@10 / Recall@10:
  - ConFit v2 retrieval only: 52.33 / 62.30
  - GPT-5 prompted: 57.43 / 65.32
  - Claude Opus 4.5 prompted: 57.87 / 65.42
  - ConFit v3 Qwen3-8B: 60.83 / 68.40
  - ConFit v3 Qwen3-32B: 61.37 / 68.89

  Re-ranking only the top 20 keeps LLM cost practical. The authors recommend keeping re-ranker prompt criteria editable. — [arXiv 2605.09760](https://arxiv.org/html/2605.09760)
- Other 2026 work includes Synapse (arXiv 2604.02539), which combines dense retrieval, contrastive re-ranking and LLM reasoning with retrieval-grounded explanations. — [arXiv 2604.02539](https://arxiv.org/html/2604.02539v1)

**What products do**
- Jobright's Match Score is a 0–100 fit rating built from skills, experience, seniority, industry and location. Its "Orion" assistant explains the score through experience, seniority, skills, gaps and highlights. No technical details are published. — [Jobright AI Job Match](https://jobright.ai/ai-job-match); [Jobright blog](https://jobright.ai/blog/should-i-apply-for-this-job/)
- Resume Matcher's ATS score is deterministic, with no LLM: keyword match 40%, skills coverage 20%, title match 15%, section completeness 15%, date consistency 10%. It also lists missing keywords and flags which ones already appear in the master resume. — [Resume-Matcher](https://github.com/srbhr/Resume-Matcher)
- AIHawk scores each job 1–5 for fit across about 37 public sources over the last 30 days, then the user approves a batch for application. — [AIHawk GitHub](https://github.com/feder-cr/Jobs_Applier_AI_Agent_AIHawk)

### Inferences
- Suggested score: `final = w1*rrf_retrieval + w2*llm_fit(0-100) + w3*deterministic_keyword_coverage + w4*recency + w5*personal_prior`. Hard constraints are applied as filters, not soft scores: visa sponsorship (parse "no sponsorship" or "must be authorized" from the JD with an LLM classifier), remote eligibility by country or state, seniority band within ±1 level, and salary max ≥ the user's floor when salary is known.
- For explanations, require the LLM re-ranker to output JSON listing matched requirements (with resume bullet IDs as evidence), missing must-haves and a calibrated score. That keeps the explanations grounded.
- For feedback learning, log impressions, saves, dismissals with reasons, applies and interview outcomes. Short term, update a per-user preference vector (Rocchio-style: add liked-job embeddings, subtract dismissed ones) plus learned filter tweaks. Medium term, train a LightGBM/learning-to-rank model on features (retrieval score, LLM score, company, title similarity, recency) with apply and interview as labels. Long term, follow ConFit v3: distill a strong LLM's judgments into a small open model for cheap re-ranking.
- At startup scale (≤ a few million active jobs), pgvector with HNSW plus tsvector in one Postgres is sufficient. Move to OpenSearch/Elasticsearch, which have native hybrid and RRF, only when facet-heavy search and volume demand it.

### Gaps
- No published production metrics were found from Jobright, Simplify or Tsenta on their matching stacks.
- No 2025–2026 benchmark of embedding models specifically on resume–JD retrieval was found. Evaluate on your own labeled pairs.
- The OpenSearch/Elasticsearch hybrid query specifics (e.g. the ES `rrf` retriever) were not fetched in this pass.

## (d) Tailoring: LLM bullet rewriting, ATS keyword alignment, rendering to PDF/DOCX, anti-hallucination, cover letters

### Takeaway
Tailor from a structured master profile. The LLM may select, reorder and rephrase existing bullets and surface JD keywords the candidate already has evidence for, but never add employers, skills, tools or metrics. Enforce this with programmatic checks, not just prompt instructions. Render from structured data with a deterministic template engine (Typst via RenderCV, LaTeX, or HTML→PDF via headless Chromium), and confirm the PDF is text-extractable for ATS parsing.

### Cited Findings
- Resume Matcher tailors from a master resume. Its prompts forbid adding skills, tools, employers or metrics absent from the master. Cover letters must draw names, metrics and motivations only from supplied information. These guards are prompt instructions with no automated verification step. — [Resume-Matcher](https://github.com/srbhr/Resume-Matcher)
- Resume Matcher stack: FastAPI with Next.js 16, SQLite or Postgres, and LiteLLM for providers (Ollama, OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek, Groq). An MCP server lets coding agents write the tailored resume. A persistent Tailoring Queue processes many job descriptions in the background. It is Apache-2.0 with about 29.4k stars. — [Resume-Matcher](https://github.com/srbhr/Resume-Matcher)
- Resume Matcher renders PDFs with headless Chromium via Playwright (A4 or Letter, 10 templates, 7 also exported as pdfLaTeX/Overleaf projects). Its "ATS Check" re-extracts the rendered PDF text with pdfminer and verifies parseability, reading order, contact info and section headings. — [Resume-Matcher](https://github.com/srbhr/Resume-Matcher)
- RenderCV: install with `pip install "rendercv[full]"` (Python 3.12+), create a template with `rendercv new "Name"`, then render with `rendercv render file.yaml`. Input is YAML with a JSON Schema, and themes include classic, engineeringresumes, sb2nov, moderncv, harvard and others. The repo is tagged Typst, but its page did not explicitly name the engine. — [rendercv GitHub](https://github.com/rendercv/rendercv)
- AIHawk (about 32.6k stars, MIT) now searches 37 public sources, scores fit 1–5, and auto-fills and submits applications in Firefox with screenshots. It attaches the CV and does not describe per-job tailoring. Its README says each application costs a few cents via an LLM router (OrcaRouter, referral links). — [AIHawk GitHub](https://github.com/feder-cr/Jobs_Applier_AI_Agent_AIHawk)

### Inferences
- Anti-fabrication design, going beyond Resume Matcher's prompt-only guard:
  1. Have the LLM output each tailored bullet as `{source_bullet_ids:[...], text}`.
  2. Programmatically check that every number, percentage or currency, every proper noun (employer, product) and every skill or tool term in the output appears in the cited source bullets or the skills list. Normalize with a skill taxonomy and synonyms (e.g. "k8s" = "Kubernetes").
  3. Run an LLM-as-judge entailment check: does the source entail the rewrite? Flag anything unsupported for user review.
  4. Store diffs and show them to the user before sending.
- Keyword alignment: extract JD requirements (must-have vs nice-to-have) into a list with an LLM. Compute coverage against the master profile. Inject only "covered but not phrased" keywords, i.e. skills the user has but describes differently. Report "missing" keywords to the user as gaps rather than inserting them. Mirror the JD's exact phrasing for hard skills (for example "PostgreSQL" vs "Postgres") because ATS keyword match is often literal (inference; Resume Matcher's score gives keyword match a 40% weight).
- Bullet-rewrite prompt pattern: give the JD requirements, the candidate's relevant bullets with IDs, constraints (keep tense, keep every metric verbatim, ≤ 2 lines, start with an action verb, no new facts) and the required JSON output. Use the same pattern with a company or role paragraph to ground cover letters: 3–4 paragraphs, every claim citing a bullet ID.
- Rendering choice: Typst (RenderCV) is fast and deterministic, with sub-second compiles and no TeX install. HTML→PDF via Playwright gives the most template flexibility. LaTeX gives the best typography but is slow and heavy. For DOCX (some ATSs prefer it), use python-docx or docxtpl templates fed from the same JSON. Always use single-column, text-based output for ATS safety, and re-extract the text to verify.

### Gaps
- No quantitative study of ATS parse rates for Typst, LaTeX or Chromium PDFs was found.
- No public anti-hallucination benchmark for resume tailoring was found.
- The internal tailoring prompts of Jobright, Simplify and Tsenta are not public.
- Data model/schema: no authoritative published schema was found. See the suggested model in the inferences below.

### Inferences: suggested data model (synthesized, not sourced)
- `companies`(id, name, domain, linkedin_url, size, industry)
- `ats_boards`(id, company_id, vendor[greenhouse|lever|ashby|smartrecruiters|workday|…], slug, region, last_polled_at, status)
- `jobs`(id, board_id, external_id, canonical_job_id, title, title_normalized, seniority, department, employment_type, workplace_type, locations jsonb, countries[], salary_min, salary_max, currency, interval, visa_sponsorship enum[yes|no|unknown], description_html, description_text, requirements jsonb{must[], nice[]}, skills[], posted_at, first_seen_at, last_seen_at, closed_at, apply_url, source, content_hash, embedding vector(N), fts tsvector; UNIQUE(board_id, external_id))
- `candidates`(id, user_id, master_profile jsonb [JSON Resume + IDs], preferences jsonb{titles, locations, remote, salary_floor, visa_status_by_country, sponsorship_needed, seniority}, profile_embedding vector)
- `matches`(candidate_id, job_id, retrieval_score, llm_score, explanation jsonb{matched:[{req, bullet_ids}], gaps[]}, model_version, created_at)
- `feedback_events`(candidate_id, job_id, type[impression|save|dismiss|apply|interview|offer|reject], reason, ts)
- `documents`(id, candidate_id, job_id, kind[resume|cover_letter], content jsonb, source_map jsonb, render_format, file_url, verification jsonb{unsupported_claims[]}, approved_by_user bool)
- `applications`(id, candidate_id, job_id, document_ids[], status[queued|submitted|failed|interview|rejected|offer], submitted_at, ats_confirmation, screenshots[], answers jsonb)
