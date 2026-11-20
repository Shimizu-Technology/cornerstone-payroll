# 1099 Pub 1220 implementation and lead handoff

## Scope and acceptance

Built on `origin/main` at `1e43ec3c` in the dedicated Mac mini checkout `/Users/agent/work/cornerstone-payroll-b`, branch `feature/1099-pub1220`. The other worker's checkout was not accessed.

Cornerstone staff prepare a client's 2026 1099-NECs for Guam DRT. The filing population and amounts come from `Form1099NecAggregator.reportable_contractors`; identity comes from company-scoped employees. The repository's November 17 year-end filing research (§1, §3, §9) and the worker brief establish the audience, jurisdiction and acceptance. The MacBook-only Brain Dump was unavailable on this host. No production data was accessed.

The generator produces one payer per file, refuses missing/invalid identities and amounts, and verifies the complete record stream before returning it. The PDF is a simple totals sheet, not an IRS overlay or paper filing substitute. It reads its count and dollars directly from the verified C record. The F record carries counts, not dollar totals.

## Specification and positions

Source: [IRS Publication 1220, For Tax Year 2025, Rev. 5-2026](https://www.irs.gov/pub/irs-pdf/p1220.pdf), Part C, printed pp. 48–57, 65, 70–81, 113–114, 139–140, 144–145. Downloaded to `/tmp/cp-p1220.pdf` for inspection; PDF not committed. Year fields deliberately carry 2026 under the requested DRT adaptation.

All positions below are one-based and inclusive. Unused fields remain spaces except the specified zero-filled monetary fields. Every record is 750 ASCII bytes. CR/LF occupies positions 749–750 **inside** those 750 bytes; no additional delimiter is appended.

| Record | Positions used |
| --- | --- |
| All | 1 record type; 500–507 ascending eight-digit sequence, starting at 1; 749–750 CR/LF |
| T | 2–5 year; 6 prior-year indicator blank; 7–15 transmitter EIN; 16–20 TCC; 28 test indicator (`T` draft, blank final); 29 foreign indicator blank; 30–69 transmitter name; 110–149 company name; 190–229 mailing address; 230–269 city; 270–271 state/territory; 272–280 ZIP; 296–303 B count; 304–343 contact; 344–358 phone; 359–408 email; 518 vendor indicator `I` (hired in-house programmer), vendor fields blank |
| A | 2–5 year; 6 CF/SF blank; 12–20 payer EIN; 21–24 name control blank (expressly allowed); 26–27 return type `NE`; 28–45 amount codes `14`; 52 foreign indicator blank; 53–92 payer name; 133 transfer agent `0`; 134–173 street; 174–213 city; 214–215 state; 216–224 ZIP; 225–239 phone |
| B | 2–5 year; 6 correction blank; 7–10 individual surname name control (business control blank when indeterminate); 11 TIN type `1` EIN / `2` SSN; 12–20 full TIN; 21–40 stable `C`-prefixed employee ID for matching corrections; 55–270 eighteen 12-digit amount fields, all zero-filled except 55–66 Box 1 and 91–102 Box 4; 287 foreign indicator blank; 288–327 first payee name; 328–367 second payee name (SSN business name or unused-line continuation); 368–407 street; 448–487 city; 488–489 state; 490–498 ZIP; 544 second TIN notice blank; 547 direct sales blank; 723–734 state withholding zero; 735–746 local withholding zero; 747–748 CF/SF blank |
| C | 2–9 B count; 16–339 eighteen 18-digit control totals; 16–33 Box 1 total; 70–87 Box 4 total; unused totals zero |
| F | 2–9 A count `00000001`; 10–30 zeros; 50–57 B count |

Domestic US/territory addresses, including GU, are supported. Foreign addresses, corrections, direct sales and second-TIN-notice workflows are outside this milestone. Name/address overflow is refused instead of truncating. SSNs use the app's filing-validity rule; business name controls remain blank because entity-specific rules cannot safely be inferred from a display name.

TCC is optional in settings and excluded from the SSA missing-fields list. T-record name/address punctuation is removed, with contact email case preserved as the spec permits. Drafts use the unmistakable `TEST0` placeholder when absent, because Pub 1220 requires the field, and set T28 to `T`. Finals require a TCC. The message directs staff to add the TCC from DRT and explains that drafts work without it. The test indicator's treatment by GuamTax remains unconfirmed.

## E1 integration seam

`api/app/services/form1099_readiness.rb`: `Form1099Readiness.final?(company:, year:)` deliberately returns false. Replace this adapter with E1's fingerprint-bound readiness check. Both the download controller and Print and file documents use it. Until wired, final requests return HTTP 409 `Mark the 1099s ready first`.

The generator only resolves employee-backed rows. Unresolved one-off checks produce a named TIN/address problem. When E1 merges, adapt the identity resolver to E1's resolved payee schema; do not join by display name. The aggregator gained `totals.reportable_federal_withheld` so the C total can be compared against the same reportable population rather than all contractors.

## Security and deployment

Both endpoints require `manage_client_administration`, block test workspaces, recheck access inside the company lock and after generation, verify a recorded Cornerstone filing decision and responsibility blockers, regenerate under an uncached read to detect changed inputs, then record an audit SHA-256 before sending. Responses use `no-store`; audit metadata has no TINs. A final readiness check is repeated after generation.

Deploy requires the additive `filing_submitters.tcc` migration and API/web release; frontend changes warrant a frontend build. No infrastructure, external service or credential changes. Hold this PR for Claude and CodeRabbit review; do not merge automatically.

## Operator questions

1. Which Pub 1220 edition does GuamTax validate for payment year 2026?
2. What are DRT's TCC issuance instructions? Final downloads currently require a TCC.
3. Must Guam payers file off-island payees with DRT?
4. Should Cornerstone record a sole proprietor using an EIN as an individual or business?

Do not treat local tests as DRT acceptance. A GuamTax test upload and Cornerstone review remain external acceptance work.

## Browser QA

Agent-executed affected-flow QA used actual React components in Chromium with a temporary fictional API harness, at 390px and 1440px. This validates component interactions and layout; it does not claim Clerk-authenticated end-to-end API acceptance. Backend behavior is covered by request specs. The harness was removed.

Passed: draft button disabled until checkbox confirmation; simulated changed-input error visible with retry; retry clears error; TCC field editing/save confirmation and warning removal; no horizontal overflow at either width. Phone Safari, WebKit, native keyboard behavior and GuamTax upload were not run (WebKit unsupported on this host).

Screenshots: `docs/evidence/pub1220/draft-390.png`, `error-390.png`, `submitter-1440.png`, `submitter-saved-390.png`. Impeccable advisory scan of changed UI returned `[]`.

## Cleanup and next action

Lifecycle session `manual-20261120-120658-93526-9f4d`: owned Vite PID 94061 terminated and preview tab closed/released. Shared PostgreSQL service remains borrowed. The task database `cp_test_pub1220` was dropped after gates; a catalog query confirmed zero matching databases. The branch and checkout remain for the lead's review/E1 integration; no runtime handoff is intended.

Next: review the final PR head, integrate E1's identity/readiness contract, retest combined flows, and obtain DRT confirmation/test-upload acceptance. Exact final gate results are recorded in the PR and worker return.

## Verification ledger

- Affected Rails run on final implementation: 58 examples, 0 failures, including migration rollback/reapply, generator golden/corruption/input checks, request security/races, settings and 1099-only checklist rows.
- Frontend: `npm run lint`, `npx tsc --noEmit -p tsconfig.app.json`, `npx tsc -b`, `npm test`: passed, 209 files / 2,082 tests.
- `bundle exec rubocop`: passed; exact final count in the PR.
- First `bundle exec rspec`: 7,648 examples, 2 failures, 4 pending. The TCC migration-sequence failure was fixed and retested. The other failure is `client_document_converter_process_spec.rb:51`: this host's RubyGems startup adds `PKG_CONFIG_PATH` inside a clean child environment. The same behavior reproduces with `env -i ... ruby -rjson -e 'puts ENV.keys.to_json'` outside Rails; `--disable-gems` removes it. No converter implementation or isolation assertion was weakened. Final full rerun: **7,654 examples, 1 failure, 4 pending** (10m54s). The only failure is the converter environment test above. The final T-record punctuation cleanup was then covered by the 58-example affected run; the full run predates that small formatting-only fix.
- Four transaction-pooler scenarios require external pooler URLs and are pending on this host.

Review round 1 changes and current verification are recorded in [pub1220-review-round1.md](qa/pub1220-review-round1.md); that ledger supersedes earlier gate/screenshot status above.
