# Tsenta: What the Product Does and How It Appears to Work (as of Nov 2026)

Note on sourcing: "Stated" means Tsenta's own pages (tsenta.com, docs.tsenta.com, tsenta.com/llms.txt, privacy, AI disclosure) or YC pages written by the founders. Third-party directories and aggregators are marked as such. Some third-party pages (YC profile blurb, StartupHub, HUGE Magazine Mar 2026) still describe an **older desktop/on-device architecture** that Tsenta's current docs say is **retired**. The product has shifted to cloud execution.

## 1. Features and end-to-end user workflow

### Takeaway
Tsenta is a four-stage pipeline (Find, Prep, Apply, Track). It ingests a PDF resume into a structured profile, matches new postings scraped from career pages against that resume, tailors a resume and cover letter per role (Off, Honest or Aggressive), fills and submits ATS forms from cloud workers, with optional resume-diff and form-review gates, and then tracks outcomes by reading the user's Gmail or Outlook.

### Cited Findings
**Positioning and stages**
- Self-description: "A Y Combinator-backed (S26) AI agent that applies to jobs for you and tracks every application." The four stages are Find, Prep, Apply and Track. — [tsenta.com](https://tsenta.com); [tsenta.com/llms.txt](https://tsenta.com/llms.txt)
- **Find:** Tsenta says it "watches 300,000+ company career pages" and ranks new roles against your resume in a match feed. It claims roles can surface hours before LinkedIn or Indeed index them, and that matching uses the resume rather than keyword search alone. — [tsenta.com](https://tsenta.com); [llms.txt](https://tsenta.com/llms.txt)
- Earlier or alternative scale claims: the YC launch post cites "over 2 million jobs, updated every couple of hours". A third-party summary of an older AI-disclosure version cites 50,000+ career pages, and HUGE Magazine (Mar 2026) cites 1M+ listings. — [YC Launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews); [HUGE Magazine](https://huge-magazine.pages.dev/feature/tsenta)
- The AI disclosure says matching "scores each newly-posted role against your résumé." — [AI disclosure](https://tsenta.com/ai-disclosure)
- **Prep:** Tsenta reads each job description, pulls out must-haves and disqualifiers, rewrites bullets, and drafts a cover letter when the form asks for one. Tailoring is included on all plans. The AI disclosure describes this as "Per-role résumé and cover letter generation from the actual job description", with keyword alignment and ATS-safe formatting. — [tsenta.com](https://tsenta.com); [AI disclosure](https://tsenta.com/ai-disclosure); [llms.txt](https://tsenta.com/llms.txt)
- **Apply:** Tsenta "logs in to supported company career sites, fills every field, drafts open-ended answers in your voice, uploads documents, and submits", and this runs "in Tsenta's cloud, so no device needs to stay on." The AI disclosure lists "Intelligent form recognition and auto-filling on supported company career sites" and "End-to-end application handling: login, every field, upload." — [tsenta.com](https://tsenta.com); [AI disclosure](https://tsenta.com/ai-disclosure)
- **Track:** Every application goes into a tracker. Recruiter replies are routed to the matching application, and statuses update automatically. — [tsenta.com](https://tsenta.com)

**Onboarding, profile and resume**
- Profile fields are contact details, work history, education, skills, work authorization and application preferences. Projects, certifications and custom sections are optional. Tsenta flags missing fields. — [Docs: profile and resume](https://docs.tsenta.com/product/profile-and-resume.md)
- Initial web setup takes a PDF under 10 MB. After setup, users can import a compatible DOCX template, though complex formatting may not carry over exactly. — [Docs: profile and resume](https://docs.tsenta.com/product/profile-and-resume.md)
- Users can keep multiple resume profiles (create, duplicate, rename, import, delete), set a default, and choose one per application. — [Docs: profile and resume](https://docs.tsenta.com/product/profile-and-resume.md)
- Tailoring modes:
  - **Off:** no rewriting.
  - **Honest:** rewords real experience.
  - **Aggressive:** "may stretch claims."
  - Docs recommend starting with resume auto-approval off. — [Docs: profile and resume](https://docs.tsenta.com/product/profile-and-resume.md)
- Users can edit a tailored resume in an Edit/Save view or through a "review chat" beside the resume. Saying "always" or "from now on" in that chat keeps the change for future resumes ("What Tsenta remembers" in Settings, for PDF-based profiles only). — [Docs: FAQ](https://docs.tsenta.com/product/faq.md); [Docs: profile and resume](https://docs.tsenta.com/product/profile-and-resume.md)
- Resume extraction is asynchronous. The agent API polls `get-profile-status` until `profileExtractionStatus` = `completed`, which typically takes 30 to 60 seconds, then reads `missingForApplication`. The default profile (address, ZIP, work authorization) "is a guess and should be confirmed." — [Docs: agent quickstart](https://docs.tsenta.com/product/agent-quickstart.md)
- Work authorization and sponsorship answers feed both matching and form answers. The product explicitly targets international students (F-1/OPT). — [Docs: FAQ](https://docs.tsenta.com/product/faq.md); [llms.txt](https://tsenta.com/llms.txt)

**Application state machine (exposed through the API)**
- `apply-to-job(jobIds)` queues applications.
- With resume auto-approval off (the default), applications wait as `PENDING_RESUME_REVIEW`. The user fetches the PDF (link valid 5 minutes) and calls `approve-application`.
- With review-before-submit on, applications stop as `PENDING_SUBMIT_REVIEW`. The user reads the filled answers with `get-application-review`, then calls `submit-application-review` with approve (optional edits) or reject. A reject returns the application to the allowance.
- `get-evaluation-summary` returns counts by status and a one-sentence verdict. — [Docs: agent quickstart](https://docs.tsenta.com/product/agent-quickstart.md)
- A completed record "may include captured answers, documents, and a confirmation, depending on the employer system." Starting an application or seeing a filled form does not confirm submission. — [Docs: how applications work](https://docs.tsenta.com/product/how-auto-apply-works.md); [FAQ](https://docs.tsenta.com/product/faq.md)
- To reapply after a submission, the user cancels at form review and then chooses Reapply. Sent applications cannot be changed. — [Docs: profile and resume](https://docs.tsenta.com/product/profile-and-resume.md)

**Tracking and email**
- Connecting email is optional. With access, Tsenta reads job-related mail (confirmations, recruiter replies, interview invites, rejections) and enters verification codes during applications. It drafts recruiter replies into the user's drafts folder and "does not send mail from your account on its own." — [tsenta.com](https://tsenta.com); [Privacy](https://tsenta.com/privacy)
- Gmail scopes are `gmail.readonly` and `gmail.compose`. — [Privacy](https://tsenta.com/privacy)

**Networking add-on**
- MCP tools can find a company's best contact, return "only verified work emails", and save email or LinkedIn drafts. "Tsenta never sends outreach." Company searches and email lookups share one daily allowance. — [Docs: MCP connector](https://docs.tsenta.com/product/mcp-connector.md)

**Interview prep (Beta)**
- Includes:
  - an AI mock interviewer built from your real interview transcript (Zoom, Google Meet or Otter)
  - 3,400+ coding problems from 650+ companies' lists, in eight languages plus SQL
  - a 20-lesson system-design course with 100 whiteboard prompts
  - transcript scoring. — [tsenta.com](https://tsenta.com); [llms.txt](https://tsenta.com/llms.txt)

### Inferences
- The core data model is likely: Job (scraped from career pages, tagged with ATS type and `isSupportedAts`), ResumeProfile (structured JSON extracted from a PDF by an LLM), Application (states such as QUEUED, PENDING_RESUME_REVIEW, PENDING_SUBMIT_REVIEW, SUBMITTED, FAILED or SKIPPED) and EmailMessage (linked to an Application).
- The "300,000+ career pages" claim suggests crawling public ATS job-board endpoints for many companies rather than LinkedIn or Indeed. Tsenta says it does not apply through LinkedIn Easy Apply ([llms.txt](https://tsenta.com/llms.txt)).
- Saving "always" preferences from the review chat implies a per-user memory of style rules that is injected into later tailoring prompts.

### Gaps
- No public detail on the matching algorithm (embeddings versus LLM scoring) or on the match-threshold scale.
- No public detail on how open-ended answers are kept "in your voice" (for example, which samples are used).

## 2. Surfaces: what each does, and the desktop history

### Takeaway
The current surfaces are a web dashboard (the primary one), iOS and Android apps, iMessage and WhatsApp, a Chrome extension, and a remote MCP server plus an HTTP agent API. The native desktop app (macOS, Windows, Linux), which ran local, on-device browser automation, is now **retired**, and all submission runs in Tsenta's cloud.

### Cited Findings
- **Web dashboard** (dashboard.tsenta.com) covers discovery, application review, profile, tracker, inbox and settings. It "has the broadest set of controls." — [Docs: apps and surfaces](https://docs.tsenta.com/product/apps-and-surfaces.md)
- **iOS and Android** let users find roles, apply, track and manage. Some controls appear on the web first. Billing goes through Apple or Google for in-app subscriptions. — [Docs: apps and surfaces](https://docs.tsenta.com/product/apps-and-surfaces.md); [FAQ](https://docs.tsenta.com/product/faq.md)
- **iMessage and WhatsApp** (entry at tsenta.com/messaging): users can search, choose a role, start applications and check status. The user texts what they want, gets matching roles, and a "yes" or "apply" reply starts the application. — [Docs: apps and surfaces](https://docs.tsenta.com/product/apps-and-surfaces.md); [tsenta.com](https://tsenta.com); [AI disclosure](https://tsenta.com/ai-disclosure)
- **Chrome extension:** on a supported job page (LinkedIn, Indeed or a career page) the user sends the role to Tsenta. The extension "captures the role and checks where it would be applied to." "Submission runs in Tsenta's cloud workflow, not inside your current tab." — [Docs: apps and surfaces](https://docs.tsenta.com/product/apps-and-surfaces.md); [Docs: supported systems](https://docs.tsenta.com/product/supported-job-boards.md); [llms.txt](https://tsenta.com/llms.txt)
- **MCP server:**
  - Endpoint is `https://api.autojobs.me/api/v1/mcp`, with OAuth.
  - Works as a Claude connector, a ChatGPT plugin, and in Cursor, Codex and any remote-MCP client with OAuth.
  - Example: `claude mcp add --transport http tsenta https://api.autojobs.me/api/v1/mcp`.
  - Tools cover resume profiles, application review and status, tracker, inbox, networking and remaining allowance. — [Docs: MCP connector](https://docs.tsenta.com/product/mcp-connector.md); [tsenta.com](https://tsenta.com)
- **HTTP agent API:**
  - Base URL is `https://api.autojobs.me`.
  - Signup: `POST /api/v1/agent-signup/start` (email, agent_name) sends a 6-digit email code (expires in 10 minutes, 5 attempts). `POST /api/v1/agent-signup/verify` returns an access token (1 hour), a refresh token (30 days idle) and a client_id.
  - Tools: `GET /api/v1/agent/tools`, `POST /api/v1/agent/tools/{tool}`.
  - Other endpoints: OpenAPI at `/api/v1/agent/openapi.json`, `POST /oauth/token`.
  - Named tools: get-profile-status, submit-resume, set-personal-info, set-work-authorization, get-job-recommendations, apply-to-job, get-application-status, approve-application, set-apply-preferences, get-application-review, submit-application-review, get-evaluation-summary.
  - Errors include 423 `paused` and 429 `rate_limited` with `retry_after`. Some tools have daily caps that reset at midnight UTC. — [Docs: agent quickstart](https://docs.tsenta.com/product/agent-quickstart.md)
- **Desktop app:** "The native desktop app is retired; use the web dashboard instead." — [Docs: apps and surfaces](https://docs.tsenta.com/product/apps-and-surfaces.md)
- **Earlier desktop architecture (third-party, March 2026):**
  - "AI-native, on-device job automation."
  - A desktop app for Mac (Apple Silicon), Windows and Linux.
  - Browser automation ran locally, which the article claims made it harder for anti-bot systems to detect.
  - Users could watch live automation, and multiple applications ran in parallel.
  - At the time it supported 12+ ATSs, including Workday, Greenhouse, Lever and Ashby. — [HUGE Magazine, Mar 17 2026](https://huge-magazine.pages.dev/feature/tsenta)
  - A search-engine summary of older docs mentioned builds for macOS (Apple Silicon), Windows 11/10 x64, and Linux (AppImage, .deb, .rpm, .zip), and a flow of watching applications live, pausing and editing fields. I did not verify this on a live docs page.
  - StartupHub and the YC profile blurb still describe it as an on-device "desktop app." — [StartupHub](https://www.startuphub.ai/startups/tsenta)
- **Remnant of the live-watch mode:** the AI disclosure still lists "Live application overlay or fully headless (replay later)," and llms.txt says users can "watch each application as it happens, or run headless and review the recording later." — [AI disclosure](https://tsenta.com/ai-disclosure); [llms.txt](https://tsenta.com/llms.txt)

### Inferences
- **Why desktop first.** The likely reasons (inferred) were: the user's residential IP and real browser fingerprint reduce bot detection and CAPTCHA rates; the user's existing logins and cookies are available; there is zero compute cost per application; and the user gets trust and transparency from watching. The HUGE article states the anti-detection rationale explicitly.
- **Why the move to cloud.** The likely reasons (inferred) were: there is no need to keep a device on (stated as a benefit on the homepage); it enables mobile and messaging-first usage and Auto Apply at 150/day; and the company controls updates. Cloud runs are probably recorded as session replays so the "replay later" feature works.
- **Possible earlier brand.** The API domain `autojobs.me` suggests an earlier or alternate product brand (AutoJobs). I found no source confirming this.

### Gaps
- No public MCP tool list beyond the API tool names.
- No public detail on the cloud browser stack (Playwright, a headless provider, proxies).
- The exact retirement date of the desktop app is unknown.

## 3. Public technical hints (stack, subprocessors, LLMs)

### Takeaway
The privacy policy names Anthropic (Claude), OpenAI and Microsoft Azure AI Foundry as LLM providers. Other named vendors are OVHcloud for hosting, Neon Postgres, Cloudflare, Firebase Auth, PostHog, Sentry, Resend and AWS SES, Composio for legacy Gmail and all Outlook mail, and Dodo Payments. The marketing site appears to be Next.js on Vercel, and the docs run on Mintlify. Job postings reveal no stack.

### Cited Findings
- Subprocessors by category:
  - **Hosting and data:** OVHcloud (application hosting), Neon (managed PostgreSQL), Cloudflare (CDN, DDoS, edge).
  - **Auth:** Firebase Authentication.
  - **LLMs:** Anthropic (Claude), OpenAI, and Microsoft Azure AI Foundry (which "runs OpenAI and other models in Microsoft's cloud").
  - **Analytics and monitoring:** PostHog, Sentry.
  - **Transactional email:** Resend, AWS SES.
  - **Payments:** Dodo Payments.
  - **Mail integration:** Gmail through Tsenta's own Google OAuth app. Earlier-connected Gmail and all Outlook go through Composio. — [Privacy](https://tsenta.com/privacy)
- Retention: synced job messages are kept until account deletion. Records of checked non-job emails are deleted within 45 days. The only contact listed is agnay@tsenta.com, and no corporate entity or address is given. — [Privacy](https://tsenta.com/privacy)
- The docs are built on Mintlify and expose `llms.txt`. The site also publishes tsenta.com/llms.txt and tsenta.com/agents.md, with a "Next steps for agents" section aimed at AI agents. — [docs.tsenta.com](https://docs.tsenta.com); [llms.txt](https://tsenta.com/llms.txt)
- A third-party scan of tsenta.com (2026-11-17) detected Next.js, Tailwind, Vercel, Ghost, GA4, Meta Pixel and Datadog. This is a detection tool's output, not a Tsenta statement. — [StartupHub](https://www.startuphub.ai/startups/tsenta)
- The YC job posting is for one Founding Engineer in Bengaluru (₹1.2M–₹4.8M, 3+ years). It lists no tech stack. — [YC jobs](https://www.ycombinator.com/companies/tsenta/jobs)
- The AI disclosure page names no model provider. — [AI disclosure](https://tsenta.com/ai-disclosure)

### Inferences
- A multi-LLM setup with Azure AI Foundry suggests cost and routing optimization: cheap models for matching and extraction, Claude or GPT for tailoring. At roughly 2–3 cents per application all-in, LLM and browser costs per application must be very low.
- OVHcloud hosting (cheap bare metal or VPS) fits running many headless browsers economically.
- Composio usage suggests they bootstrapped mail integrations with a third-party connector before building their own Gmail OAuth app, which requires Google restricted-scope verification.

### Gaps
- No found HN posts, engineering blog, or founder tweets with technical detail. YourStory returned 403, and the employbl job mirror returned 429.
- The desktop app's framework (Electron or otherwise) is unknown.

## 4. Pricing, traction, funding, timeline, ATS coverage

### Takeaway
Current pricing is 25 free applications, then $19, $39 or $99 per 30 days for 600, 1,500 or 4,500 applications, plus a wallet at $0.10 per application. Only successful submissions are charged. Tsenta and YC claim roughly $3M annualized within about three months and 90k+ job seekers. Funding is the standard YC S26 deal, reported as about $500K. The launch claims 30+ ATSs, but no current Tsenta page names them.

### Cited Findings
**Pricing**
- Plans:
  - **Free:** 25 applications, no card.
  - **Starter:** $19 for 600 applications per 30 days (about 20/day).
  - **Pro:** $39 for 1,500 (about 50/day).
  - **Power:** $99 for 4,500 (about 150/day), and includes Auto Apply.
  - Only successful submissions count, which works out to about 2–3 cents per application. — [tsenta.com](https://tsenta.com)
- Wallet top-ups cost $0.10 per application ($5–$500), do not expire, and are used after the monthly allowance. Fixed credit packs are no longer sold. — [Docs: FAQ](https://docs.tsenta.com/product/faq.md)
- Earlier pricing (Mar 2026, third-party): Free at 5 applications/day, Pro at $9.99/month "unlimited," and a one-week trial. — [HUGE Magazine](https://huge-magazine.pages.dev/feature/tsenta)

**Traction**
- The YC profile says about $3M annualized in three months and 90,000+ job seekers. The launch post says 45,000+ users and "over 70% of paid users landed interviews," with interviews at Cisco, Goldman Sachs, JPMorgan, Intel, NVIDIA, Scale AI, SpaceX and others. — [YC company](https://www.ycombinator.com/companies/tsenta); [YC Launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- Third-party figures conflict:
  - arr.club reports crossing $3.5M ARR ($290K MRR, 137K+ sign-ups) on one page and lists $1.2M ARR elsewhere.
  - A search summary claims they entered YC at about $15K MRR and reached $250K within 12 weeks.
  - StartupHub models revenue at about $468K.
  - All of these are unverified. — [arr.club signal](https://www.arr.club/signal/tsenta-crossed-3-5m-arr); [arr.club](https://www.arr.club/tsenta); [StartupHub](https://www.startuphub.ai/startups/tsenta)

**Funding**
- Funding is reported as about $500K from YC (seed), or as ₹5 crore by NewsBytes. Simplify lists $130K, which looks outdated. — [StartupHub](https://www.startuphub.ai/startups/tsenta); [NewsBytes](https://www.newsbytesapp.com/news/business/tsenta-founders-raise-rs5cr-from-y-combinator-for-ai-platform/tldr); [Simplify](https://simplify.jobs/c/Tsenta)

**Timeline and team**
- YC Summer 2026. YC lists the company as founded in 2026, a team of 2, based in San Francisco, with Jared Friedman as primary partner. — [YC company](https://www.ycombinator.com/companies/tsenta)
- Other sources disagree on location and founding year: StartupHub says Indianapolis, and some sources say 2025 or 2023. — [StartupHub](https://www.startuphub.ai/startups/tsenta)
- Press listed on YC: AOL and Inside Indiana Business (Apr 24 2026), YourStory (Jun 11 2026), Moneycontrol (Jun 29) and Startuppedia (Jun 30). — [YC company](https://www.ycombinator.com/companies/tsenta)
- Founders:
  - Agnay Srivastava (CEO): CS + AI at Rose-Hulman; previously at VIAVI, GrapheneAI (MLOps) and Paytm.
  - Pulkit Gupta (CTO): CS at Rose-Hulman; previously at RelateXR, Dexter Capital and Multibhashi.
  - They built Tsenta after manually applying to 3,000+ jobs as international students. NewsBytes reports their ages as 21 and 19. — [YC company](https://www.ycombinator.com/companies/tsenta); [YC Launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews); [NewsBytes](https://www.newsbytesapp.com/news/business/tsenta-founders-raise-rs5cr-from-y-combinator-for-ai-platform/tldr)
- The YC launch post says the employer side is being built next. — [YC Launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)

**ATS coverage**
- The launch post claims 30+ ATS platforms, "including account creation" and OTP handling. — [YC Launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- The current docs name no ATS. To check eligibility, users add a job link. "Recognizing a page is different from supporting submission." The docs say Tsenta "does not support every employer system or role," and users can request support at founders@tsenta.com. — [Docs: supported systems](https://docs.tsenta.com/product/supported-job-boards.md); [tsenta.com](https://tsenta.com)
- Previously named ATSs were Workday, Greenhouse, Lever and Ashby (HUGE, Mar 2026). A search summary of an older AI-disclosure version also listed Rippling, iCIMS and BambooHR. — [HUGE Magazine](https://huge-magazine.pages.dev/feature/tsenta)
- Tsenta does not apply through LinkedIn Easy Apply. — [llms.txt](https://tsenta.com/llms.txt)

### Inferences
- Charging only for successful submissions means each ATS adapter must detect submission confirmation reliably, and the business absorbs the cost of failed runs.

### Gaps
- No primary-source current ATS list. No verified funding amount beyond YC's standard deal.

## 5. Human-in-the-loop, CAPTCHAs, logins, ATS accounts

### Takeaway
There are three independent controls: resume auto-approval (a resume diff gate), review before submit (a filled-form gate, on compatible systems only) and Auto Apply (Power plan, with no review). Tsenta says it handles ATS login and account creation, email verification and OTPs on supported ATSs, reading codes from the connected inbox. It says nothing public about CAPTCHAs.

### Cited Findings
- Resume auto-approval: when off, tailored applications pause with a diff for the user to approve or edit. Review-before-submit pauses compatible forms after they are filled, and other systems may proceed without the pause. Auto Apply uses its own filters, daily cap, match threshold and resume settings, and skips manual review. — [Docs: how applications work](https://docs.tsenta.com/product/how-auto-apply-works.md); [tsenta.com](https://tsenta.com)
- Auto Apply is on the Power plan and "can apply up to four times a day" (as batch runs). — [llms.txt](https://tsenta.com/llms.txt)
- "Every change Tsenta makes is shown to the user before it goes out," with a "Diff view of every change before send (approve / edit gate)." In messaging, users reply "apply" to confirm. — [AI disclosure](https://tsenta.com/ai-disclosure)
- Connecting to an MCP client "does not guarantee a prompt before every change." — [Docs: MCP connector](https://docs.tsenta.com/product/mcp-connector.md)
- Tsenta "handles account creation, email verification, and filling in OTPs on the supported ATSs." — [YC Launch](https://www.ycombinator.com/launches/SBV-tsenta-your-ai-career-agent-that-applies-to-jobs-lands-you-interviews)
- The connected inbox is used to "enter verification codes mid-application." — [tsenta.com](https://tsenta.com)
- Docs say Tsenta handles "supported account and verification steps", and that "a missing answer or verification step may need your attention." — [Docs: how applications work](https://docs.tsenta.com/product/how-auto-apply-works.md)
- Tsenta adds no Tsenta label to applications and "can't control what employers or their systems infer." It makes no promise that applications are undetectable. — [Docs: FAQ](https://docs.tsenta.com/product/faq.md); [tsenta.com](https://tsenta.com)
- Disclaimers: no guaranteed interviews, offers or sponsorship, and no fixed timing for when an application is submitted. — [tsenta.com](https://tsenta.com)

### Inferences
- For ATSs that require candidate accounts (Workday, iCIMS and similar), Tsenta likely creates accounts with the user's email and a generated password stored server-side, then completes email verification by reading the Gmail or Outlook inbox. This is inferred from the OTP and email-reading claims. How credentials are stored is not disclosed.
- CAPTCHA handling is undisclosed. Possible approaches are solver services or stealth browsers with residential proxies, or simply excluding CAPTCHA-heavy systems from the "supported" set. The move away from on-device automation suggests they found a workable cloud approach. This is speculation.
- "No fixed timing" suggests a queue with rate-limited workers per ATS or domain.

### Gaps
- CAPTCHA handling, proxy and IP strategy, credential storage, and the default Auto Apply cap and threshold values are not public.
