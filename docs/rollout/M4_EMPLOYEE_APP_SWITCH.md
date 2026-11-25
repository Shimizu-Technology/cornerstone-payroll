# Employee app switch (M4-9d)

The Employee app switch lifts the Milestone 4 lock for one company at a time. It is the last item of M4-9 in `docs/MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md` §4, plus the demo early-access rule in `docs/DEMO_COMPANY_PLAN_2026-11-25.md` §4.

**Where:** Settings → Employee app switch, with a client selected (`/companies/:id/employee-app/switch`). Only organization admins (and platform admins) see it (`manage_employee_app_switch`).

## What it switches

| Switch | Profile key | Extra check |
|---|---|---|
| Employee app | `employee_portal_enabled` | Employee App Terms wording |
| Company web address | `subdomain_enabled` | |
| Pay stubs | `employee_portal.features.stubs` | |
| Tax forms | `employee_portal.features.tax_forms` | |
| Contact and address updates | `employee_portal.features.profile_requests` | |
| Electronic delivery consent | `employee_portal.features.delivery_consent` | Consent wording (pay statements and W-2GU) |

Bank account changes (`employee_portal.features.bank_requests`) stay locked (D3). The Milestone 5 and 6 switches stay locked. `ClientOperatingProfile` refuses any save that turns one of them on, and `CompanyFeatures` reads them as off whatever a row says. A legacy row stored with one on can still have its dates closed or be sanitized, so turning the employee app off never fails on it. The switch writes every locked switch off on each row it touches.

**A profile flag alone opens nothing.** Each turn-on writes an `employee_app_activations` row (company, part, who, when, the checks it passed, and the early-access window if one was used). `CompanyFeatures` counts a part on only while its profile flag is on **and** an unrevoked activation for that part exists. A direct profile write, a copied row, or a future-dated version with the flags on opens nothing. Only the switch writes activations. Flags turned on before this switch existed have no activation, so they now read as off; that is intended, since nothing was turned on through the switch before. The runtime database role can insert activation rows, because it is the same role the app uses; the switch service is the only code that does. Every turn-off revokes them (the switch, the demo expiry sweep and the demo kill switch). Rows can't be edited, except to revoke them once, and can't be deleted.

A change takes effect today and is written to the operating profile from today forward, including any later scheduled versions. Turning off clears the part (and, for the employee app, every feature under it) today and in every later version, even a part that is on only in a later version. It doesn't wait for a pay period. Features need the employee app on. Turning the employee app off also turns its features off. The operating profile editor can't turn these switches on, but it keeps them on through other edits and can still turn them off.

Every change needs a reason and writes an `employee_app_switch#changed` audit row. A turn-on records the result of each check it was checked against, and the early-access window if one was used. Turning on, and setting early access, need a fresh step-up (`MfaPolicy.recently_step_up_verified?`): a second factor with `REQUIRE_MFA=true`, or a fresh first factor (password or email code, through Clerk reverification) while it's off. The switch service (`EmployeeAppSwitch::Update`) requires it itself: every caller passes the actor's verified session claims, and the service refuses to turn anything on without a step-up within the window. It also always builds its own readiness checks; a caller can't pass them in. Turning off and the demo kill switch never need a step-up.

## Readiness checks

Every turn-on needs every check below. Turning off always works.

| Check (as shown) | Passes when |
|---|---|
| This is a live client or a demo company | Active company in an active organization. It's a live client or a demo, not another test workspace. |
| Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim) | Payroll web and the employee service both have `REQUIRE_MFA=true` with `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF`, the same evidence `production:readiness` checks. **While Payroll's `REQUIRE_MFA` is off** (until Clerk Pro), it shows **Not required yet** (status `waived`) for every company, demo and live, and doesn't block. Turn MFA on before real employees use the app ([MFA_ROLLOUT_RUNBOOK.md](MFA_ROLLOUT_RUNBOOK.md)). |
| The employee service refuses any database read without a company (RLS guard in raise mode) | The employee service's signed answer says `RLS_CONTEXT_GUARD_MODE=raise`, it connects as the restricted `payroll_app` role, and it sees the RLS kill switch off. |
| The database enforces company separation (row-level security on) | Every protected table has its policy, with ENABLE and FORCE row-level security, **and** `rls_admin.rls_kill_switch.bypass_enabled` is `false`. Payroll web reads both from the database itself. A kill switch that is bypassing, or can't be read, fails the check. |
| Sign-in accepts only our own web addresses (CLERK_AUTHORIZED_PARTIES set) | Payroll web and the employee service both have production HTTPS origins in `CLERK_AUTHORIZED_PARTIES`. |
| The company's web address (subdomain) is set | The company has a valid `subdomain_slug`. |
| The employee service is running and healthy | The employee service answers `GET $EMPLOYEE_API_URL/health/dependencies` with `ok` and a valid signed answer, and its own `employee_web:` readiness lines pass. |
| Employee App Terms and Privacy Notice wording is approved by counsel | The current `employee_terms_versions` row is approved. A demo may use a draft. |
| Electronic delivery consent wording is approved by counsel | The current pay statement and W-2GU delivery disclosures are approved. A demo may use drafts. |

Counsel text isn't a merge blocker. These checks read the status of the loaded wording. See `docs/legal/COUNSEL_REVIEW_TRACKER.md`.

### How Payroll web sees the employee service

Payroll web can't read the employee service's process settings, so each readiness check asks the employee service directly. Payroll sends `GET $EMPLOYEE_API_URL/health/dependencies` with a fresh random nonce and an HMAC of it. The employee service, and only its `employee_web` process, answers with a signed statement about itself: guard mode, whether the restricted database role is verified, the kill switch as it sees it, MFA and authorized-party settings, dependency health, its own `employee_web:` checks, and its deploy revision (`RENDER_GIT_COMMIT`). The signature is an HMAC-SHA256 with a shared secret. Payroll rejects an answer that isn't signed, has the wrong signature or nonce, is more than 60 seconds old, or comes from another process. Callers without the secret get only `{"status": ...}`. Nothing is stored: the checks read this live answer.

**Set on both Payroll web and the employee service:** `EMPLOYEE_SERVICE_ATTESTATION_SECRET`, the same random value of at least 32 characters (for example `openssl rand -hex 32`). Without it the guard, MFA, authorized-party and employee service checks fail.

**Set on Payroll web:** `EMPLOYEE_API_URL` = the employee service's base URL, for example `https://cornerstone-payroll-employee-api.onrender.com`. It is read from configuration only, must be HTTPS in production, and redirects are never followed. Without it the employee service check fails with "EMPLOYEE_API_URL isn't set on Payroll".

The screen shows the observed guard state and the database state side by side, as separate facts.

### Loading the Terms version

Sign-up and claim use the current server-published Terms. Publish each immutable version with the exact served Terms file so the API can return its SHA-256 digest.

The employee site's Netlify rules serve the versioned HTML directly at `/terms` and `/privacy`. Publish root-relative versioned URLs so every client subdomain resolves them on its own employee host and recorded versions keep pointing to the same bytes after the friendly routes change. These paths pass `safeDocumentUrl`. After deploying the employee site, verify that the SHA-256 of the versioned Terms response matches the checked-in Terms HTML. From `api/` in the matching checkout, publish the draft:

```bash
VERSION=2026-12-01-draft STATUS=draft TERMS_URL=/legal/employee-terms-2026-12-01-draft.html \
  PRIVACY_URL=/legal/employee-privacy-2026-12-01-draft.html \
  TERMS_FILE=../web/deploy/employee/legal/employee-terms-2026-12-01-draft.html \
  bin/rails employee_terms:publish
```

Rows can't be edited or deleted. For counsel's approved release, add new versioned HTML files, set their version and effective date, set `data-status="approved"` on each document, and point the employee redirects at the new files. Keep the draft files at their original locations for audit. Deploy the approved pages before publishing a new row with `STATUS=approved` and the matching approved Terms file. Counsel must review both documents before any real employee is invited.

## Demo early access before database enforcement

This is a named, server-side exception: **Demo early access before database enforcement**. Only the owner (a `super_admin`) can set it or extend it. It records:

- the expiry date (from today up to 30 days ahead, counted in Guam business dates);
- one or two demo companies, named by ID; real companies are refused;
- the approver (the super admin who set it), the reason, and when.

An extension is a new window: it needs a new super admin approval and its own reason, and it ends the old window. Any switch admin can end a window early.

While it is in effect, a named demo company's database check shows **Waived** instead of failing. The waiver accepts only the intended shadow state: every policy installed, no table enforced yet, and the kill switch known to be off. It also needs the employee service's signed answer to show its guard in raise mode with the restricted role. Every other check still applies. Real companies never get the exception. Rows can't be edited or deleted. They can only be ended or retired once.

**At request time**, a demo company's employee app is open only while the database enforcement is verified, or while the database is in the intended shadow state and an in-effect window names that exact company (Guam date). Expiry takes effect at once. Under the waiver, the process reading it must also run the RLS guard in raise mode as the restricted role, with the kill switch known to be off (a missing kill switch row counts as unknown, which fails). `CompanyFeatures` applies this whole gate, so web requests, jobs and mail all see a demo's app as off on any process that fails it, and employee jobs do nothing for it. A failing request gets a plain 404. A demo link's activation, claim, bind and every data request must come from that demo company's own subdomain: the session's authorized party must be the demo's subdomain, and a browser `Origin` must match it. A demo link outside its gate is neither listed (`/employee/links`) nor counted (`/auth/me`).

**After the expiry date**, `CloseExpiredDemoEarlyAccessJob` (every 15 minutes) reconciles the stored switches. Any demo company that no in-effect window covers has its switches turned off and its activations revoked, with an `employee_app_switch#demo_early_access_closed` audit row. Ending a window, or replacing it with one that drops a demo, does this right away.

**Once the database enforces RLS**, every open window retires for good (`retired_at`, and an `employee_app_early_access#retired` audit row from the sweep). A later return to shadow mode doesn't bring it back. New windows can't be set while the database enforces RLS.

## Demo kill switch

**Stop demo employee access**, on a demo company's switch screen, needs a reason. In one action it:

- turns every demo company's employee app switches off, today and in later versions, and revokes their activations;
- ends the early-access window;
- revokes pending demo invitations (tickets) and their Clerk sign-up invitations;
- ends open support views (view-as grants) on demo companies;
- ends the Clerk sessions of employee-only demo logins;
- stops demo employee emails: `DemoOutbound` refuses every employee channel for a demo whose employee app is off, and the mail transport checks again right before each send, so queued and retried mail stops too. Employee portal notifications use the employee channel at both points.

Each demo company is stopped under its row lock. Issuing an invitation (invite, resend, or the Clerk sign-up invitation) takes the same lock and checks again that the app is on, so nothing is issued halfway through a stop.

Clerk revocations are recorded in `employee_app_clerk_revocations` and retried by `RevokeEmployeeAppClerkJob` until Clerk confirms. The stop's audit rows list what it did in the database (`confirmed`) separately from what it asked Clerk to do (`requested`). Each confirmation writes its own `employee_app_switch#clerk_revocation_confirmed` row, and running out of retries writes `employee_app_switch#clerk_revocation_failed`.

An invitation someone already accepted can't be revoked, so it never counts as confirmed by itself. The job ends the sessions of the account the person created (the login's bound Clerk user, or the one Clerk user with the invited address) and confirms only once they are ended. If no single account is found, the row ends as needing follow-up (`follow_up_at`, `outcome`) with an `employee_app_switch#clerk_revocation_needs_follow_up` audit row. Check those rows by hand.

Each row records when its job was claimed (`enqueued_at`) and when that job actually reached the queue (`submitted_at`). A repeat stop finds the requests still pending, doesn't duplicate them, and queues any that never got a job. `RetryEmployeeAppClerkRevocationsJob` (every 15 minutes) re-enqueues pending rows that were never queued five minutes after their request, whose claim was never confirmed as queued after five minutes (the process died between the claim and the enqueue), or that were untouched for six hours (longer than the job's slowest retry wait). A crash or failed enqueue after a stop commits therefore doesn't strand them.

Each attempt holds a 15-minute lease with its own token (`lease_token`). The attempt records an outcome and releases the lease only under that token, so a run that outlived its lease and lost it to a newer attempt writes nothing. A pass also stops calling Clerk after 10 minutes and is rescheduled a minute later to carry on. Those reschedules have their own retry count, separate from failed attempts.

Demo data and the activity history stay. It writes one organization audit row and one row per demo company.
