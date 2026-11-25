# Employee app go-live runbook (M4-12)

**What this is:** the order of steps that takes the employee app from "merged and switched off" to the pilot client's whole staff using it. Each step has a gate check, an owner role, how to verify it and how to roll it back.
**Plan:** [Milestone 4 build plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) §3 (gates), §4 "M4-12" and §8 (milestone acceptance). The demo company replaces the earlier company 1 sign-ups ([demo company plan](../DEMO_COMPANY_PLAN_2026-11-25.md) §5).
**Test script:** [M4_ACCEPTANCE_SCRIPT.md](M4_ACCEPTANCE_SCRIPT.md). **Hand-out for employees:** [EMPLOYEE_APP_HOW_TO_SIGN_UP.md](EMPLOYEE_APP_HOW_TO_SIGN_UP.md).
**Related runbooks:** [two-step sign-in (G3)](MFA_ROLLOUT_RUNBOOK.md), [employee site and service (G5)](M4_EMPLOYEE_PLATFORM_RUNBOOK.md), [counsel review tracker (G1)](../legal/COUNSEL_REVIEW_TRACKER.md).

This repo is public. Don't write names, emails, phone numbers, sign-up codes, tokens or screenshots of real records into this file, a PR or a ticket. Record them in the access-controlled evidence location and refer to people by role.

---

## 0. Roles

| Role | Who, by role | Does |
|---|---|---|
| **Owner** | Shimizu Technology's owner | Gives the go for each step. Picks the counsel firm with the Cornerstone principal. Holds Clerk, Render and Netlify billing. |
| **Cornerstone principal** | The Cornerstone admin who signs off for the firm | Reviews the WISP, signs off G8a, uses view-only Sign in as. |
| **Cornerstone admin** | Staff with client administration access | Runs the rollout page, invites, unlocks and revokes, Help contacts, the switch screen. |
| **Cornerstone accountant** | Staff who run payroll | Runs payroll, prints checks, reviews stubs, confirms changes on payroll, posts W-2 copies. |
| **Reviewers** | Two Cornerstone staff named by the principal | Run the written acceptance script independently. |
| **Lead** | The engineering and rollout lead (a person or an agent working for the owner) | Runs readiness checks, deploys, Render shells, the security check, and keeps the go-live record. |
| **First pilot user** | The pilot client's day-to-day lead, who is also on its payroll | The first real user: a client portal admin and an employee on one login. |
| **Pilot managers** | The pilot client's two other admins (its owners), also on its payroll | Approve the first pilot user's own address request, then join wave 0. |
| **Client managers** | The first pilot user and the pilot managers | Enter contact details, send invites, answer employees' questions. |

## 1. Owner decision: counsel items block go-live, not merges

Work is never held for counsel. Code that carries legal wording is built, reviewed, merged and deployed **switched off**, with clearly marked draft wording. The demo company runs on that draft wording. Counsel's approved text must replace the draft before the switch is turned on for **real employees** of a real client.

So for every item in the [counsel review tracker](../legal/COUNSEL_REVIEW_TRACKER.md):

- it never blocks a pull request or a deploy;
- it never blocks the demo rehearsal (step 1) or the internal check (step 3), because no real employee is invited in either;
- the items marked "Real-employee go-live" block step 4 onward, unless a counsel-cleared pilot carve-out (tracker item 10) covers the first pilot user only;
- the items marked "Electronic-only" block only a later switch to electronic-only delivery. Paper stubs and paper W-2s continue for everyone in this milestone (plan D5).

## 2. Gate checks

All nine must be met before wave 1. The order in §3 says which ones each step needs.

| # | Gate | Owner | How to verify | Rollback |
|---|---|---|---|---|
| **G1** | **Counsel review:** tracker items 1, 5, 6, 7 and 8 are **Approved**, and item 4 is approved before any real employee's W-2 copy posts. Or, for the first pilot user only, item 10 (a carve-out counsel clears and the pilot client's owners and the first pilot user sign). | Owner and Cornerstone principal pick the firm. Lead prepares the packet and replaces the wording. | Each item's status is **Approved**, with the date and the PR that replaced the draft. The current server-published terms point at counsel's version, and the sign-up screen shows the **Employee App Terms** and **Privacy Notice** checkbox. Approved disclosures are new version rows, never edits (tracker). | Turn the employee app off for the company (switch screen, M4-9d). Counsel wording problems don't need a data rollback. |
| **G2** | **WISP:** Cornerstone's written security plan covers Payroll, plus the Shimizu Technology platform addendum with its incident response plan. | Lead drafts. Cornerstone principal reviews and adopts. | The adopted plan and addendum are in the private evidence location with the adoption date. The record names Cornerstone's Qualified Individual by role. | None. If the plan isn't adopted, stop before step 4. |
| **G3** | **Two-step sign-in on:** Clerk Pro, `REQUIRE_MFA=true` on Payroll web, worker and the employee API, after the M4-1 fix. | Owner, with one recovery admin | [MFA runbook](MFA_ROLLOUT_RUNBOOK.md) steps 1–9 done. `bundle exec rails production:readiness` shows PASS for `MFA enforcement has instance-bound evidence`, `Clerk Backend API accepts the configured key and matches MFA evidence` and `Clerk session token includes the MFA enrollment claim`, on Payroll web and on the employee service. | MFA runbook §3.4: set `REQUIRE_MFA=false` and redeploy. View-only Sign in as stops working at once, because it requires MFA. |
| **G4** | **Row-level security enforced** (M3-7 phase 3). The employee service runs with `RLS_CONTEXT_GUARD_MODE=raise`. | Lead | Readiness PASS for `RLS runtime role and kill switch privileges` and `RLS policy installation matches the selected phase`, with phase 3 selected. The critical demo cases pass again under enforcement (step 2). At least one normal payroll has run with enforcement on (plan §5). | Follow the M3-7 rollback. If enforcement is rolled back, turn the employee app off for every company first: G4 must hold while any real employee has access. |
| **G5** | **Employee site and API live:** Render employee service, Netlify site 2, the pilot client's employee address and the two demo addresses (`harborfinch` and `harborfinch-catering`), with Clerk allowed subdomains. | Lead | [Platform runbook](M4_EMPLOYEE_PLATFORM_RUNBOOK.md) §1.3 (all four `employee_web:` readiness lines PASS) and §3.5 smoke check, for each address, recorded with date and result. The demo addresses replace the runbook's company 1 team address (demo plan §5). | Platform runbook §6, in its order. |
| **G6** | **Client logins:** the first pilot user and the pilot managers have client portal logins on the pilot company, each enrolled in two-step sign-in. `PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true`. | Owner gives the go. Cornerstone admin invites. | Each signs in on desktop with the second step, sees the pilot company and its **Employees**, **Employee app**, **Contact Details** and **Change Requests** pages. A notice reaches each inbox. | Deactivate the client login under **User Management**. Their employee access (if any) is separate and is revoked from the employee record. |
| **G7** | **Contact details entered** for each wave. | Client managers (first pilot user's own record first) | On **Employee app → Employee app rollout**, the wave's employees are in **Ready to invite by email**, or have a printed code planned, and none of them is under **Missing contact details**. **Contact Details** shows no **Shared email** or **Not a real email** flag for them. | Edit the record. A wrong email can't let the wrong person in, because sign-up also checks date of birth and SSN last 4. |
| **G8** | **(a) Internal sign-off in two passes,** then **(b) the first pilot user's acceptance**. | (a) Reviewers run the script; Cornerstone principal signs off. (b) First pilot user, with the Cornerstone admin on call. | (a) Pass 1: the full [acceptance script](M4_ACCEPTANCE_SCRIPT.md) on the demo (step 1). Pass 2: the critical demo cases again under enforced RLS (step 2), plus the read-only check on the real pilot with zero invites (step 3). Both results and the sign-off are recorded. (b) The first pilot user's rows of the script pass (step 4). | A failed row stops the rollout at that step. Fix, redeploy, and rerun the failed rows plus anything the fix touched. |
| **G9** | **Security check** of the employee surface and Sign in as (M4-11). | Lead | The isolation suite passes in CI under RLS `raise` with real authentication. An adversarial review by a different model family is done and its findings are fixed or accepted in writing. An automated scan (OWASP ZAP baseline) of the production employee site and API is done before anyone is invited. Results are filed with the WISP evidence. | None needed: the gate stays open until the findings are closed. |

## 3. The steps, in order

Never start a step until the one before it is recorded as passed in the go-live record. Each step lists the gates it needs.

```text
Step 0  Preconditions (code deployed, demo seeded)
Step 1  Demo rehearsal with two-step sign-in on              G3, G5 (demo addresses)          = G8a pass 1
Step 2  Re-check under enforced RLS                          G4, G9                           = G8a pass 2, part 1
Step 3  Internal check on the real pilot, zero invites       G3, G4, G5, G6, G9               = G8a pass 2, part 2 → sign-off
Step 4  First pilot user (wave 0)                            + G2, G1 or carve-out, G7 (own)  = G8b
Step 5  Pilot managers (wave 0)                              + G1 for them, G7 (theirs)
Step 6  One full pay period with the three admins
Step 7  Wave 1: everyone else, or a group the client picks   all nine gates + G7
```

### Step 0. Preconditions

**Owner:** lead. **Go:** owner.

- [ ] Every M4 slice is merged and deployed with the M4 switches off: M4-1, M4-2, M4-3, M4-4, M4-5, M4-6, M4-7, M4-8, M4-9 (b, c and d), M4-10 and M4-11. Record each deployed commit. Merged isn't the same as deployed: check the Render and Netlify deploy pages.
- [ ] The switch screen (M4-9d) is deployed and shows the readiness list by name. Until it is, nothing can be turned on.
- [ ] The demo slices D1–D5 are deployed, and so are **D6** (lets the demo turn on its employee app and subdomains: today the employee portal and subdomain checks refuse every test workspace, `api/app/services/company_features.rb:104-107,151-154`) and **D7** (stub posting and the W-2 sample for the demo: today the stub posting job scans only live companies, `api/app/jobs/post_employee_pay_stubs_job.rb:13`). Without D6 and D7 only the staff and client half of the demo rehearsal can run.
- [ ] The demo companies are seeded (Render shell on Payroll web, private values from the operator configuration):
  ```bash
  ORGANIZATION_ID=… ACTOR_ID=… bundle exec rails demo:seed
  ORGANIZATION_ID=… ACTOR_ID=… MANAGER_EMAIL=… USER_EMAIL=… bundle exec rails demo:invite_clients
  ```
  ✅ `OK    demo:seed companies=…` and two `OK` lines from `demo:invite_clients` (it prints domains only). A rerun is safe: a finished seed is a no-op, and a delivered, still-open invite is left alone.
- [ ] For the QuickBooks original-stub cases, generate the sample files on the lead's machine and keep them in the private evidence location: `OUTPUT_DIR=… bundle exec rails demo:quickbooks_sample`.
- [ ] The persona mailbox aliases, passwords and backup codes are in the access-logged vault, with one reviewer assigned per script run (demo plan §3).
- [ ] View-only Sign in as is ready: `VIEW_AS_READY=true` on Payroll web and the employee service, and the Cornerstone principal's and owner's staff logins have the support-view permission. It works in production once the RLS guard is in `raise` and `CLERK_AUTHORIZED_PARTIES` is set (`ViewAsGrant.ready?` in `api/app/models/view_as_grant.rb`). It doesn't wait for two-step sign-in: while `REQUIRE_MFA` is off, starting a view asks for a fresh password or email code instead.

**Verify:** the go-live record lists the deployed commits and the seed output.
**Rollback:** nothing to roll back. A failed seed is rerun after the fix.

### Step 1. Demo rehearsal, with two-step sign-in on (G8a pass 1)

**Needs:** G3, and G5 for the two demo addresses. **Owner:** reviewers run it, the lead records it. **Go:** owner.

1. Turn on the demo companies on the switch screen (M4-9d): `employee_portal_enabled`, `subdomain_enabled`, and the `stubs`, `tax_forms`, `profile_requests` and `delivery_consent` features. `bank_requests` stays locked. The demo uses the draft wording (§1).
2. Rerun the platform runbook §3.5 smoke check on both demo addresses. Branding returns 200 for each, only for its own company.
3. Each reviewer runs the **whole** [acceptance script](M4_ACCEPTANCE_SCRIPT.md) on the demo, separately, on a phone and on a desktop. Agents can run the rows marked "agent OK".
4. After the run, check the boundary the demo must never cross (demo plan §0): no filing transmission, no email outside the allow-list, no AIRE or Cornerstone Tax activity, and the firm's client counts, KPIs, profitability and billing are the same as before the run.

**Verify:** every row is Pass, or Fail with an issue raised, or Pending with a reason (for example a slice not yet deployed). No Fail in sections A–C.
**Rollback:** turn the demo's switches off. Revoke any persona sessions that misbehaved from the employee record (**Revoke access**). Data and audit history stay.

The early-access window before RLS enforcement (demo plan §4) is an option for this step. It needs the owner's and lead's written approval with an expiry, and it can't count as enforced isolation evidence. If it's used, step 2 is mandatory.

### Step 2. Re-check under enforced RLS (G8a pass 2, part 1)

**Needs:** G4 and G9. **Owner:** lead and one reviewer. **Go:** owner.

1. Confirm the readiness RLS lines pass with phase 3 selected, and that the employee service runs with `RLS_CONTEXT_GUARD_MODE=raise`.
2. Rerun the critical demo rows. They're marked **[critical]** in the acceptance script: every negative test (wrong company, wrong person, view-only can't write, expired or replaced invite, lockout), a fresh email sign-up, a printed-code sign-up, a claim with an existing login, the two-employer picker, a stub and its PDF, a change with step-up, an address approval, former access, revoke ending the session, and Sign in as (client view on the demo).
3. Check the Render logs for the employee service during the run: no RLS guard errors, and no 5xx.

**Verify:** every critical row passes again. Record the date, the deployed commits and the readiness output (no tokens).
**Rollback:** as step 1. A guard error is a stop: switch the demo off and fix before going on.

### Step 3. Internal check on the real pilot: read-only Sign in as, zero invites (G8a pass 2, part 2)

**Needs:** G3, G4, G5 (pilot address), G6 and G9. **Owner:** Cornerstone principal and owner. **Go:** owner.

1. On the switch screen, turn on the pilot company's employee app: `employee_portal_enabled`, `subdomain_enabled`, `stubs`, `tax_forms`, `profile_requests`. Leave `delivery_consent` off until counsel's wording is loaded (G1). `bank_requests` stays locked.
2. **Send no invites.** On **Employee app → Employee app rollout** for the pilot company, **Invited** and **Active** are both 0. Check it again at the end of this step.
3. Rerun the smoke check on the pilot address. Branding returns 200 for the pilot company only.
4. The Cornerstone principal and the owner each use **Sign in as** (client settings menu → **Sign in as**), with a reason, on:
   - several employees: hourly, salaried, direct deposit and paper check, choosing **Employee app**. The real employee site opens with the "View only" banner;
   - the first pilot user's client portal view, choosing **Client portal** (after G6).
5. Compare each viewed stub with Cornerstone's printed copy for the same check: pay date, hours, each earning line, taxes, deductions, take-home pay and YTD. Open **Download PDF** and compare it too. Check the January–August **From QuickBooks records** rows against the imported history, and **View original stub (PDF)** where an original is posted.
6. Try one write in each view-only session (for example **Request a change** on **My info**). It must be refused.
7. Open **Support access** as the first pilot user's client login: each session started in 4 is listed.
8. The Cornerstone principal reviews steps 1–3 and signs off G8a.

**Verify:** stubs match the printed copies to the cent. Every Sign in as session is in the client's **Support access** list. **Invited** and **Active** are still 0.
**Rollback:** turn the pilot company's employee app off on the switch screen. Nobody outside Cornerstone ever had access, so nothing else changes.

### Step 4. First pilot user (wave 0, G8b)

**Needs:** step 3 signed off, **G2**, and **G1 or the signed carve-out** (tracker item 10), plus G7 for the first pilot user's own record. **Owner:** first pilot user runs it; Cornerstone admin supports. **Go:** owner and Cornerstone principal.

1. The first pilot user checks their own contact details on **Contact Details**. Their personal email is their client login email; confirming it's their own record is part of the invite (the checkbox "If this is my payroll sign-in email, I confirm this is my own employee record.").
2. From their employee record's **Employee app** panel, the first pilot user (or the Cornerstone admin) chooses **Invite** → **Email**. Because they already have a login, the invite points to signing in, not a new account.
3. The first pilot user claims their employee access on a phone: sign in, **Add your employee access**, code from the email link, date of birth and SSN last 4, then the fresh confirmation step.
4. They run their rows of the acceptance script, sections C and D, as both client manager and employee:
   - stubs, QuickBooks history, and the W-2 copy once posted;
   - a phone or email change with the code;
   - an address request, which a **pilot manager** or Cornerstone approves (they can't approve their own);
   - the rollout page, contact entry and Help contacts.
5. The Cornerstone accountant confirms each change on **Changes to confirm**.

**Verify:** every row the first pilot user ran passes, and the audit shows only their own records were read through their employee access.
**Rollback:** **Revoke access** on their employee record ends the employee access and its sessions (plan D12). Their client login stays. To stop everything, turn the pilot company off on the switch screen.

### Step 5. Pilot managers (wave 0)

**Needs:** step 4 passed, G1 (or a carve-out that names them too) and G7 for their records. **Owner:** pilot managers, with the first pilot user. **Go:** owner.

1. The first pilot user invites each pilot manager from their employee record (**Invite** → **Email**). Each claims their access with their existing client login, as in step 4.
2. Each pilot manager approves one address request from another admin, so each has used **Change Requests** → **Employee changes** at least once (milestone acceptance item 5).

**Verify:** both are **Active** on the rollout page. Each can see their own pay and nobody else's.
**Rollback:** as step 4, per person.

### Step 6. One full pay period with the three admins

**Needs:** step 5 passed. **Owner:** Cornerstone accountant, client managers. **Go:** owner.

1. Run the pilot company's next payroll as usual. Nothing in how pay is run changes.
2. At 6am Guam time on the pay date (or when a paper check gets its number), each admin's stub posts. Each opens it on their phone and compares it with the printed stub.
3. The Cornerstone accountant clears **Changes to confirm** before starting the run. The run warns about unconfirmed changes but isn't blocked.
4. Watch the alerts in the platform runbook §5 every day: employee 5xx, rate-limit hits and lockouts.

**Verify:** the three app stubs match the printed stubs. The audit shows no access to anyone else's records. No change in how pay was run.
**Rollback:** as step 4. If the stubs don't match, turn the company off and investigate before the next pay date.

### Step 7. Wave 1: everyone else, or a group the client picks

**Needs:** all nine gates and G7 for the wave. **Owner:** client managers send the invites; Cornerstone admin supports. **Go:** owner.

1. The client managers enter each employee's own email and mobile on **Contact Details**, using the **Needs contact details** filter. Shared inbox addresses are already cleared (M4-3).
2. On **Employee app rollout** → **Invite a group**, they choose up to 25 employees at a time, with **Email** for anyone who has a personal email and **Printed code** for anyone who doesn't.
3. For printed codes, print the sheets straight away (the codes are shown only once) and hand each sheet to the person it names, with the [how to sign up sheet](EMPLOYEE_APP_HOW_TO_SIGN_UP.md). Never hand codes out on a group table or post them.
4. Invite in groups small enough to support. One shift at a time is a good size, because everyone on the restaurant's Wi-Fi shares the backstop rate limits.
5. The Cornerstone admin checks the rollout page each day for **Locked sign-ups** and **Expiring or expired invites**.

**Verify:** milestone acceptance (plan §8): after one full pay period with wave 1, the audit shows no cross-employee access, pay ran the same way, and app stubs match the printed stubs.
**Rollback:** turn the company off on the switch screen (§4).

## 4. Rollback: switch off

The first and usual rollback is the switch.

1. On the switch screen (M4-9d), turn `employee_portal_enabled` off for the company, **and** in any scheduled future operating profile that would turn it back on.
2. Within about a minute (cached settings refresh) every employee API call for the company returns its usual 404, and the app shows **"The employee app isn't available right now"**. Nobody is told whether an account exists.
3. Links, logins, stubs, consents and audit history all stay. Turning the switch on again restores access without new invites.
4. Tell the client managers what happened and when to expect it back. Employees keep getting paper stubs as usual.

Deeper rollbacks, only if the switch isn't enough:

| Problem | Do |
|---|---|
| One person's access must end | Their employee record → **Employee app** → **Revoke access**, with a reason. It ends their sessions (plan D12). |
| Bad website or API deploy | Platform runbook §6 items 2–3 (publish the last good Netlify deploy; roll back the Render employee service). |
| The employee address must go dark | Platform runbook §6 item 1 (`subdomain_enabled` off), then item 4 only if the whole service must come down. |
| Two-step sign-in is locking people out | MFA runbook §3.4. |
| RLS enforcement is rolled back | Turn the employee app off for every company first (G4). |

## 5. Support

- **Employees ask their own managers first.** At the pilot client that's the client managers. The app's **Help** tab shows the contacts the client set under **Employee app settings → Help contacts**. Until they're set, it says "Ask your manager at {company}". There's no Cornerstone fallback on the employee screens.
- **Managers escalate to Cornerstone.** The Cornerstone admin handles locked sign-ups, revokes, sign-up resets and anything about pay amounts. Cornerstone escalates app faults to the lead.
- **Nobody asks for a password, a backup code or a full SSN.** Not by phone, not by text and not by email.

| The employee says | Who | What to do |
|---|---|---|
| "I didn't get the email." | Client manager | Check the email on **Contact Details**, then **Resend invite** on the employee record. The old email link stops working. Or give a **Printed code**. |
| "It says too many tries." | Client manager → Cornerstone admin | Sign-up pauses for 24 hours after 5 wrong tries. A Cornerstone admin can **Unlock sign-up** from the employee record after checking it's really the employee. |
| "My code doesn't work." | Client manager | The code may have been replaced by a resend, or be more than 14 days old. **Resend invite** and print a new sheet. |
| "I set up my account but it won't finish." | Cornerstone admin | **Reset sign-up** on the employee record, with a reason. The employee starts again. |
| "My new phone asks for a code." | Client manager | That's expected: on a new phone the app emails a code to check it's you. |
| "I'm a manager and it wants a second step." | Client manager → Cornerstone | Managers need two-step sign-in everywhere, including the employee app. MFA runbook §3 covers lost phones. |
| "My pay looks wrong." | Client manager → Cornerstone accountant | The app shows the same stub Cornerstone prints. Compare it with the printed stub. |
| "I left the company. Can I still see my stubs?" | Client manager | Yes, read-only, for 2 years after the termination date by default, and W-2s through October 15 of the next year. |
| "Someone else is using my account." | Cornerstone admin | **Revoke access** now, then issue a new invite after talking to the employee. |

## 6. Go-live record

Keep one record per company in the private evidence location. For each step: date, deployed commits, who ran it (by role), the script rows and their results, readiness output (no tokens), and who gave the go. The record for step 3 also carries the Cornerstone principal's G8a sign-off, and step 4 the first pilot user's acceptance.

## 7. Sources

- Gates and order: plan §3 and §5; the demo replaces company 1: demo plan §5.
- The rollout page, employee panel, printed codes and statuses: `web/src/pages/EmployeeAppRollout.tsx`, `web/src/components/employee-app/EmployeeAppPanel.tsx`, `web/src/components/employee-app/PrintedInvites.tsx`; 25 per group: `api/app/controllers/concerns/employee_app_rollout_actions.rb:8`.
- Sign in as: `web/src/support/StartSupportView.tsx`, `web/src/support/SupportAccessLogs.tsx`, `api/app/models/view_as_grant.rb`.
- Unavailable screen: `web/src/employee/StateScreens.tsx`. Help fallback: `web/src/employee/help.tsx`.
- Demo seed and invites: `api/lib/tasks/demo_seed.rake`, `api/app/services/demo_company/seed.rb`, `api/app/services/demo_company/invite_clients.rb`.
