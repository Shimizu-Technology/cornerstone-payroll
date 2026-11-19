# One product, three apps: the architecture decision

**Status:** Proposed. For Leon to decide, with questions for Dafne. No code has changed.
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
- **Recommendation:**
  - Make the Payroll codebase the one platform, organized as clear internal modules.
  - Build its time module by porting AIRE's time code, not from scratch and not as copies.
  - Move AIRE onto the platform once the module matches it. Until then, keep AIRE running exactly as it is.
  - Keep Cornerstone Tax as Cornerstone's practice app.
- **Cornerstone's profitability goal:** it doesn't need the full AIRE-style connection. A small cost feed from Payroll to Tax delivers it soon, alongside client fees and required client tagging. The full connection would duplicate the time module we plan to build anyway.
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

**Why not B:** it is the strongest alternative, and the August plan described it. It keeps the payroll engine separate from public employee traffic, and AIRE wouldn't have to move. It also keeps the connection layer, two copies of each person, two logins for managers and two codebases that both need strict client separation, permanently. C gets the same protection through separate login, API and website boundaries inside one platform (§4). Choose B over C only if Leon wants Workforce to be a product that can be sold without Payroll, to employers whose payroll someone else runs.

### Decision 2: where HR lives

**Recommendation:** HR lives in the platform, which is the Payroll codebase. Every plan already agrees that Payroll is the one HR engine.
- HR covers people records, leave, documents and policies, onboarding, credentials and the employee app.
- No new HR features go into AIRE's app. Anything built there would have to be rebuilt in the platform. AIRE's leave requests stay as they are until AIRE moves, then switch to the platform's leave.
- The employee app is a new front door into the platform:
  - its own login (a separate Clerk app for employees)
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

The profitability report lives in Tax, where clients and fees are.

Alongside T2, these small changes in Tax make the numbers trustworthy:
- Require a client on every entry, with an "Internal – Cornerstone" choice.
- Require a category and a task.
- Let one clock-in session be split across clients.
- Record each client's fee, with dates so changes are kept, or import fees from wherever Dafne bills.
- Show unassigned time in the report, so a gap never looks like profit.

Payroll already has a way to send totals to Tax. It has never been used, and as built it could send other companies' data. The cost feed has to be limited to company 1 and to managers.

## 3. How the pieces fit

```
                    ┌─────────────────────────── The platform (Payroll codebase) ────────────────────────────┐
 Employee app  ───► │  People & HR   Time & attendance   Leave   Documents   Pay engine   Year-end   Reports  │ ◄── Cornerstone staff console
 (per-client brand) │                         one record per person, per company                          │
 Manager portal ──► │  Settings per client turn modules on: payroll only · + portals · + time (workforce)  │
                    └───────────────▲──────────────────────────────────────────────────▲──────────────────────┘
                                    │ connector (until AIRE moves)                     │ cost feed (company 1 only)
                              AIRE time app                                      Cornerstone Tax
                         (unchanged; moves later)                       (practice app: clients, returns, fees,
                                                                        profitability; staff time until T3)
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

1. **A separate login for employees:** its own Clerk app, so an employee can never become a staff or client user. Today any verified email that matches gets matched or provisioned.
2. **Stronger company separation.** Separation is enforced in controllers today. Before employees arrive, add one of these:
   - a scoped query layer
   - Postgres row-level security
   - isolation tests that fail when a query isn't limited to a company
3. **MFA enforced** for staff and client users. It's configured but nothing checks it.
4. **Audit for actions with no staff user,** such as employees, kiosks and system jobs.
5. **Effective-dated pay.** Pay rates are overwritten in place today.
6. **Document scanning.** It's a placeholder that marks every file "not scanned".
7. **Rate limits and monitoring** on the employee API. The employee website can be deployed separately from the staff website while sharing the platform.

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

## 6. Order of work

| Step | What | Why here |
|---|---|---|
| 0 | Year-end W-2GU and 1099 (full build R0) | Legal deadline: February 1, 2027 |
| 1 | Cornerstone profitability: required client and "Internal", split sessions, fees, scoped cost feed, profitability report | Dafne wants it. It's small, independent of the platform, and every day of untagged time is lost |
| 2 | Foundations and the §4 safety gate (full build R1) | Every later module needs them |
| 3 | Employee app: pay, W-2s, profile, documents, policies (R2) | Cornerstone staff first, then MoSa's and KPI |
| 4 | Leave, onboarding and offboarding (R3–R4) | Sellable HR |
| 5 | Time module, ported from AIRE (R5) | First users are Cornerstone's own staff, since T3 makes Cornerstone the test client, then the next time client |
| 6 | AIRE moves onto the platform | When the module matches and AIRE agrees |
| 7 | Benefits, construction, report builder, year-end service (R6–R7) | Larger clients |

The timing estimate stays at nine to twelve months for the full scope.
- If a new client needs time tracking before step 5, a copy of AIRE's app (option A) is the stopgap. It moves at step 6 with AIRE.
- The time module could move ahead of leave and onboarding if a paying time client is waiting and the HR pilot isn't.

## 7. Questions

### For Leon
1. **Time:** approve option C (time as a module of the platform, ported from AIRE)? Or B, if Workforce should be sellable without Payroll?
2. **AIRE:** agree that AIRE's app gets fixes and requested changes only from now on, and moves when the module matches? Who at AIRE needs to agree, and when should we tell them?
3. **Cornerstone profitability:** approve T2 (cost feed) now instead of the full Tax connection?
4. **Employee app address and branding:**
   - one product name with a web address per client?
   - or only the client's branding?

   This is the spec's open "employee app domain" decision.
5. **Next time clients:** which clients want clock-in after AIRE, and when? That decides whether the time module or leave and onboarding comes first.
6. **Still open from the spec:**
   - MFA first
   - a separate employee login app
   - close PR #139
   - the text-message provider
   - bank changes through the portal first
   - contact changes approved with a one-time code

   Approving C makes the separate employee login required.

### For Dafne
7. How are Cornerstone's own staff paid today: hourly from logged hours, salaried, or a mix? That tells us how much it matters to pay staff from logged hours.
8. Where do her client fees live today: QuickBooks, invoices, or agreements? Monthly, per job, or both?
9. Should profitability include only staff cost (pay and employer taxes), or office overhead as well?
10. Should every time entry require a client, with an "Internal – Cornerstone" choice for firm work?

The commercial questions in the full build plan (§9: who owns, sells, supports and bills the product, and pricing) still need answers before the product is sold outside Cornerstone's current clients. They don't block anything above.
