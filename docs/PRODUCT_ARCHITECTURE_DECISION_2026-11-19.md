# One product, three apps: the architecture decision

**Status:** Decided by Leon on November 19, 2026. The decisions are in §0. Leon approved the milestone plan in §6 the same day. Dafne's open questions are in §7. No code has changed.
**Date:** November 19, 2026.
**Checked against code:**
- Payroll `origin/main` `3da73499`
- AIRE `origin/main` `7fe43c3e`
- Cornerstone Tax `origin/main` `e2724cd`

**Supersedes:**
- the time-architecture sections of the [platform offerings spec](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md) (W1–W2), the [employee portal plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md) and the [HR module plan](HR_MODULE_ADP_STUDY_AND_PLAN_2026-11-18.md)
- §4 of the [full build plan](WORKFORCE_PLATFORM_FULL_BUILD_PLAN_2026-11-18.md), which this document refines

Everything else in those documents stands.

Leon asked to step back before building anything major. The product now spans payroll, HR, time tracking, client and employee portals, and Cornerstone's own time and profitability. Some of it is built and some isn't. The question is what the whole product should look like, what the options are, and what is best for the long term.

## 0. Decisions (Leon, November 19, 2026)

Where a decision changes a recommendation further down, the decision wins.

| Area | Decision |
|---|---|
| **Shape of the product** | **One platform.** The Payroll codebase becomes the whole product. Time tracking becomes a module ported from AIRE's code, and HR lives in the platform (§2). |
| **AIRE** | AIRE keeps its app as it is, with fixes and changes AIRE asks for, and no new HR features. It moves onto the platform when the time module matches it. AIRE's look, logo, colors and workflows carry over through per-client settings. Its aviation marketing site stays a separate website. Leon tells AIRE himself, when he chooses. |
| **Logins** | **One login for everyone** (one Clerk app). This replaces the spec's separate employee login app. Accounts are by invitation only. A person's login is separate from their roles: Cornerstone staff, a client user for specific companies, an employee at one or more companies. Each area checks for its own role. MFA is required for staff and client users. Employees confirm sensitive changes with a one-time code. People with more than one role get a role switcher. |
| **Web addresses** | Client subdomains on shimizu-technology.com. `payroll.shimizu-technology.com` is for Cornerstone staff and client offices. `<client>.shimizu-technology.com` (for example `mosas.`, `aire.`) is for each client's employees, branded for that client. A client's own domain is an optional extra later. |
| **Separating companies' data** | Postgres row-level security on employee-facing and sensitive tables, behind the controller checks. Automated tests try to read across companies on every change. |
| **Phone app** | An installable web app first. Native iOS and Android apps come with the time module. |
| **Bank changes** | In the employee app. The employee confirms with a one-time code, and a fraud-alert email goes to the old address. Cornerstone approves the change in Payroll. A new account is never used for a payday that's already being processed. Direct deposit stays opt-in, with a check fallback (§8). |
| **Contact changes** | Phone, personal email and emergency contacts apply after a one-time code. Home address is sensitive and goes through approval. |
| **Per-client settings** | Built fresh from current main. Old PR #139 was closed. |
| **Cornerstone Tax** | **Joins in stages.** A shared login and a client list linked to Payroll's companies come during the foundations. Staff time tracking moves with the time module, which makes Cornerstone the first time client. Whether the practice side (returns, documents, tax portal) moves is decided after the platform is proven, probably 2028. |
| **Dafne's profit report** | **Lives in the platform** (this replaces the T2-in-Tax recommendation in §2). Tax sends hours by client, category, task and period to the platform. The platform adds each person's actual pay and employer taxes from Payroll, plus client fees, so pay data never leaves Payroll. Staff cost comes first. Overhead is a separate add-on column: a monthly amount Cornerstone enters, spread across clients by hours. Unallocated cost is shown and reconciles to payroll totals. Every Tax time entry requires a client, with an "Internal – Cornerstone" choice, plus a category and task. One clock session can be split across clients. All of Payroll's companies go into Tax's client list. |
| **Release acceptance** | Work goes live one milestone at a time, and each milestone is tested live before the next one goes live (§6). Inside a milestone, pieces merge as they're ready but stay switched off in client settings. Each milestone is tested by agents on staging, deployed to production switched off, run through a written acceptance script by Mark and Benjo, and signed off by Dafne. Then it's switched on for one pilot client for a full pay period, then for everyone. A problem in the pilot is handled by switching it off for that client. |
| **Employee app pilot** | **MoSa's first.** Emma leads day to day, and Sara and Mo (the owners) are admins too. Admin roles are configurable, with several per client. |
| **Name employees see** | The employer's name and logo, with a small "powered by" footer. |
| **Engineering calls** | <ul><li>Module boundaries in the codebase are enforced by automated checks.</li><li>Employee and kiosk traffic gets its own server processes and workers.</li><li>The text-message provider is chosen when notifications are built, by delivery and price to Guam numbers.</li><li>AIRE moves after a side-by-side pay period, with its history checksums kept and the old app read-only for a while.</li></ul> |
| **Deferred on purpose** | MoSa's start date (as soon as possible, done properly), languages, the business side (ownership, sales, pricing, revenue share, product name), the airport, and working directly with the bank on direct deposit. |

### Decisions (Leon, November 22, 2026)

These refine §0 and §6 for milestone 3. Where they differ from a recommendation elsewhere, these win.

| Area | Decision |
|---|---|
| **Clerk production setup** | Payroll still runs on a Clerk *development* instance in production (its live site uses a `pk_test_` key; Tax already uses a production instance). Milestone 3 moves Payroll to a Clerk *production* instance on the free plan, before any MoSa's employee logs in. Existing users are re-linked by a controlled one-time migration from a reviewed list of Payroll user records to their new Clerk user IDs, never by matching on an email address, verified or not. The one Clerk app for everyone (§0) stays. |
| **MFA timing** | MFA is built and tested in milestone 3 against the development instance, where it is free, and stays switched off in production (`REQUIRE_MFA=false`). It is switched on at the milestone 4 gate, before the first employee logs in, or once the platform earns revenue, whichever comes first. Clerk Pro (about $25 a month for the one app) is bought then, not before. Authenticator apps plus backup codes are the main method; text codes are optional. |
| **Text messages** | No text-message provider in milestone 3. Sign-in and MFA codes come from Clerk. A provider such as ClickSend is chosen only when text notices are built. |

## Summary

- **The product** is one service for Guam employers, run by Cornerstone. It covers payroll, people and HR records, time and attendance, leave, documents, onboarding, year-end forms and reporting. There are three front doors:
  - an employee app
  - a manager portal for each client
  - Cornerstone's staff console
- **The problem:** our own plans have changed direction three times on where time tracking and HR live:
  - **August 23:** separate products that share logins.
  - **November 17:** a separate copy of the time app for each client, with HR inside Payroll.
  - **November 18:** everything in one platform.

  Nothing from any of these plans has been built yet, so choosing now costs nothing to undo.
- **Decision** (§0):
  - Make the Payroll codebase the one platform, organized as clear internal modules.
  - Build its time module by porting AIRE's time code, not from scratch and not as copies.
  - Move AIRE onto the platform once the module matches it. Until then, keep AIRE running exactly as it is.
  - Keep Cornerstone Tax as Cornerstone's practice app.
- **Cornerstone's profitability goal:** it doesn't need the full AIRE-style connection. The profit report lives in the platform: Tax sends hours by client and task, and the platform adds actual pay cost and fees (§0). The full connection would duplicate the time module we plan to build anyway.
- **Order:**
  1. Year-end forms, due February 1.
  2. The profitability pieces, which run separately and are small.
  3. Platform foundations.
  4. The employee app.
  5. Leave and onboarding.
  6. The time module.
  7. AIRE's move.

## 1. What exists today

| | Payroll | AIRE | Cornerstone Tax |
|---|---|---|---|
| **Who uses it** | Cornerstone staff; client portal users (MoSa's, KPI) | AIRE's workers, managers and admin | Cornerstone staff; tax clients |
| **Size** | 184 models; about 119k lines of Ruby and 121k of TypeScript | 50 models; about 32k lines of Ruby and 75k of TypeScript | Practice app: returns, documents, clients, staff time |
| **Clients in one app** | Yes: organization → company → employee, enforced in controllers (no database-level isolation) | No: one employer, global settings, AIRE branding in code | One firm |
| **Stack** | Rails 8.1, React 19, Clerk, Render and Netlify | The same | The same (AIRE was split off from Tax in March and April) |
| **Time tracking** | None captured by employees; imports from time apps; paper timecards read by OCR | Built: clock, kiosk with PIN, breaks, one geofence, schedules, approvals, weekly overtime, categories | Built for staff (an older relative of AIRE's), with client, category, task and period since November 18 |
| **HR** | Employee records, effective-dated W-4 and work profile, change requests with approval, documents, client portal | Minimal: name, contact, department; leave requests without balances | None |
| **Employee login** | None | Yes: workers see My Pay, fetched live from Payroll | Staff only |
| **Connection** | Pulls AIRE's frozen pay-period batches; sends back status, the pay calendar and pay statements | The producer side: immutable batches, settlement records, actions taken from Payroll | Its old v1 summary feed exists; it has never sent a batch |

The connection between Payroll and AIRE is real and proven, but much of it exists only because the two are separate systems:
- frozen batches with checksums
- acknowledgements in both directions
- settlement records
- the "cockpit" calls that let Payroll staff act on AIRE's data
- about 100 Payroll files of connector code

Inside one system, most of that becomes ordinary database links and locks.

## 2. The three decisions

1. **Where does time tracking live?** That means clock-in, kiosk, schedules and approvals.
2. **Where does HR live?** That means people records, leave, documents, onboarding and the employee app.
3. **How does Cornerstone's own time connect,** and where does profitability come from?

### Decision 1: where time tracking lives

| | A. Separate apps, connected (today's model, extended) | B. AIRE's app becomes a shared Workforce product | C. One platform: time becomes a module of Payroll **(recommended)** |
|---|---|---|---|
| **What it means** | Each new time client gets its own copy of AIRE's code, server and database, connected to Payroll | Add client separation to AIRE's code. One deployment serves every client's time; Payroll stays separate | Port AIRE's time code into the Payroll codebase with company separation. One deployment serves everything |
| **Employee login** | One per time app, plus another for pay and HR | One for time and pay (pay fetched from Payroll) | One for everything |
| **Person records** | Copied and kept in step per app | Copied between two systems; Payroll can't create AIRE workers today, so that has to be built | One record |
| **Client managers** | Two or more apps | Two apps: Workforce for time and leave, Payroll's portal for payroll | One portal |
| **Adding a client** | A new deployment, database and monitoring | Settings and branding | Settings and branding |
| **Running cost** | Grows with every client | Two systems | One system |
| **Connection code** | Kept for every client | Kept forever, between the two products | Kept only for AIRE until it moves, and for any client that insists on its own time system |
| **Risk to payroll** | Low: payroll is isolated | Low | Higher, because employee traffic hits the same system. It needs the security work in §4 |
| **Work to get there** | Least now, most later | Large: 62 AIRE tables need client separation, plus a worker sync from Payroll | Large: port the time code into Payroll with company separation, then move AIRE's history |
| **AIRE** | Unchanged | Becomes the first client of the new product without moving its data | Keeps its app until the module matches it, then moves |

**Why C:**
- **The product is sold as one service.** Employees, managers and Cornerstone staff should log in once and see one record of each person. Keeping copies of people and hours in step between systems is extra work that adds nothing for the client.
- **The connection layer is expensive, and it's the part most likely to break.** A and B keep it forever. C keeps it only for AIRE's transition.
- **It's one stack and one team.** Leon and agents maintain everything. Every extra codebase adds its own deployments, security patches, tests and environments.
- **It costs no more than B.** B adds client separation to AIRE's 62 tables. C adds company separation to the time tables it ports, and Payroll's company model already exists. Both reuse AIRE's code.
- **What C loses:** AIRE keeps running on its own app longer, and its history has to move once. Both are manageable (§5).

**Why not A for the long term:** it's fine as a stopgap if a client needs time tracking before the module exists. A copy per client becomes unmanageable at ten clients.

**Why not B:** it is the strongest alternative, and the August plan described it. It keeps the payroll engine separate from public employee traffic, and AIRE wouldn't have to move. It also keeps the connection layer, two copies of each person, two logins for managers and two codebases that both need strict client separation, permanently. C keeps login, API and website boundaries separate inside one platform (§4), but it does not separate payroll's capacity from employee traffic the way B does. §4 item 7 covers that with reserved capacity for payroll. Choose B over C only if Leon wants Workforce to be a product that can be sold without Payroll, to employers whose payroll someone else runs.

### Decision 2: where HR lives

**Recommendation:** HR lives in the platform, which is the Payroll codebase. Every plan already agrees that Payroll is the one HR engine.
- HR covers people records, leave, documents and policies, onboarding, credentials and the employee app.
- No new HR features go into AIRE's app. Anything built there would have to be rebuilt in the platform. AIRE's leave requests stay as they are until AIRE moves, then switch to the platform's leave.
- The employee app is a new front door into the platform:
  - one login shared with staff and client users, with separate roles (§0; this replaces the separate Clerk app)
  - its own API area
  - client branding (logo, colors, a web address per client, the way AIRE's app looks like AIRE)
- AIRE's "My Pay" already shows the pattern: pay comes from Payroll and is never stored elsewhere.

### Decision 3: Cornerstone's own time and profitability

Dafne wants to see what each client and task costs her, to know where she makes or loses money. That needs four things:
1. hours by client and task, which Tax has had since November 18
2. what each associate actually cost
3. what she charges each client
4. a client on every entry

| | T1. Full AIRE-style connection from Tax | T2. Cost feed from Payroll to Tax **(recommended now)** | T3. Cornerstone staff use the platform's time module |
|---|---|---|---|
| **What it means** | Tax produces frozen pay-period batches like AIRE. Payroll imports them to pay staff and sends cost back | Payroll sends Tax each associate's actual pay and employer taxes per pay period. Tax spreads that cost across the hours each person logged, by client and task | Cornerstone is a client of the platform like any other. Staff clock in there, tagging Tax's clients |
| **Gives Dafne cost per client and task** | Yes | Yes | Yes |
| **Pays staff from logged hours** | Yes | No; staff pay is entered as it is today | Yes |
| **Size** | Large: Tax needs AIRE's whole producer side, about 3–6 weeks | Small to medium: a scoped feed plus a report, about 1–2 weeks | Part of the time module |
| **Long term** | Duplicates the time module, then gets thrown away | Stays useful as the cost source for Tax's report | The destination |

**Recommendation:** T2 now, then T3 once the time module exists.
- T1 means building AIRE's producer side a second time, in an app whose time tracking we plan to retire.
- For salaried staff, cost has to be spread across hours anyway, which is exactly what T2 does.
- Every dollar in the feed has to land somewhere. Cost for a period in which a person logged no hours (paid leave, a holiday, a missing timesheet) goes into an **unallocated** line for that person and period. Allocated cost plus unallocated cost must equal the feed's totals for each pay period, and the report shows the difference if they don't.

**Decided instead (§0):** the profitability report lives in the platform. Tax sends hours by client and task to the platform, and pay data never leaves Payroll. The T2 reasoning still holds for how cost is spread and reconciled.

These small changes in Tax make the numbers trustworthy:
- Require a client on every entry, with an "Internal – Cornerstone" choice.
- Require a category and a task.
- Let one clock-in session be split across clients.
- Record each client's fee, with dates so changes are kept, or import fees from wherever Dafne bills.
- Show unassigned time in the report, so a gap never looks like profit.

Under the §0 decision, pay data doesn't go to Tax. Tax sends hours by client, category, task and period to the platform, and the platform computes cost and profit. Payroll's existing, never-used feed of totals to Tax could send other companies' data as built. If it's ever kept, it must be limited to company 1 and to managers, and must not carry pay data.

## 3. How the pieces fit

```
                    ┌─────────────────────────── The platform (Payroll codebase) ────────────────────────────┐
 Employee app  ───► │  People & HR   Time & attendance   Leave   Documents   Pay engine   Year-end   Reports  │ ◄── Cornerstone staff console
 (per-client brand) │                         one record per person, per company                          │
 Manager portal ──► │  Settings per client turn modules on: payroll only · + portals · + time (workforce)  │
                    └───────────────▲──────────────────────────────────────────────────▲──────────────────────┘
                                    │ connector (until AIRE moves)                     │ hours by client, category, task, period
                              AIRE time app                                      Cornerstone Tax
                         (unchanged; moves later)                       (practice app: clients, returns, fees;
                                                                        staff time until it moves to the platform)

 Profitability lives in the platform: Tax's hours + Payroll's pay and employer taxes + client fees (pay never leaves Payroll).
```

Rules carried forward from the spec still hold:
- Offerings are per-client settings.
- Sensitive changes (bank, W-4, SSN, pay, address) are approved in Payroll.
- AIRE keeps working.
- Never add capabilities to AIRE's advertised list.

Added rules:
- **Time is a module, but it talks to pay through the same frozen hours record.** The ported time module produces the same pay-period hours snapshot the payroll importer already checks. The certified pay pipeline stays the same, and every commit keeps an exact record of the hours paid. That was the CEO's November 2 ask.
- **Modules own their tables.** Time, HR and pay each get their own namespace and tables, and talk through defined services, not by reaching into each other's records. This keeps one codebase from becoming one tangle.
- **The marketing site isn't part of the product.** AIRE's aviation pages stay on their own site when AIRE's workforce part moves.

## 4. What C needs to be safe

Today Payroll serves only Cornerstone staff and client offices. Employee logins mean many more users, on phones, on the open internet. Before the first employee logs in:

1. **Safe login for employees (§0: one login).** Invitation-only accounts, login separate from roles, and each area checking for its own role, so an employee can never reach staff or client areas. Today any verified email that matches gets matched or provisioned, and that has to end first.
2. **Stronger company separation (§0: database-level).** Separation is enforced in controllers today. Add Postgres row-level security on employee-facing and sensitive tables, plus isolation tests that fail when a query isn't limited to a company.
3. **MFA enforced** for staff and client users. It's configured but nothing checks it.
4. **Audit for actions with no staff user,** such as employees, kiosks and system jobs.
5. **Effective-dated pay.** Pay rates are overwritten in place today.
6. **Document scanning.** It's a placeholder that marks every file "not scanned". *Leon, November 22, 2026: not a gate for the pilot. Pilot uploads use the existing file-type and size checks without malware scanning, trusting the pilot companies; scanning must be added before wider rollout beyond the pilot clients.*
7. **Capacity kept for payroll.**
   - Rate limits and monitoring on the employee API.
   - Separate web processes and background workers for employee and kiosk traffic, with their own database connection limits, so a rush of clock-ins can't slow a payroll run.
   - The employee website deployed separately from the staff website.

   If that isn't enough at scale, the employee API can move to its own deployment of the same codebase.

These are mostly the full build plan's R1 foundations. This section makes them a hard gate.

## 5. AIRE's path

1. **Now:** AIRE keeps its app exactly as it is. It gets fixes and changes AIRE asks for. No new HR features.
2. **While the time module is built:** port AIRE's time code (clock, kiosk, breaks, geofence, schedules, approvals, overtime, categories) and its staff screens. AIRE is the reference implementation, and the module has to match what AIRE staff use every day, including:
   - the kiosk with PIN and admin unlock
   - instructor "Log time"
   - the cutoff workflow
   - departments as approval groups
3. **Move when the module matches and AIRE agrees:**
   - Run both side by side for one pay period and compare.
   - Bring AIRE's history across with checksums kept.
   - Switch AIRE's company from the external connection to the internal module.
   - Keep the old app read-only for a while.
4. **After the move:** the connector stays for any future client that keeps its own time system. It's built and documented, so it costs little to keep.

Any big AIRE feature built before the port gets ported along with it. Anything built after the port starts has to be built twice, so large new AIRE features should wait or be built in the platform.

## 6. Milestones (approved by Leon, November 19, 2026)

Eight milestones. Each one goes live and is tested live before the next one goes live.

### How every milestone goes live

Pieces of a milestone merge to `main` as they're ready. New features stay switched off in client settings until the whole milestone is done, so clients never see half-built work. Then:

1. Agents test it on staging.
2. It's deployed to production, still switched off.
3. Mark and Benjo work through a written acceptance script.
4. Dafne signs off.
5. It's switched on for one pilot client for a full pay period.
6. It's switched on for everyone.

If something goes wrong in step 5, it's switched off for that client. Nobody else is affected. Switching a feature off never hides or deletes records it created: filing records, acknowledgements and audit history stay visible to staff.

### The milestones

| # | Milestone | What's built | Live test | Waits on |
|---|---|---|---|---|
| 1 | **Year-end forms** (now to mid-January; legal deadline) | W-2GUs and 1099s from payroll data, the SSA (EFW2) file, employee copies, and a record of what was filed and when it was confirmed. The step-by-step build is §8 of the [year-end research](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md): number fixes and 941/W-1 reconciliation first, then official copies, then the EFW2 file, then 1099s, then the filing record. | One or two clients: totals checked against their payroll and 941s, Dafne reviews, then filing with DRT by January 29. ezW2 stays available as the fallback. | Dafne's answers on BSO access, last year's ezW2 file and the GuamTax filing method (§7). These affect only the filing steps; the number fixes and reconciliation can start now. |
| 2 | **Cost and profit per client for Cornerstone** | Every Tax time entry requires a client (with "Internal – Cornerstone"), one clock session can be split across clients, all Payroll companies join Tax's client list, Tax sends hours to the platform, and the platform adds real pay, employer taxes and fees to show cost and profit by client and task (§0). | Cornerstone staff log a full month; the report's cost matches the payroll totals. | Dafne's answer on how she bills fees. |
| 3 | **Foundations** (mostly invisible) | The §4 safety gate: one invitation-only login, with MFA for staff and client users built and tested on Clerk dev and switched on only at the milestone 4 gate or once the platform earns revenue, whichever comes first, row-level security with cross-company tests, client subdomains, pay-rate history, audit for employee and system actions, separate capacity plumbing for employee traffic, and Payroll's move to a Clerk production instance (free plan) before milestone 4. *(File scanning is deferred past the pilot; lawyer review and WISP stay a milestone 4 go-live prerequisite.)* | Cornerstone and the client offices run a normal payroll on it and nothing breaks. | Nothing. |
| 4 | **Employee app, MoSa's first** | Pay stubs, W-2s, profile and contact changes, and bank changes (opt-in, one-time code, Cornerstone approves; off for MoSa's, which keeps no bank details in Payroll). Documents and policy sign-offs moved to milestone 5 (Leon, November 24, 2026). Build plan: [Milestone 4 build plan](MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md). | Leon, Dafne, Mark and Benjo check it in production with a view-only "Sign in as" (no staging for this milestone); Emma is the first real user; then MoSa's employees use it for one pay period, with Emma, Sara and Mo as admins. | The lawyer review and the written security plan (WISP) must be finished before it goes live. |
| 5 | **Leave and onboarding** | PTO and sick balances and requests, new-hire paperwork (W-4, I-9, policies), documents and policy sign-offs, and offboarding. | MoSa's, then KPI. | Milestone 4 live. |
| 6 | **Time module, ported from AIRE** | Clock in and out, kiosk, breaks, schedules, approvals and overtime, inside the platform (§5). | Cornerstone's own staff first, then the next client that needs time tracking. | Milestone 3. |
| 7 | **AIRE moves onto the platform** | A side-by-side pay period, AIRE's history brought over with checksums, and the old app kept read-only for a while (§5). | The side-by-side pay period matches. | The module matching AIRE, and Leon talking to AIRE. |
| 8 | **Bigger-client features** | Benefits, construction pay, a report builder and year-end filing as a service. | Per feature. | Earlier milestones. |

The full scope is still about nine to twelve months. Dates for milestones 2 onward are set once Dafne answers §7.

- **Year-end fallback, per client:** the filing record is the source of truth, and it stays available even if year-end is switched off for that client. Before ezW2 is used for a client, staff reconcile every DRT and SSA submission and acknowledgement for that client against its filing record. A client whose forms were already submitted or accepted is never filed again through ezW2; any fix goes through a correction (W-2c) instead. ezW2 is only for clients with nothing submitted, and each fallback filing is recorded the same way, so every client is filed exactly once.
- If a new client needs time tracking before milestone 6, a copy of AIRE's app is the stopgap. It moves at milestone 7 with AIRE.
- The time module could move ahead of leave and onboarding if a paying time client is waiting and the HR pilot isn't.

**Overlap (Leon, November 19):** milestone 2 is built while Dafne tests milestone 1, since they touch different code (year-end is in Payroll; most of the profit work is in Tax). The go-live rule still holds: milestone 2 doesn't go live until milestone 1 passes.

## 7. Questions

Leon's questions from the first version of this document are all answered in §0.

### For Dafne (email drafted November 19; Leon reviews it before sending)
1. **Year-end:** does her SSA Business Services Online account cover every employer? Can she send one of last year's ezW2 upload files? Should Cornerstone keep filing through each client's GuamTax account with clients signing their own 941s, or register as a GuamTax payroll processor and possibly as an IRS reporting agent (Form 8655)?
2. **Fees:** does she bill every client through Payroll's invoices, or are some billed in QuickBooks? Monthly, per job, or both?
3. **Security plan:** was the written information security plan (WISP) finished after the March 2026 training?
4. **MoSa's:** PTO or sick policy and who approves, which policies employees acknowledge, health or food-handler permits, where schedules are made, and whether most employees have a smartphone and personal email.
5. **KPI:** Nan's and Dee's access and notifications.
6. **For DRT, through her contacts:** the questions in [the legal research](GUAM_PAYROLL_HR_LEGAL_COMPLIANCE_RESEARCH_2026-11-19.md), Part 4.

### Answered without asking her
- How Cornerstone's staff are paid: from Payroll, company 1.
- Which clients go in the time list: all of them.
- Tips: per pay period.
- Benefits: from the deductions set up in Payroll.
- W-9s for MoSa's payees: already requested in her November 17 email.
- Direct deposit today: Cornerstone gives MoSa's the stubs, and MoSa's pays through its own ACH agreement with its bank.
- GuamTax today: each client has its own account, and Cornerstone signs in for them.

## 8. Legal research

[GUAM_PAYROLL_HR_LEGAL_COMPLIANCE_RESEARCH_2026-11-19.md](GUAM_PAYROLL_HR_LEGAL_COMPLIANCE_RESEARCH_2026-11-19.md) is a sourced research brief for a later law-firm review. It is not legal advice. Its Part 1 is the list of build requirements. The findings that change this plan:

- **Wages are "cash or check"** (22 GCA § 3212(b)). Direct deposit stays opt-in, with a signed authorization and a check fallback, until Guam DOL or the law firm confirms.
- **Guam has no tip credit.** Payroll needs a below-minimum-wage warning, and service charges need correct handling.
- **Meal and split-shift rules** go into the time module: flag violations and store waivers.
- **Pay deadlines:** wages are due within 7 days of the period end, and a discharged employee is paid immediately. Withheld amounts owed to others (child support, 401(k), loans) are due within 5 days after the day the employee's pay is due (22 GCA § 3217(b); to confirm in legal review).
- **Guam leave laws** go into the leave module.
- **Records are kept 6 years** by default.
- **Year-end:** GuamTax rules, and tracking each SSA submission's confirmation number. In 2025, SSA flagged 2024 W-2s that were created but never submitted.
- **Text messages:** the new opt-out rules take effect November 25, 2026.
- **Security:** a WISP, the FTC Safeguards Rule and a breach plan. The platform never stores client bank or EFTPS passwords.
- **H-2B and Davis-Bacon** wait for the construction release.
