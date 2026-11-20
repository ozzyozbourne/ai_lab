# Apply Engine Architecture: Browser Automation, LLM Form Understanding, and Packaging for an ATS Auto-Apply Agent

Scope: the "apply" engine of a Tsenta / Simplify / LazyApply-style product. Research done Nov 2026. Many sources in this space are vendor blogs with commercial bias (Skyvern, Browserbase competitors, auto-apply vendors). They are flagged where relevant. Code-level patterns that are my own engineering recommendations are placed under "Inferences", not "Cited Findings".

---

## 1. Browser automation options in 2026 (Playwright, Puppeteer, CDP, browser-use, Stagehand, Skyvern, computer-use, extension content scripts): trade-offs

### Takeaway
Deterministic Playwright/CDP scripts are still the most reliable and cheapest option (around 98% on WebVoyager in one roundup, versus 75-89% for LLM agents). LLM agent frameworks (browser-use, Stagehand: DOM/accessibility-tree based; Skyvern: vision based) are fallbacks for unknown forms. Pixel-level computer-use is the slowest and most token-heavy option. The best-supported design is a hybrid: deterministic adapters first, then a cached or self-healing LLM layer (Stagehand-style `observe -> act` with selector caching), then a vision agent as a last resort.

### Cited Findings
- No apples-to-apples benchmark exists. One roundup reports WebVoyager scores of browser-use (with Claude) 89.1%, Skyvern 85.85%, Stagehand agent 75%, and hand-written Playwright scripts 98%. — [noqta.tn](https://noqta.tn/blog/ai-browser-agents-browser-use-stagehand-web-automation-2026)
- Skyvern's own published eval reports 85.85% on WebVoyager. The Browser Arena leaderboard excludes Skyvern because it is a workflow platform rather than a browser runtime. — [notte.cc](https://ai.notte.cc/answers/browser-use-vs-skyvern)
- Two sources conflict over a 64.4% WebBench score: one credits Stagehand, the other credits Skyvern 2.0, a benchmark Skyvern co-authored. Treat it as unverified. — [awesomeagents.ai](https://awesomeagents.ai/tools/best-ai-browser-automation-tools-2026/); [digitalapplied.com](https://www.digitalapplied.com/blog/open-source-browser-computer-use-agents-2026)
- browser-use reportedly scores 97% on Online-Mind2Web (bu-max setup) and 63.3% on BU Bench V1 for the open-source library. — [digitalapplied.com](https://www.digitalapplied.com/blog/open-source-browser-computer-use-agents-2026)
- Architecture split: browser-use and Stagehand read page structure (DOM and accessibility tree), while Skyvern reads the rendered page with vision plus an LLM. — [joinmassive.com](https://www.joinmassive.com/blog/browser-use-vs-stagehand-vs-skyvern-choosing-an-agent-browser-framework)
- Fit by use case: Stagehand for TypeScript/Playwright pipelines, browser-use for Python, Skyvern for legacy or non-semantic pages. — [meshworld.in](https://meshworld.in/blog/ai/agents/page-agent/browser-agent-landscape-comparison/)
- **browser-use speed and cost:** its strongest model averages about 3 seconds per step, because most actions take only 10-15 output tokens. — [browser-use.com/posts/speed-matters](https://browser-use.com/posts/speed-matters)
  - ChatBrowserUse is priced at $0.50 per 1M input tokens, $3.00 per 1M output, and $0.10 per 1M cached input. — [browser-use docs, costs](https://docs.browser-use.com/open-source/development/monitoring/costs)
  - Cloud per-step pricing lists $0.002 per step plus a $0.01 task-init fee, so a 10-step task costs about $0.03. These two pricing schemes come from different API versions. — [browser-use cloud pricing](https://docs.cloud.browser-use.com/pricing)
  - The FAQ suggests `flash_mode=False` for more careful navigation, which implies flash mode trades care for speed. — [browser-use cloud FAQ](https://docs.cloud.browser-use.com/faq)
- **Stagehand v3:** primitives are `act()`, `extract()` and `observe()`. Caching is on by default and returns repeated results without consuming LLM tokens. The server-side cache only works when `env: "BROWSERBASE"` and has no effect locally. — [Stagehand caching docs](https://docs.stagehand.dev/best-practices/caching); [Stagehand act docs](https://docs.stagehand.dev/v3/basics/act)
  - Self-healing: an Action from `observe()` replays its selector directly. If the selector no longer resolves and `selfHeal` is on, Stagehand re-infers the action and retries once. — [Stagehand act docs](https://docs.stagehand.dev/v3/basics/act)
  - Third-party per-call cost estimates, unverified: about $0.001 for a simple `act()` on Haiku, about $0.005 for a complex `act()` on Sonnet, and $0.002-$0.02 per act/extract call. — [tessl.io skill page](https://tessl.io/registry/skills/github/fernandezbaptiste/Skrillz/stagehand-automation); [wetheflywheel review](https://wetheflywheel.com/en/radar/stagehand-review/)
- **Skyvern pricing:** it historically charged per step, cut from $0.10 to $0.05 (a step is a page visit or scan), and has since moved to credit tiers. Third parties list Free (5,000 credits, about 170 actions), Hobby at $29/month and Pro at $149/month. Skyvern's own pricing markdown says it charges per workflow execution, not per step, which conflicts with the third-party listings. — [Skyvern launch week day 1](https://www.skyvern.com/blog/launch-week-day-1-automating-with-skyvern-got-50-cheaper/); [Skyvern simpler pricing](https://www.skyvern.com/blog/launch-week-day-5-simpler-pricing-model/); [skyvern.com/md/pricing.md](https://www.skyvern.com/md/pricing.md); [costbench](https://www.costbench.com/software/browser-automation/skyvern/)
- **Anthropic computer use (as of Nov 2026):** the current client toolset `computer_toolset_20260801` (17 member tools, no beta header) is supported on Opus 5.5, Sonnet 5.5, Haiku 5.5 and Fable/Mythos 5.2. The older `computer_20251124` tool (beta header `computer-use-2025-11-24`) serves Opus 4.5-4.7 and Sonnet 4.6. — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
  - Each screenshot adds roughly 1,000-1,800 input tokens in a long loop. Recommended web-app resolution is 1280x800 or 1366x768, and nothing above 1920x1080. Visual tokens are `ceil(w/28) x ceil(h/28)`, capped at 4,784 on newer models. A `zoom` action reads small text at full resolution. — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
  - Security guidance: use a dedicated VM or container, keep credentials away from the model, allowlist domains, and have a human confirm consequential actions. Claude may follow instructions embedded in web pages, and Anthropic runs prompt-injection classifiers on screenshots. Developers should inform end users and get consent. — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
- browser-use claims its model is 2x to 6x faster than computer-use models. This is a vendor claim. — [browser-use LLM gateway post](https://browser-use.com/posts/llm-gateway); [browser-use benchmarks](https://browser-use.com/benchmarks/agents)

### Inferences
- **Recommended layered engine:**
  1. **Per-ATS deterministic adapters:** Playwright (TS or Python) or raw CDP for Greenhouse, Lever, Ashby and Workday. These are fast (seconds), cost no tokens for structured fields, and are testable.
  2. **Generic LLM form agent:** for long-tail career sites, use a DOM/accessibility-tree approach (Stagehand `observe`/`act` or browser-use). Cache the resolved selectors per domain and form hash, so the second application to the same tenant costs about $0.
  3. **Vision computer-use fallback:** only for canvas or iframe-heavy or otherwise broken pages. It is 5-10x the tokens per step because of screenshots.
- The LLM should be called once per form to produce a *fill plan* (field -> value JSON), not once per keystroke. Deterministic code then executes the plan. This cuts step count from about 30-60 agent steps to 1-3 LLM calls per page.
- Chrome extension content scripts run inside the user's real logged-in session and real fingerprint, so they have the best detection profile. However, they cannot easily set `<input type=file>` from disk without the extension holding the file bytes; the extension must use a `DataTransfer` to build a `File` and dispatch `change`/`input` events. Content scripts also cannot cross into cross-origin iframes unless `all_frames: true` is set with matching host permissions.

### Gaps
- No independent, job-application-specific benchmark of these frameworks was found.
- No verified, current Steel.dev or Hyperbrowser pricing was retrieved.
- Puppeteer-specific 2026 comparisons were not retrieved. Treat Puppeteer as roughly equivalent to Playwright via CDP, an uncited judgment.

---

## 2. How the main ATSs structure their application forms; deterministic adapters vs generic agent; Workday account pain

### Takeaway
Greenhouse, Lever and Ashby expose machine-readable form schemas (public GET endpoints) with a small set of field types, so they are ideal for deterministic adapters. Their *submission* APIs, however, require the employer's API key, so a third-party agent must still drive the hosted web form. That form is protected by reCAPTCHA Enterprise and a fingerprint on Greenhouse. Workday is a per-employer-tenant, multi-step wizard with mandatory account creation per tenant, a resume parser that needs correction, and `data-automation-id` attributes that make adapters feasible but laborious. iCIMS and Taleo are account-based, inconsistent across tenants, and poorly documented, so they suit the generic agent. LinkedIn Easy Apply automation violates LinkedIn's User Agreement.

### Cited Findings
**Greenhouse**
- `GET https://boards-api.greenhouse.io/v1/boards/{board_token}/jobs/{id}?questions=true` returns: — [Greenhouse Job Board API](https://docs.greenhouse.io/job-board.html)
  - `questions`: each has `required`, `label` and `fields[]`, and each field has `name`, `type` and `values`.
  - `location_questions`
  - `compliance`: EEOC questions.
  - `demographic_questions`: has `header`, `description` and `questions`, where each question has `answer_options[]` with `id`, `label` and `free_form`.
  - Field types are `input_file`, `input_text`, `input_hidden`, `textarea`, `multi_value_single_select` and `multi_value_multi_select`.
  - One question can aggregate several fields; for example, "Resume" can be `resume` (file) or `resume_text` (textarea).
- The application POST to `/boards/{board_token}/jobs/{id}` needs HTTP Basic auth with the Base64-encoded *employer's* Job Board API key, and Greenhouse says to proxy it through your own servers. — [Greenhouse Job Board API](https://docs.greenhouse.io/job-board.html)
  - Required fields are only `first_name`, `last_name` and `email`. Greenhouse says "Validation for required fields must be done on the client side."
  - Resume options: multipart `resume`, JSON `resume_content` + `resume_content_filename`, `resume_url` + `resume_url_filename`, or `resume_text`.
  - `location` is ignored unless `latitude` and `longitude` are also sent.
  - Attachments must be pdf, doc, docx, txt or rtf.
- A third-party skill doc describes the hosted Greenhouse form (unofficial; treat as a lead): — [browse.sh Greenhouse skill](https://browse.sh/skills/greenhouse.com/apply-to-jobs-dsmal1)
  - It is a React SPA built on react-aria comboboxes, not native `<select>` elements.
  - The submit body includes a `g-recaptcha-enterprise-token`, a `fingerprint` and a `csrfToken`. Replaying the POST outside the page context was rejected at the captcha layer in every attempt the doc recorded.
  - Latitude and longitude are populated only when a geocode option is clicked. Typing and tabbing away leaves them empty, and submit fails silently.
  - The email field has a roughly 500 ms debounced validator.
  - The phone field needs the country combobox selected first.
  - Files go to S3 via presigned URLs.
  - Success adds `?application_id=` to the URL or shows a confirmation container.
  - Both the `compliance[]` and `demographic_questions` schemas exist.
  - `question_<int>` IDs change per job.

**Lever**
- The public `GET api.lever.co/v0/postings/{site}?mode=json` needs no auth. The Apply POST needs an employer API key from a Super Admin and is rate-limited to 2 POSTs per second. — [100hires Lever API guide](https://100hires.com/lever-api.html)
- A Ruby client notes the POST API key must be configured by Lever support. — [lever_postings gem](https://rubydoc.info/gems/lever_postings)
- The apply path is listed as `POST /postings/{posting_id}/apply` by Merge, and can only be used for published or unlisted postings. — [Merge Lever docs](https://docs.merge.dev/integrations/ats/lever/provider-interactions); [Nango Lever docs](https://docs.nango.dev/integrations/all/lever)

**Ashby**
- The public `GET posting-api/job-board/{JOB_BOARD_NAME}` returns listings with an `applyUrl`. — [Ashby public job posting API](https://developers.ashbyhq.com/docs/public-job-posting-api)
- `jobPosting.info` returns the application form spec. — [Ashby custom careers page](https://developers.ashbyhq.com/docs/creating-a-custom-careers-page)
- `applicationForm.submit` takes multipart/form-data containing `fieldSubmissions[]` of `{path, value}`. — [Ashby applicationForm.submit](https://developers.ashbyhq.com/reference/applicationformsubmit)
  - System fields use paths such as `_systemfield_name` and `_systemfield_email`.
  - A file field's value references a multipart part, for example `resume_1`.
  - Plain text is sent as `{type:"PlainText", value}`.
  - The endpoint requires the `candidatesWrite` permission, meaning an employer key.

**Workday**
- Each employer runs its own Workday instance, and there is no unified profile across employers. You create a candidate account per company. Workday parses the uploaded resume into fields, and applicants then re-enter or fix work history, education and skills. Some tenants add screening questions, voluntary demographic surveys and cover letters. — [dev.to FastApply article](https://dev.to/fastapply/how-to-beat-workday-applications-in-2026-the-ats-everyone-hates-and-how-to-auto-fill-it-36n6) (vendor)
- A typical manual Workday application is said to take 20-30 minutes. The parser struggles with tables and columns, producing wrong dates and merged titles. — [dev.to FastApply article](https://dev.to/fastapply/how-to-beat-workday-applications-in-2026-the-ats-everyone-hates-and-how-to-auto-fill-it-36n6) (vendor)
- Workday UI elements carry custom attributes `data-automation-id`, `data-uxi-element-id` and `data-uxi-widget-type`, which serve as stable targeting hooks. — [Nexthink Workday selectors](https://docs.nexthink.com/platform/user-guide/adopt/guide-creation-and-management-from-nexthink-applications/configuring-adoption-settings/use-case-element-selectors-for-workday)
- Vendor claims say cheap AI tools fail on Workday dynamic fields, and cite a "22% rejection from anti-bot filters". These figures are unsourced and the vendor sells manual services. — [scale.jobs](https://blog.scale.jobs/cheap-ai-apply-tools-fail-workday-applications); [jobicy](https://jobicy.com/tools/how-to/productivity/how-auto-apply-job-services-really-work)
- One review cites a 70% Simplify Workday accuracy figure (unverified), and negative reviews often mention Workday. — [Simplify review summary via jobright](https://jobright.ai/blog/?p=5309)

**iCIMS, Taleo, SmartRecruiters**
- Vendor descriptions: iCIMS is account-based, multi-step, with long and dated forms, and extensions need the tab active. Taleo is inconsistent across client setups. SmartRecruiters is listed as supported with no special difficulties. — [jobwizard iCIMS guide](https://jobwizard.ai/blog/how-to-autofill-icims-job-applications-with-a-chrome-extension); [scale.jobs iCIMS](https://blog.scale.jobs/icims-applications-break-most-automation-tools)
- Old Taleo Business Edition pages used iframes that broke LinkedIn prefill (2013 thread). — [Oracle community](https://community.oracle.com/customerconnect/discussion/12560/tbe-recruit-application-form-auto-fill-in-from-linkedin)

**LinkedIn Easy Apply and Indeed**
- Section 8.2 of LinkedIn's User Agreement prohibits bots and unauthorized automated methods. LinkedIn restricts accounts and in March 2026 publicly named a tool, HeyReach, as violating it. Tools such as LazyApply drive Easy Apply from a logged-in session, which is exactly the behavior targeted. — [LinkedIn prohibited software help](https://www.linkedin.com/help/linkedin/answer/a1341387); [scoutify](https://scoutify.com/blog/linkedin-auto-apply/); [salesflow](https://salesflow.io/blog/linkedin-automation-user-agreement-compliance)

**How the products handle it**
- Simplify Copilot autofills "100+" portals including Workday, Greenhouse, iCIMS, Taleo, Avature, Lever and SmartRecruiters, but does not submit; the user reviews and submits. — [simplify.jobs/copilot](https://simplify.jobs/copilot); [Simplify help](https://help.simplify.jobs/articles/1749022-installing-and-setting-up-copilot)
- Tsenta lists Workday, Greenhouse, Lever, Ashby, Rippling, iCIMS and BambooHR. It applies in the cloud and "handles supported account and verification steps". — [Tsenta docs](https://docs.tsenta.com/product/how-auto-apply-works); [Tsenta YC launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- Tsenta also notes that "Job page recognition alone does not confirm that Tsenta can submit." — [Tsenta docs](https://docs.tsenta.com/product/how-auto-apply-works)

### Inferences
- **Deterministic-adapter tier:**
  - Greenhouse (`job-boards.greenhouse.io/{token}/jobs/{id}` or `boards.greenhouse.io`), Lever (`jobs.lever.co/{site}/{id}/apply`) and Ashby (`jobs.ashbyhq.com/{org}/{id}`): fetch the form schema from the public JSON endpoint, have the LLM answer the custom questions against that schema *before* opening the browser, then fill the DOM in the browser so the captcha and fingerprint stay valid. Direct API POST is only possible with the employer's key, i.e. it is not available to a third-party agent.
  - Workday (`{tenant}.wd{N}.myworkdayjobs.com/...`): an adapter keyed on `data-automation-id` covering the wizard steps sign-in/create account -> My Information -> My Experience -> Application Questions -> Voluntary Disclosures -> Self Identify -> Review. These step names are from general knowledge, not from a fetched source.
- **Generic-agent tier:** iCIMS, Taleo, SuccessFactors, Avature, custom career sites.
- **Workday account pain:** you need a per-tenant credential vault (email + generated password per tenant), automated email verification (read the verification link via Gmail API or an inbox owned by the product, such as plus-addressing), and you must expect captchas at account creation. This is the biggest operational cost driver for Workday.

### Gaps
- No primary source documented Workday's applicant-side DOM, account-creation captcha behavior, or password rules.
- No primary technical docs were found for iCIMS, Taleo or SmartRecruiters candidate forms. SmartRecruiters has a public posting API, but it was not verified here.
- Indeed Apply internals were not researched.
- Lever's exact canonical apply path was not confirmed against its GitHub postings-api repository.

---

## 3. Field mapping: profile -> fields, dropdowns, file uploads, EEO, LLM free-text answers

### Takeaway
Use a canonical profile schema (contact, work authorization, experience, education, EEO preferences, saved Q&A), then a two-pass mapper. First, deterministic matching by label, name and autocomplete plus ATS-specific keys (Greenhouse field `name`s, Ashby `_systemfield_*`, Workday `data-automation-id`). Second, a single LLM call that maps the remaining fields and drafts free-text answers under a strict JSON schema. The hard parts are custom widgets (ARIA comboboxes, typeaheads that set hidden fields), files, and async validators.

### Cited Findings
- Greenhouse options come as `values` on select fields. Demographic answers carry `answer_options` with `free_form` flags, and decline options are usually available. — [Greenhouse Job Board API](https://docs.greenhouse.io/job-board.html); [browse.sh skill](https://browse.sh/skills/greenhouse.com/apply-to-jobs-dsmal1)
- Greenhouse widget behavior, from the third-party skill doc: — [browse.sh skill](https://browse.sh/skills/greenhouse.com/apply-to-jobs-dsmal1)
  - Single-select is a combobox with a "Toggle flyout": open it, then click the option.
  - Files go into a hidden `<input type=file>` behind an "Attach" button; upload directly to the input. pdf, doc, docx, txt and rtf are accepted, with 10 MB considered safe.
  - Typeahead location must be *clicked* to populate the hidden lat/long.
  - Wait about 1 second after typing an email.
- Ashby plain-text answers must be sent as `{type:"PlainText"}`, and file fields reference multipart parts. — [Ashby applicationForm.submit](https://developers.ashbyhq.com/reference/applicationformsubmit)
- Tsenta tailors the resume per role (with a diff view) and prepares cover letters only when the workflow accepts them. It warns users to review work authorization and experience claims. — [Tsenta docs](https://docs.tsenta.com/product/how-auto-apply-works); [Tsenta YC launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- Simplify uses one profile (experience, education, skills, contact, resumes) as the autofill source. — [Simplify help](https://help.simplify.jobs/articles/1749022-installing-and-setting-up-copilot)

### Inferences
- **Field extraction per page:** build a compact JSON of fields: `{id, label, type, required, options[], current_value, section_heading, help_text}`. Get it from the accessibility tree (Playwright `page.accessibility.snapshot()` or a `getByRole` walk) plus the DOM, not from screenshots. Typical forms produce 2-6k tokens of this JSON.
- **LLM fill plan:** use structured outputs or tool use with a schema such as `{field_id: {value, confidence, source: "profile"|"generated"|"saved_answer", needs_review: bool}}`. Force `needs_review=true` for:
  - work authorization and sponsorship,
  - salary expectations,
  - "how did you hear",
  - legal attestations,
  - low confidence.
- **Dropdowns:** match option text by normalized fuzzy match first (e.g. "United States" vs "USA"), then by LLM choice restricted to the given options. Never type free text into a combobox without selecting a listbox option, since Greenhouse location shows that the hidden state may not update.
- **EEO:** store the user's explicit choice per category (gender, race, veteran, disability), defaulting to "decline to self-identify". Never let the LLM infer these.
- **Files:**
  - Playwright `locator.setInputFiles(path)` works on hidden file inputs.
  - In an extension, build a `File` and assign it via `DataTransfer` to `input.files`, then dispatch `change`.
  - Cache the per-job tailored PDF and keep a filename convention like `First_Last_Resume.pdf`.
- **Saved Q&A memory:** embed past question -> answer pairs, retrieve the top-k for each new custom question, and generate an answer grounded in the profile and the job description. This also cuts tokens on repeat questions.

### Gaps
- No source quantified mapping accuracy per ATS beyond an unverified "70% Workday" figure for Simplify.
- AIHawk's current README no longer describes its LLM question-answering internals (see section 6), so no OSS reference prompt was captured.

---

## 4. Local (Electron/Tauri controlling the user's Chrome) vs cloud headless (Browserbase, Steel, Hyperbrowser): logins, CAPTCHAs, detection, IP reputation

### Takeaway
Local execution via an extension, or a desktop app with its own Chrome profile, inherits the user's residential IP, real fingerprint and existing logins, so it gets the best captcha scores and avoids credential custody. It is limited by the user's machine being on. Since Chrome 136 a desktop app cannot attach CDP to the user's *default* Chrome profile. Cloud browsers scale and run 24/7 (Tsenta runs in the cloud). They need stealth, residential proxies and captcha solving (Browserbase: basic stealth and captcha solving from $20/mo, advanced stealth only on custom-priced Scale), plus custody of per-tenant credentials.

### Cited Findings
- **Chrome 136 change:** `--remote-debugging-port` and `--remote-debugging-pipe` are no longer respected on the default Chrome data directory and must be paired with `--user-data-dir` pointing to a non-standard directory, because infostealers abused them. Chrome for Testing and Chromium are unaffected. A 2026 GitHub issue confirms the behavior persists on Chrome 151. — [Chrome developer blog](https://developer.chrome.com/blog/remote-debugging-port); [trycua/cua issue #2916](https://github.com/trycua/cua/issues/2916)
- **Browserbase pricing (2026 third-party summaries):** — [tinyfish](https://www.tinyfish.ai/blog/browserbase-pricing); [wetheflywheel](https://wetheflywheel.com/en/radar/browserbase-review/)
  - Free: 1 browser-hour, no stealth, captcha or proxies.
  - Developer: $20/mo, 100 browser-hours, $0.12/hr overage, 1 GB proxies, basic stealth and auto captcha solving.
  - Startup: about $99/mo for 500 hours.
  - Scale: custom pricing, with advanced stealth.
- The Greenhouse submit checks a reCAPTCHA Enterprise token and fingerprint at submit time. The skill doc recommends stealth plus residential proxies to improve captcha scoring. — [browse.sh skill](https://browse.sh/skills/greenhouse.com/apply-to-jobs-dsmal1)
- ATS-side defenses exist. Workable describes multi-layered defenses against AI-generated and automated applications, and Fingerprint markets submission-time bot detection to ATS platforms. — [Workable help](https://help.workable.com/hc/en-us/articles/35293126257815-Managing-AI-generated-and-automated-job-applications); [Fingerprint blog](https://fingerprint.com/blog/job-application-fraud-detection/)
- Tsenta applications "run in the cloud", and it offers a Chrome extension for capturing jobs on LinkedIn, Indeed and Glassdoor. — [Tsenta docs](https://docs.tsenta.com/product/how-auto-apply-works); [Tsenta YC launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- AIHawk drives a real local Firefox window. macOS can find and score jobs but cannot apply yet because the browser has no macOS build. — [AIHawk repo](https://github.com/feder-cr/Jobs_Applier_AI_Agent_AIHawk)
- Anthropic recommends running computer-use in an isolated VM or container with minimal privileges. — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)

### Inferences
- **Local options:**
  - **(a) Chrome MV3 extension:** content scripts with `all_frames`, plus optionally `chrome.debugger` (CDP from inside the extension, which shows the "is being debugged" banner). It runs in the real profile, is the most stealthy, and is the easiest to distribute. Its drawbacks are that the tab must stay open and long-running orchestration is constrained by service-worker lifetimes.
  - **(b) Electron/Tauri app launching a dedicated Chrome or Chromium:** uses its own `--user-data-dir` plus Playwright `connectOverCDP`. The user logs into ATS tenants once in that profile. You get full Playwright power but lose the existing default-profile cookies (per Chrome 136).
  - **(c) Electron's built-in Chromium:** fingerprintable as Electron, so it is a weaker stealth option.
- **Cloud:** one isolated browser context per user, with a persistent context and storage state per user so tenant logins survive. Use a sticky residential proxy per user to avoid IP-reputation flags from thousands of applications on datacenter IPs, use captcha solving, and store per-tenant credentials encrypted (KMS).
  - At about 5 minutes per application and $0.10-0.12 per browser-hour, browser cost is about $0.01 per application, so LLM tokens and proxies dominate.
- **Hybrid (likely what Tsenta-class products do):** cloud for API-friendly and adapter-covered ATSs at volume, and an extension for "assist mode" on hostile sites such as LinkedIn or captcha-heavy ones.

### Gaps
- Steel.dev and Hyperbrowser features and pricing were not retrieved.
- No hard data was found on captcha encounter rates per ATS, or on IP-reputation thresholds.

---

## 5. Human-in-the-loop review, error recovery, verifying submission success, status tracking (Gmail API)

### Takeaway
Ship with a configurable approval ladder (review every application -> pre-approve under filters and a daily cap -> full auto). Treat submit as irreversible and gated. Verify success by URL change or confirmation container plus absence of field errors. Close the loop with confirmation emails via Gmail API `users.watch` -> Pub/Sub -> `history.list`. That requires restricted scopes (`gmail.readonly`) and therefore an annual CASA security assessment.

### Cited Findings
- Tsenta's controls: — [Tsenta docs](https://docs.tsenta.com/product/how-auto-apply-works)
  - "Resume auto-approval" pauses for review of the tailored resume.
  - "Review before submit" pauses compatible forms after filling; other systems may submit without this pause.
  - "Auto Apply" submits with a filter, daily cap and match threshold, skipping review.
  - Completed records may include captured answers, documents and a submission confirmation.
  - Failure causes include a changed form, a closed role, or an unavailable system, and users should check final status before retrying.
- Simplify Copilot never submits; the user reviews and clicks submit. — [Simplify help](https://help.simplify.jobs/articles/1749022-installing-and-setting-up-copilot)
- On Greenhouse, success is a URL with `?application_id=...` or a confirmation route plus a confirmation container. Failure re-renders the form with field errors and a generic failure banner. The skill doc requires explicit user confirmation before the submit click. — [browse.sh skill](https://browse.sh/skills/greenhouse.com/apply-to-jobs-dsmal1)
- Ashby's API returns a `success` flag with validation errors. — [Ashby applicationForm.submit](https://developers.ashbyhq.com/reference/applicationformsubmit)
- AIHawk logs each page's response with a screenshot and checks the posting is still open before applying. — [AIHawk repo](https://github.com/feder-cr/Jobs_Applier_AI_Agent_AIHawk)
- Tsenta routes recruiter replies back to the matching application. — [Tsenta YC launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- **Gmail push:** `users.watch` publishes to a Pub/Sub topic. The topic must grant publish rights to Gmail's push service account. The notification payload contains only the email address and `historyId`, so you call `history.list(startHistoryId)` to get changes. The watch must be renewed at least every 7 days. — [Gmail push guide](https://developers.google.com/workspace/gmail/api/guides/push); [unipile guide](https://www.unipile.com/gmail-api-push-notifications/)
- `gmail.readonly` is a restricted scope. Public apps need a CASA assessment by a Google-authorized lab, re-verified at least every 12 months. — [EmailEngine scopes reference](https://learn.emailengine.app/docs/accounts/gmail/gmail-api-scopes); [explosion.com CASA guide](https://www.explosion.com/210203/gmail-api-integration-guide-oauth-scopes-and-casa/)
- Anthropic recommends human confirmation for consequential actions such as agreeing to terms. — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)

### Inferences
- **State machine per application:**
  `QUEUED -> PRECHECK (posting open?) -> FORM_SCHEMA -> FILL_PLAN (LLM) -> NEEDS_REVIEW? -> FILLING -> VALIDATING -> AWAITING_APPROVAL -> SUBMITTING -> VERIFYING -> SUBMITTED | FAILED(reason) | NEEDS_USER(verification/captcha/missing answer)`.
  Persist after each step so the run can be resumed idempotently. Never auto-retry SUBMITTING without first verifying that no prior submission exists (check the confirmation email or the ATS candidate portal).
- **Evidence bundle:** final-page screenshot, DOM snapshot of the confirmation, the filled answer JSON, and the files used.
- **Email classification:** parse confirmation, rejection, interview and assessment emails with a cheap LLM classifier. Match them to applications by company domain, ATS sender (e.g. `no-reply@greenhouse.io`, `myworkday.com` senders) and job title.
  - Alternative that avoids CASA: a product-owned forwarding inbox (`user+apply@yourdomain`) used as the application email, or `gmail.metadata` / label-scoped approaches. These are uncited options to evaluate.
- **Error recovery:**
  - On validation errors, re-extract the error-bearing fields and call the LLM with the error text, up to 2 retries.
  - On selector failure, fall back from the adapter to the LLM `observe` step, then to vision.
  - On captcha or email verification, move to NEEDS_USER and notify the user.

### Gaps
- No source documented how Tsenta or Simplify technically verify submissions or parse emails.
- Exact Workday confirmation-page markers were not sourced.

---

## 6. Cost per application in LLM tokens and time

### Takeaway
Published data points are sparse:
- AIHawk claims "a few cents" per application.
- browser-use cloud is about $0.03 per 10-step task at $0.002 per step plus a $0.01 init fee.
- Computer-use screenshots cost 1-1.8k tokens each.
- Browserbase hours cost $0.10-0.12.

A schema-first adapter with one or two LLM calls per page should land at roughly $0.01-0.05 and 1-3 minutes per application. A full vision agent on Workday could plausibly reach $0.50-$2 and 5-15 minutes. Those are estimates, not sourced figures. Manual Workday applications take 20-30 minutes.

### Cited Findings
- AIHawk says each application costs "a few cents" in LLM credit. — [AIHawk repo](https://github.com/feder-cr/Jobs_Applier_AI_Agent_AIHawk)
- AIHawk's README describes the current app as follows: — [AIHawk repo](https://github.com/feder-cr/Jobs_Applier_AI_Agent_AIHawk)
  - It searches a local index of postings from 37 public sources, refreshed every 5 hours, scores each posting 1-5, and applies in Firefox.
  - The repo has about 32.6k stars and an MIT license.
  - The README has changed substantially from the older LinkedIn-Selenium AIHawk. The older YAML configs such as `plain_text_resume.yaml` are no longer mentioned.
- browser-use averages about 3 seconds per step. Its LLM costs $0.50/$3.00 per 1M input/output tokens and $0.10 cached, or $0.002 per step plus $0.01 per task in the cloud. — [browser-use speed post](https://browser-use.com/posts/speed-matters); [browser-use cost docs](https://docs.browser-use.com/open-source/development/monitoring/costs); [browser-use cloud pricing](https://docs.cloud.browser-use.com/pricing)
- Stagehand calls cost about $0.001-$0.02 each (third-party estimates). Cached actions cost zero tokens. — [tessl.io](https://tessl.io/registry/skills/github/fernandezbaptiste/Skrillz/stagehand-automation); [Stagehand caching](https://docs.stagehand.dev/best-practices/caching)
- Skyvern historically charged $0.05 per step. — [Skyvern blog](https://www.skyvern.com/blog/launch-week-day-1-automating-with-skyvern-got-50-cheaper/)
- Computer-use screenshots cost about 1,000-1,800 input tokens each. — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
- Browserbase costs $0.10-0.12 per browser-hour in overage. — [tinyfish](https://www.tinyfish.ai/blog/browserbase-pricing)
- Manual Workday applications take 20-30 minutes; FastApply claims about 3 minutes (vendor claim). — [dev.to FastApply](https://dev.to/fastapply/how-to-beat-workday-applications-in-2026-the-ats-everyone-hates-and-how-to-auto-fill-it-36n6)
- Tsenta's pricing: 25 free applications, then from $19/mo (third-party, may be outdated). Its "2-3 seconds" claim refers to reaction time after its scanner sees a job, not submit latency. — [scoutify Tsenta review](https://scoutify.com/blog/tsenta-review/); [loopcv directory](https://www.loopcv.pro/directory/tsenta/)

### Inferences
- **Back-of-envelope (my arithmetic, using token counts not prices):**
  - **Schema-first adapter:** form JSON plus profile plus job description is about 6-10k input tokens, and the answers are about 1-2k output tokens. That is 1-3 calls per application, about 10-30k tokens total. With a small model this is a fraction of a cent to a few cents, consistent with AIHawk's "few cents".
  - **Resume tailoring:** adds roughly another 5-10k tokens.
  - **DOM agent (browser-use style):** 20-60 steps x (3-8k input tokens per step) is about 100-400k input tokens. Prompt caching cuts this a lot. At the $0.002-per-step cloud price that is $0.04-0.13, and it takes 1-3 minutes at about 3 seconds per step.
  - **Vision computer-use on a Workday wizard (6-7 pages, many widgets):** 60-150 actions x (about 1.5k screenshot tokens plus history) can exceed 1M input tokens without context trimming. It is the costliest path, so reserve it as a fallback.
- **Time:** the floor is set by page loads and the ATS's own validators (e.g. Greenhouse's 500 ms email debounce, Workday's step transitions), not by LLM latency. Expect about 1-2 minutes for Greenhouse, Lever and Ashby, and 4-10 minutes for Workday including account creation and email verification (estimate).
- Model prices change frequently. The report writer should take current per-token prices from the providers' pricing pages; these were not fetched here.

### Gaps
- No published, measured per-application cost from Tsenta, Simplify or LazyApply.
- Current Claude/OpenAI per-token prices were not fetched in this research pass.
- No measured time-per-application data for agents on Workday, iCIMS or Taleo.
