# Legal, Platform-Risk, Privacy and Unit Economics of an AI Job-Application Agent (Tsenta-like)

Status: researched 2026-11-20. US and EU focus. This is not legal advice. Several items below are unsettled law or rest on secondary sources; uncertainty is flagged inline. Research budget was limited (about 15 tool calls), so privacy and agent-of-user items lean more on inference and are flagged that way.

## 1. Terms of service and case law (LinkedIn, hiQ, Meta v. Bright Data, CFAA after Van Buren, ATS ToS, fate of auto-apply tools)

### Takeaway
The main threat is contract (ToS) enforcement and account bans, not criminal or CFAA liability. After Van Buren and the Ninth Circuit's August 2026 *Amazon v. Perplexity* opinion, a user-directed agent acting in the user's own logged-in session is on its strongest CFAA footing in the Ninth Circuit. But LinkedIn's User Agreement expressly bans bots, browser plugins and credential/cookie sharing, and hiQ shows LinkedIn can win on breach of contract. Building on employer career pages and ATS forms (Tsenta's model) instead of LinkedIn Easy Apply lowers platform risk but does not remove it.

### Cited Findings
**LinkedIn User Agreement (effective November 3, 2025), section 8.2 "Don'ts":**
- 8.2.13: users may not "Use bots or other unauthorized automated methods to access the Services" — [LinkedIn User Agreement](https://www.linkedin.com/legal/user-agreement)
- 8.2.2: users may not "Develop, support or use software, devices, scripts, robots or any other means or processes (such as crawlers, browser plugins and add-ons or any other technology) to scrape or copy the Services" — [LinkedIn User Agreement](https://www.linkedin.com/legal/user-agreement)
- 8.2.1: users may not "use or attempt to use another's account (such as sharing log-in credentials or copying cookies)". A cloud agent that holds the user's LinkedIn session cookies arguably falls under this. — [LinkedIn User Agreement](https://www.linkedin.com/legal/user-agreement)
- LinkedIn now sells its own first-party alternative: a Premium "Apply Assistant" that uses AI to pre-fill applications and draft cover letters, reportedly including for roles not posted on LinkedIn. That gives LinkedIn a competitive reason to police third-party tools. — [Let's Data Science news](https://letsdatascience.com/news/linkedin-launches-premium-apply-assistant-to-autofill-applic-5adb3af3)

**hiQ Labs v. LinkedIn (N.D. Cal. / 9th Cir.):**
- On November 4, 2022, the N.D. Cal. granted LinkedIn summary judgment on breach of contract. It held that the User Agreement's bans on scraping and fake profiles are enforceable. — [Privacy World](https://www.privacyworld.blog/2022/12/linkedins-data-scraping-battle-with-hiq-labs-ends-with-proposed-judgment/)
- The December 2022 consent judgment included $500,000 against hiQ and a permanent injunction. hiQ had to stop scraping, delete its scraped data, code and algorithms, and not use LinkedIn's platform to build a commercial service without written consent. — [Proskauer](https://www.proskauer.com/blog/hiq-and-linkedin-reach-proposed-settlement-in-landmark-scraping-case); [MediaPost](https://www.mediapost.com/publications/article/380493/web-scraper-agrees-to-pay-linkedin-500000-destr.html)
- The stipulated settlement has no precedential value. The CFAA questions were left to future cases. — [Morgan Lewis](https://www.morganlewis.com/blogs/sourcingatmorganlewis/2022/12/linkedin-v-hiq-landmark-data-scraping-suit-provides-guidance-to-data-scrapers-and-web-operators)

**Meta v. Bright Data (N.D. Cal., Judge Chen, Jan 23, 2024):**
- Meta's terms reached only logged-in use. Logged-off scraping of public data did not breach them, because Bright Data was not a "user" while logged off. — [Farella Braun + Martel](https://www.fbm.com/technology/publications/major-decision-affects-law-of-scraping-and-online-data-collection-meta-platforms-v-bright-data/)
- Once Bright Data closed its accounts, Meta could no longer bind it. The court rejected the survival clause. — [Quinn Emanuel](https://www.quinnemanuel.com/the-firm/news-events/client-alert-what-does-the-meta-v-bright-data-summary-judgment-ruling-mean-for-web-scraping/)
- Meta later dropped the suit. Commentators call the ruling narrow and specific to Meta's terms. — [MediaPost](https://www.mediapost.com/publications/article/393996/None); [Zyte](https://www.zyte.com/blog/california-court-meta-ruling/)
- Relevance: an auto-apply agent works logged in, as the user, so it is bound by the ToS. That is the opposite of the Bright Data fact pattern. Bright Data helps only for logged-off job discovery, such as crawling public career pages.

**CFAA after Van Buren (2021) and agentic AI:**
- Van Buren adopted a "gates-up-or-down" test: access is authorized or not. Purpose-based limits do not count, and commentators read time-or-manner restrictions in ToS as not counting either. The Court did not say whether contractual limits, as opposed to technical barriers, can lower a gate. — [Proskauer](https://www.proskauer.com/blog/supreme-court-ends-long-running-circuit-split-over-cfaa-exceeds-authorized-access-issue-adopting-a-narrow-interpretation-that-will-reverberate-in-scraping-disputes-and-litigation-over-departing-employees); [Haynes Boone](https://www.haynesboone.com/news/publications/the-shifting-legal-landscape-surrounding-web-scraping)
- On remand in hiQ, the Ninth Circuit held that CFAA authorization matters only for systems with erected gates, such as password protection. It also considered whether anti-scraping code and cease-and-desist letters count as gates. — [Haynes Boone](https://www.haynesboone.com/news/publications/the-shifting-legal-landscape-surrounding-web-scraping)
- *Amazon.com Services v. Perplexity AI* (9th Cir. No. 26-1444):
  - November 2025: Amazon sued over the Comet browser's shopping agent under the CFAA and California's CDAFA.
  - March 2026: the district court granted a preliminary injunction.
  - August 4, 2026: the Ninth Circuit vacated the injunction. It held that an AI agent is not a "whoever" under the CFAA and cannot itself intentionally access a computer. It held that the user, through their browser, accessed Amazon; Perplexity did not.
  - The court expressly did not decide whether greater developer control could make the developer an accessor. It also did not decide "without authorization," the $5,000 loss element, or tort and contract theories, and it noted Amazon can still regulate access through its ToS. The case continues on remand. — [ZwillGen](https://www.zwillgen.com/artificial-intelligence/web-scraping-digest-9th-circuit-addresses-agentic-ai/)

**ATS and job-board ToS (Workday, Greenhouse, Indeed):**
- Workday's general site Terms of Use reportedly bar interfering with site functionality and bar scraping or data extraction. This comes from a third-party tracker; I could not confirm the full wording. — [Conduct Atlas (scraping)](https://conductatlas.com/platform/workday/workday-terms-of-use/provision/CA-P-076032/prohibition-on-scraping-or-data-extraction/); [Conduct Atlas (interference)](https://conductatlas.com/platform/workday/workday-terms-of-use/provision/CA-P-076029/prohibition-on-interfering-with-site-functionality/)
- One auto-apply service (4dayweek.io) excludes Workday-hosted career sites. Its stated reason is that it excludes platforms whose terms "prohibit or do not clearly permit" third-party automated applications. That is indirect evidence of how the industry reads Workday's terms. — [4dayweek.io acceptable use](https://4dayweek.io/acceptable-use)

**What happened to LinkedIn auto-apply tools and extensions:**
- I found no LinkedIn lawsuit aimed specifically at an auto-apply tool. The observed enforcement is account-level: restrictions, suspensions and closures. Vendor blogs say LinkedIn detects extensions by probing for extension IDs or by comparing traffic patterns. LinkedIn does not publish a list of banned extensions, and restrictions attach to the account, so uninstalling the extension afterwards does not help. These are vendor sources with commercial bias, and widely repeated figures such as "23% restricted within 90 days" have no primary source. — [Scoutify](https://scoutify.com/blog/linkedin-auto-apply/); [Cleverly](https://cleverly.co/blog/why-linkedin-automation-tools-get-your-account-banned-and-what-to-do-instead); [Datablist](https://www.datablist.com/how-to/linkedin-account-restriction); [Graphic Design Junction (2024 extension bans)](https://graphicdesignjunction.com/2024/05/why-linkedin-banned-these-extensions-exploring-the-reasons/)
- Tsenta positions itself as career-page and ATS auto-apply across "50,000+ company career pages", not LinkedIn Easy Apply. One review says the user approves each application before it is submitted. — [Scoutify Tsenta review](https://scoutify.com/blog/tsenta-review/); [scale.jobs comparison](https://scale.jobs/blog/tsenta-vs-scale-jobs-autofill-vs-real-humans-comparison)

### Inferences
- Ranked risk for this product, from most to least likely:
  1. Account bans for the user, with the reputational and churn hit that follows.
  2. Cease-and-desist letters, plus technical blocking such as CAPTCHAs, bot detection and ATS rate limits.
  3. A breach-of-contract or tortious-interference suit against the company for inducing users to breach ToS. I did not verify an inducement theory in any source.
  4. CFAA or CDAFA claims, which are now weaker for user-directed agents in the 9th Circuit, but other circuits are unsettled.
- Design choices that lower risk:
  - Run on the user's device in the user's own browser session; this tracks the Perplexity reasoning that the user is the accessor.
  - Require per-application human approval.
  - Avoid LinkedIn automation entirely. At most, deep-link the user to LinkedIn.
  - Respect rate limits and CAPTCHAs; never solve CAPTCHAs.
  - Apply on employer career pages, where the employer, not the ATS vendor, is the counterparty inviting applications.
  - Honor any cease-and-desist letter promptly. Ignoring one was a factor the hiQ remand weighed as a possible "gate".
- Cloud agents that store users' LinkedIn cookies or passwords clash directly with LinkedIn clause 8.2.1. A desktop app that uses the user's live session avoids credential custody, though it probably still counts as an "unauthorized automated method" under 8.2.13.

### Gaps
- I did not retrieve the verbatim ToS for Indeed, Greenhouse or Lever on bots and automated applications. The Workday wording is from a third-party tracker only.
- I found no primary-source record of LinkedIn suing or sending takedowns to a named auto-apply vendor (for example LazyApply). Anecdotes exist, but I did not verify them.
- How courts outside the 9th Circuit would treat agent access, and the outcome of the *Perplexity* remand, are unknown.

## 2. Acting as agent for the user (consent, authorization, credentials, false statements, EEO and self-ID, work authorization)

### Takeaway
I found no case law specifically on AI agents submitting job applications. Risk therefore comes from general principles: the user is the applicant and makes the attestations, so the product must get informed, specific authorization and keep the user in the loop for any factual attestation. Treat EEO self-ID and work-authorization answers as user-supplied facts the agent must never infer or invent.

### Cited Findings
- *Amazon v. Perplexity* treated the agent as the user's tool and the user as the party who accessed the site. That supports framing the product as a user-directed tool rather than an independent actor. The court left open whether greater developer control changes this. — [ZwillGen](https://www.zwillgen.com/artificial-intelligence/web-scraping-digest-9th-circuit-addresses-agentic-ai/)
- LinkedIn's ToS forbids credential and cookie sharing, so an architecture that has the service hold platform credentials is itself a ToS problem, separate from security. — [LinkedIn User Agreement](https://www.linkedin.com/legal/user-agreement)
- Applicant-side AI litigation is emerging on the employer and vendor side. Job seekers sued Eightfold AI, alleging it secretly scored applicants without knowledge or consent, which they say violates consumer protection laws. This shows plaintiff interest in AI in hiring, though it concerns the other side of the market. — [Yahoo News](https://www.yahoo.com/news/articles/job-seekers-sue-company-scanning-174500494.html)

### Inferences (not sourced; general legal principles to verify with counsel)
- **Consent and authorization:**
  - Use clickwrap terms that appoint the service as a limited agent to fill and submit forms on the user's instruction.
  - Keep per-job approval logs with timestamps and a snapshot of what was submitted. This is evidence the user authorized each submission, and it is useful if an employer or platform complains.
- **False statements:**
  - Application forms usually end with an attestation that the information is true; falsification is commonly grounds for rescinding an offer or termination.
  - An LLM that embellishes a resume, invents years of experience, or answers knockout questions "Yes" to get past filters creates harm to the user and potential deceptive-practices exposure for the vendor, for example under FTC Act section 5 if marketing promises interviews.
  - Mitigations:
    - Answers to factual questions come only from a user-verified profile.
    - Unknown answers stop the flow and ask the user rather than guessing.
    - Keep a do-not-fabricate eval suite.
- **EEO and voluntary self-ID** (race, gender, veteran, disability; the disability form is OFCCP Form CC-305 for federal contractors):
  - These are voluntary, sensitive data.
  - Default to "decline to self-identify" unless the user explicitly pre-sets an answer.
  - In the EU, these fields would be special-category data under GDPR Art. 9.
- **Work authorization and sponsorship:**
  - Answers here are legally significant attestations and may be checked later through the I-9 process.
  - These must be user-set fields and never inferred, for example from nationality or location.
- **Credentials:**
  - Prefer no custody at all: a desktop app that uses the user's existing browser session.
  - If ATS account passwords must be stored (Workday makes candidates create a tenant account per employer), keep them in the OS keychain (macOS Keychain or Windows Credential Manager/DPAPI) on-device, not on the vendor's servers.
  - If cloud storage is unavoidable, use KMS envelope encryption, per-user keys and access logging.

### Gaps
- I found no primary sources on vendor liability for false statements in AI-submitted applications, or any enforcement action on point.
- I did not verify FTC actions against "guaranteed interview" job-search services in this session.
- No source on whether submitting EEO self-ID on a user's behalf raises extra issues under US law.

## 3. Privacy (GDPR, CCPA, retention, LLM provider data use and ZDR, SOC 2, on-device processing)

### Takeaway
Resumes and applicant answers are personal data. EEO, disability and veteran answers are sensitive or special-category data. The vendor is likely a controller under GDPR for its own processing of user profiles, and the LLM provider is a processor. Practical compliance:
- Data minimization and short retention.
- A DPA with the LLM provider, using zero-data-retention terms where eligible.
- A published retention schedule and deletion flow.
- On-device storage of the profile and credentials as a strong differentiator.

SOC 2 matters mainly for B2B (university career centers, outplacement firms), not for B2C job seekers.

### Cited Findings
- Anthropic, as one example LLM provider, documents that some newer features are not ZDR-eligible:
  - Claude Fable 5.2 requires 30-day data retention and is "not available under zero data retention unless expressly authorized".
  - Managed Agents are "not currently eligible" for ZDR or HIPAA BAA coverage.
  - Message Threads are "not ZDR eligible".
  - Source: Claude API skill reference (bundled Anthropic documentation, cached 2026-11-03); live docs at [platform.claude.com](https://platform.claude.com/docs)
  - Implication: model and feature choice affects the privacy posture. Use the stateless Messages API on ZDR-eligible models for resume data.
- Workday publishes its own Recruitment Privacy Statement. This is a reminder that each employer and ATS becomes a separate controller of the data once the application is submitted; the agent vendor cannot recall it. — [Workday Recruitment Privacy Statement](https://www.workday.com/en-us/privacy/archive/recruiting-privacy-statement-20241008.html)

### Inferences (based on background knowledge of GDPR and CCPA; I did not fetch primary texts this session)
- **GDPR:**
  - Lawful basis for core processing is likely contract (Art. 6(1)(b)).
  - EEO-type answers need explicit consent (Art. 9(2)(a)).
  - Users have rights of access, erasure and portability.
  - Sending data to US LLM providers needs a transfer mechanism, such as the EU-US Data Privacy Framework or SCCs.
  - Keep a DPIA if processing is large-scale or involves sensitive data.
- **CCPA/CPRA:**
  - Applies once revenue or data-volume thresholds are met.
  - Ethnicity, citizenship or immigration status and similar fields are "sensitive personal information" and trigger the right to limit their use.
  - Disclose categories of data and retention periods at collection.
- **Retention:** keep profile data while the account is active. Hold per-application snapshots for a fixed window (for example 12 to 24 months) for user records and dispute evidence, then delete. Never use user data to train models without opt-in.
- **On-device processing as a strategy:**
  - Store the profile, resume and credentials locally and send only the minimum context per form to the LLM API under ZDR.
  - Alternatively, use a small local model for classification and field mapping.
  - This also cuts server costs and supports the "user is the accessor" legal posture from section 1.
- **SOC 2 Type II** typically costs tens of thousands of dollars per year plus tooling such as Vanta or Drata. That is an unsourced estimate to verify. B2C buyers rarely ask for it.

### Gaps
- I did not fetch GDPR, CCPA or EDPB primary texts, OpenAI or Google ZDR terms, or SOC 2 cost data in this session. The report writer should treat the GDPR and CCPA points above as background, not verified citations.
- No source on regulator actions against job-search assistant apps specifically.

## 4. AI regulation relevant to hiring (EU AI Act Annex III, NYC Local Law 144, AI disclosure)

### Takeaway
The EU AI Act's employment category (Annex III point 4) targets AI used by or for employers to recruit and select candidates:
- placing targeted job ads
- analyzing and filtering applications
- evaluating candidates

A candidate-side tool that fills forms for the applicant is probably outside Annex III, but this is uncertain: job-matching or ranking jobs for the user is not employer-side evaluation. Its high-risk obligations were in any case pushed to December 2, 2027 by the Digital Omnibus. The Art. 50 transparency duties (from August 2, 2026) are more likely to matter, for example if AI-generated text such as cover letters must be marked or if the tool interacts with recruiters.

NYC Local Law 144 applies to employers and employment agencies that use AEDTs to substantially assist hiring decisions. A candidate-side tool is very likely out of scope unless the product starts acting as an agency or screening for employers.

### Cited Findings
- Annex III covers AI used to place targeted job advertisements, analyze and filter job applications, and evaluate candidates. Obligations also reach decisions on promotion and termination, task allocation and monitoring. — [Ogletree](https://ogletree.com/insights-resources/blog-posts/eu-nears-approval-of-agreement-to-delay-rules-for-ai-use-in-employment-decisions/); [DLA Piper](https://knowledge.dlapiper.com/dlapiperknowledge/globalemploymentlatestdevelopments/2026/The-Digital-AI-Omnibus-Proposed-deferral-of-high-risk-AI-obligations-under-the-AI-Act)
- The Digital Omnibus on AI moves the Annex III high-risk deadline from August 2, 2026 to December 2, 2027. Council and Parliament reached a provisional agreement on May 7, 2026. — [Sidley Data Matters](https://datamatters.sidley.com/2026/06/22/eu-lawmakers-reach-provisional-agreement-to-delay-key-eu-ai-act-obligations/); [ActuIA](https://actuia.com/en/news/hr-tools-and-artificial-intelligence-europe-delays-high-risk-obligations-to-december-2027/)
- Sources conflict on formal adoption status:
  - One reports Parliament approval on June 16, 2026.
  - Partena reports publication in the Official Journal on July 24, 2026.
  - Others say it is effective only on OJ publication.
  - Verify against EUR-Lex. — [Partena Professional](https://www.partena-professional.be/en/what-will-change-employers-under-ai-regulation-digital-omnibus-introduces-potential-relaxations); [fintech.global](https://fintech.global/2026/09/02/brussels-delays-high-risk-ai-rules-not-the-rulebook-itself/)
- Art. 50 transparency obligations were reportedly not postponed and apply from August 2, 2026. — [Airia](https://airia.com/the-eu-ai-act-just-got-an-extension-heres-how-to-use-it/)
- NYC LL144 applies to employers and employment agencies using AEDTs to evaluate candidates or employees residing in NYC. This comes from a secondary source; verify against the statute and DCWP rules. — [Vaquill](https://www.vaquill.ai/blog/nyc-local-law-144-automated-hiring-explained)
- NY State Comptroller audit (December 2, 2025) of DCWP enforcement, July 2023 to June 2025:
  - It found enforcement "ineffective".
  - Only two AEDT complaints were received.
  - DCWP identified 1 non-compliance issue versus 17 potential issues found by the auditors.
  - DCWP agreed to adopt most recommendations, and law firms flag rising employer risk. — [NY OSC audit](https://www.osc.ny.gov/state-agencies/audits/2025/12/02/enforcement-local-law-144-automated-employment-decision-tools); [DLA Piper](https://www.dlapiper.com/en/insights/publications/2026/01/critical-audit-of-nyc-ai-hiring-law-signals-increased-risk-for-employers)

### Inferences
- **Candidate-side tool under the EU AI Act:** the provider is likely not a high-risk provider under Annex III(4), because the system does not make or assist the employer's decision. However:
  - If the product later offers employers a "verified candidate" feed or ranks candidates for recruiters, it moves into Annex III.
  - GPAI-based features still trigger Art. 50 duties to disclose that users are interacting with AI and to mark synthetic content. The scope for text that a human reviews is debated.
  - Flag as uncertain and get counsel's view.
- **Employer-side reaction is a bigger commercial risk than regulation.** Employers and ATS vendors increasingly detect and filter AI-mass-applied candidates. Some application forms ask candidates to attest that they did not use AI or bots. That is a user-attestation issue, see section 2. This is not sourced in this session.
- **AI disclosure:** voluntarily disclosing AI-assisted cover letters is not legally required in the US as far as found, but it reduces deception risk.

### Gaps
- I did not retrieve the Annex III text from EUR-Lex directly, or any official Commission guidance on candidate-side tools.
- I did not research other US state laws (Colorado AI Act timeline, Illinois HB 3773 effective January 2026, California CRD regulations). They mainly bind employers, but the report should note them.

## 5. Unit economics (LLM cost per application, browser infra, competitor pricing, CAC, churn)

### Takeaway
LLM cost per application is low if the agent reads the DOM or accessibility tree rather than screenshots:
- about $0.01 on Haiku-class models
- roughly $0.15 to $0.35 on Sonnet-class models
- roughly $0.30 to $0.70 on Opus-class models

Screenshot-driven computer use can cost 3 to 5 times more. With competitor pricing clustered at about $20 to $100 per month, gross margin is healthy if the agent runs on the user's desktop, which removes cloud browser cost. The hard economics are CAC and churn: job seekers churn by design once hired, and consumer subscription apps lose over half of monthly subscribers within about three months.

### Cited Findings
**Current API pricing (Anthropic first-party, per 1M tokens, cached 2026-11-03):**

| Model | Input | Output | Cache reads |
|---|---|---|---|
| Claude Haiku 5.5 | $0.10 | $0.50 | not listed (prompts up to 100K tokens; $0.50 / $2.50 beyond) |
| Claude Sonnet 5.5 | $2.00 | $10.00 | $0.10 |
| Claude Opus 5.5 | $4.00 | $20.00 | $0.20 |

- Batch API runs at 50% cost but is asynchronous, so it does not suit a live form-filling loop.
- Source: Claude API skill reference (bundled Anthropic docs); live pricing at [platform.claude.com pricing](https://platform.claude.com/docs/en/about-claude/pricing)

**Competitor pricing (third-party sources; conflicting and possibly affiliate-driven):**
- **Tsenta:** "$19 to $99/mo; 25 free apps", per a review site. Another lists a one-time "$199 for 250 applications". The official pricing page is at tsenta.com/pricing. — [LoopCV directory](https://www.loopcv.pro/directory/tsenta/); [scale.jobs](https://scale.jobs/blog/tsenta-vs-scale-jobs-autofill-vs-real-humans-comparison); [Tsenta blog](https://tsenta.com/blog/tsenta-vs-loopcv)
- **LazyApply:** sources variously cite $99/year Basic, $149/month Premium, or one-time pricing. — [tryapplynow review](https://www.tryapplynow.com/blog/lazyapply-review); [aitoolsatlas](https://aitoolsatlas.ai/tools/lazyapply/pricing)
- **Sonara:** sources cite $9 per month, $19.99 per month, $23.95 every 4 weeks, or up to $80 per month for 420 applications. — [Jobr comparison](https://jobr.pro/post/jobr-vs-lazyapply-aiapply-sonara); [quickads](https://www.quickads.ai/blog/sonaraai-reviews-comparison-with-competitors)
- **AutoApplyMax:** free tier, $9.99 per month, $29.99 per month unlimited. — [Capterra](https://www.capterra.com/p/10040139/AutoApplyMax/)
- **Applyre AI:** $49.99 for 40 applications per month. — [creati.ai](https://creati.ai/ai-tools/applyre-ai/)

**Churn and CAC:**
- Consumer subscription apps lose more than half of monthly subscribers within three months and over half of annual subscribers in year one. — [Phil Carter on 20VC (summary)](https://www.recall.it/summary/startup/phil-carter-growth-loops-cac-ltv-benchmarks-pricing-discounts-paywalls-or-e1204)
- About a third of monthly cancellers cancel within three days of paying. — [FunnelFox](https://blog.funnelfox.com/keeping-users-after-first-payment/)
- Monthly-plan churn for subscription apps is about 15% per month, per one source. — [Elena Verna](https://www.elenaverna.com/i/159919614/first-term-churn)
- I found no CAC benchmark specific to career tools.

### Inferences (my estimates, not sourced; show the math so the writer can adjust)
**Token model per application, DOM or accessibility-tree agent:**
- Inputs:
  - User profile and resume: about 3K tokens.
  - Job description: about 1.5K tokens.
  - Form DOM per page after pruning: about 5 to 15K tokens.
  - Pages: 1 to 6 (Greenhouse or Lever is usually 1 page; Workday is 4 to 6 steps).
  - Context is re-sent each step.
- Totals: about 40K to 120K input tokens and 3K to 8K output tokens per application, including a tailored cover letter or answers.
- Cost at those volumes:
  - Sonnet 5.5, 80K in and 5K out: $0.16 + $0.05 = about $0.21. Prompt caching of the stable profile and system prefix (cache reads $0.10 per 1M) can cut input cost substantially.
  - Haiku 5.5, same volume: about $0.008 + $0.0025 = about $0.01.
  - Opus 5.5, same volume: about $0.32 + $0.10 = about $0.42.
- Screenshot-based computer use runs about 20 to 40 steps, each adding an image of roughly 1 to 1.5K tokens plus growing history. That plausibly reaches 300K to 600K input tokens, or about $0.60 to $1.20 per application on Sonnet-class models.
- Recommended architecture:
  - Deterministic ATS adapters (Greenhouse, Lever, Ashby, Workday) handle most fields with no LLM call.
  - A cheap model maps fields.
  - A mid-tier model writes free-text answers.
  - Escalate only on failure.

**Per-user cost and margin:**
- A heavy user doing 300 applications per month on Sonnet costs about $63 in LLM spend at the uncached estimate, or perhaps $20 to $30 with caching.
- On a hybrid Haiku and Sonnet pipeline, it costs perhaps $5 to $15.
- At $30 to $60 per month pricing, the hybrid approach is needed for 70%+ gross margin.

**Browser infrastructure:**
- A desktop app runs the browser locally, at near-zero marginal infra cost.
- Cloud headless browsers (Browserbase-style services, or self-hosted Playwright on containers) add per-session-minute costs plus residential proxies to avoid IP blocks. Proxies also raise the platform-evasion legal optics.
- Pricing was not verified this session.

**LTV:**
- Job searches end. With about 15 to 30% monthly churn and $30 ARPU, LTV is roughly $100 to $200 gross. CAC on paid social must stay well below that.
- Referral and word of mouth, a free tier (for example 25 free applications), and university or outplacement B2B2C channels are the likely levers. These are unsourced.

### Gaps
- No verified cloud-browser or proxy pricing.
- No measured tokens-per-application data from a real agent. The figures above are estimates and should be benchmarked.
- No OpenAI or Google pricing compared.
- No career-tool CAC data.
- Tsenta's official pricing page was not fetched, so its prices are unverified.

## 6. Desktop app distribution (macOS signing and notarization, Windows signing, auto-update)

### Takeaway
On macOS, ship Developer ID-signed and notarized builds. Since Sequoia, unnotarized apps can no longer be opened with Control-click and need a trip to System Settings, which is fatal for consumer onboarding. On Windows, Azure Artifact Signing (formerly Trusted Signing) at about $9.99 per month is the cheapest route. Neither it nor EV certificates give instant SmartScreen trust any more; reputation builds over downloads.

### Cited Findings
- **macOS:**
  - Developer ID signing requires a paid Apple Developer membership.
  - The workflow is: sign with a Developer ID certificate, submit via Xcode or `xcrun notarytool`, then staple the ticket. — [Xojo blog](https://blog.xojo.com/?p=13510); [Eclectic Light](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/)
  - Notarized apps do not trigger Gatekeeper warnings. — [Eclectic Light](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/)
  - macOS Sequoia removed the Control-click Gatekeeper override for software that is not correctly signed or notarized. — [MacRumors](https://macrumors.com/2024/08/06/macos-sequoia-gatekeeper-security-change)
- **Windows:**
  - Azure Artifact Signing costs about $9.99 per month and is generally available in the US, Canada, the EU and the UK.
  - It does not give instant SmartScreen trust; reputation builds per file hash.
  - Since 2024, EV certificates no longer bypass SmartScreen on first download and follow the same reputation process as OV certificates. — [Microsoft Learn: code signing options](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options); [Azure pricing page](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/) (it showed placeholder prices when searched)
  - A reseller still claims EV gets instant trust, which contradicts Microsoft's own documentation. — [CheapSSLSecurity](https://cheapsslsecurity.com/fastssl/ev-code-signing-certificate.html)

### Inferences
- **Auto-update:**
  - Electron: electron-updater with GitHub Releases or S3; macOS updates must be signed and notarized.
  - Tauri: the built-in updater with signed update manifests.
  - Native macOS: Sparkle with EdDSA-signed appcasts.
  - Windows: Squirrel or MSIX.
  - Sign every update artifact, and pin the update public key in the app.
  - These are standard practices; I did not verify them against docs this session.
- **Budget:** Apple Developer Program fee plus about $120 per year for Artifact Signing, plus CI time. The Apple fee is commonly $99 per year but was not verified in this session.
- **Third-party automation risk inside desktop apps:**
  - Shipping an embedded Chromium or CDP-controlled browser is ordinary.
  - Avoid techniques that look like malware, such as injecting into the user's main Chrome profile or reading cookies from it.
  - Such techniques could trip antivirus software or macOS TCC prompts and hurt notarization trust.

### Gaps
- I did not confirm the Apple Developer Program fee or Microsoft Store and MSIX alternatives from primary sources.
- I did not research Mac App Store eligibility; App Store sandboxing would likely block browser automation.
