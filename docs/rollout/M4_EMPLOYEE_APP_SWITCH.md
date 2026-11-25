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

Bank account changes (`employee_portal.features.bank_requests`) stay locked (D3). The Milestone 5 and 6 switches stay locked.

A change takes effect today and is written to the operating profile from today forward, including any later scheduled versions. It doesn't wait for a pay period. Features need the employee app on. Turning the employee app off also turns its features off. The operating profile editor can't turn these switches on, but it keeps them on through other edits and can still turn them off.

Every change needs a reason and writes an `employee_app_switch#changed` audit row. A turn-on records the result of each check it was checked against, and the early-access window if one was used. Turning on, and setting early access, need a fresh second factor. Turning off and the demo kill switch never do.

## Readiness checks

Every turn-on needs every check below. Turning off always works.

| Check (as shown) | Passes when |
|---|---|
| This is a live client or a demo company | Active company in an active organization. It's a live client or a demo, not another test workspace. |
| Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim) | Payroll web and the employee service both have `REQUIRE_MFA=true` with `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF`, the same evidence `production:readiness` checks. |
| The employee service refuses any database read without a company (RLS guard in raise mode) | The employee service reports `RLS_CONTEXT_GUARD_MODE=raise` and connects as the restricted `payroll_app` role. |
| The database enforces company separation (row-level security on) | Every protected table has its policy, with ENABLE and FORCE row-level security. Payroll web reads this from the database itself. |
| Sign-in accepts only our own web addresses (CLERK_AUTHORIZED_PARTIES set) | Payroll web and the employee service both have production HTTPS origins in `CLERK_AUTHORIZED_PARTIES`. |
| The company's web address (subdomain) is set | The company has a valid `subdomain_slug`. |
| The employee service is running and healthy | The employee service answers `GET $EMPLOYEE_API_URL/health/dependencies` with `ok`, reported in the last 5 minutes, and its own `employee_web:` readiness lines pass. |
| Employee App Terms and Privacy Notice wording is approved by counsel | The current `employee_terms_versions` row is approved. A demo may use a draft. |
| Electronic delivery consent wording is approved by counsel | The current pay statement and W-2GU delivery disclosures are approved. A demo may use drafts. |

Counsel text isn't a merge blocker. These checks read the status of the loaded wording. See `docs/legal/COUNSEL_REVIEW_TRACKER.md`.

### How Payroll web sees the employee service

Payroll web can't read the employee service's process settings. When `/health/dependencies` runs on the employee service, the service records what it observes about itself in `employee_service_observations` (one row, at most every 30 seconds). The record holds the guard mode, whether the restricted database role was verified, MFA and authorized-party settings, dependency health, and its own `employee_web:` checks. The switch screen pings that endpoint first, so each check reads a fresh report.

**Set on Payroll web:** `EMPLOYEE_API_URL` = the employee service's base URL, for example `https://cornerstone-payroll-employee-api.onrender.com`. Without it the employee service check fails with "EMPLOYEE_API_URL isn't set on Payroll".

The screen shows the observed guard state and the database state side by side, as separate facts.

### Loading the Terms version

The sign-up screen still reads the Terms version from the employee build (`VITE_EMPLOYEE_TERMS_*`). The server copy exists so the switch can check counsel's status. Record each version, and keep it the same as the build:

```bash
VERSION=2026-12-01-draft STATUS=draft TERMS_URL=https://... PRIVACY_URL=https://... \
  bin/rails employee_terms:publish
```

Rows can't be edited or deleted. Counsel's approval is a new row with `STATUS=approved`.

## Demo early access before database enforcement

This is a named, server-side exception: **Demo early access before database enforcement**. Only an org admin can set it, and only with the owner's approval written in the reason. It records:

- the expiry date (from today up to 31 days ahead, counted in Guam business dates);
- one or two demo companies, named by ID; real companies are refused;
- who set it and when.

While it is in effect, a named demo company's database check shows **Waived** instead of failing. That holds only while the employee service reports its guard in raise mode with the restricted role. Every other check still applies. Real companies never get the exception. Rows can't be edited or deleted. They can only be ended once, and setting a new window ends the old one.

**After the expiry date**, the exception stops applying on its own. `CloseExpiredDemoEarlyAccessJob` runs every 15 minutes and does this while the database doesn't enforce RLS. Any demo company that no in-effect window covers has its employee app switches turned off, with an `employee_app_switch#demo_early_access_closed` audit row. Ending a window, or replacing it with one that drops a demo, closes that demo right away. Once the database enforces RLS, demos follow regular readiness and the job does nothing.

## Demo kill switch

**Stop demo employee access**, on a demo company's switch screen, needs a reason. In one action it:

- turns every demo company's employee app switches off, today and in later versions;
- ends the early-access window;
- revokes pending demo invitations (tickets);
- ends open support views (view-as grants) on demo companies;
- ends the Clerk sessions of employee-only demo logins;
- stops demo employee emails: `DemoOutbound` refuses every employee channel for a demo whose employee app is off, including queued and retried mail.

Demo data and the activity history stay. It writes one organization audit row and one row per demo company.
