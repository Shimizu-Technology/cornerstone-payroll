# Two-step sign-in rollout runbook (gate G3)

**Who does this:** the owner (Clerk, Render and Netlify logins) with one recovery admin as the second pair of eyes.
**When:** after Clerk Pro is bought (owner decision, Nov 25, 2026: not yet; MFA stays off for the next few weeks). Pick a weekend, not a payroll cutoff day, and not while anyone is mid-entry on a pay period.
**What it does:** turns on `REQUIRE_MFA=true` so **every** user must sign in with a second factor (authenticator app or backup code): Cornerstone staff, client users and employees. This reverses the earlier decision (D9) that employee-only users were exempt.
**Gate:** G3 in [the M4 build plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md). Clerk Pro is bought at this gate.
**Cost:** Clerk Pro $25/month, or $20/month billed annually ([Clerk pricing](https://clerk.com/pricing), checked 2026-11-25).

This repo is public. Do not write names, emails, tokens, instance secrets or backup codes into this file, a PR, a ticket or a chat. Record them in the access-controlled evidence location and refer to them by role.

**Turning it on is configuration only:** Clerk dashboard settings (Steps 1–3), then `REQUIRE_MFA=true` with the two evidence variables on every API service (Step 6). No code change or deploy of new code.

---

## 0. What the system does

### 0.1 While `REQUIRE_MFA` is off (MFA-ready mode, today)

Clerk's free plan has no second factor, so nobody can have one. Everything else works as intended:

| Area | Behavior with `REQUIRE_MFA` unset or false | Code |
|---|---|---|
| Sign-in | First factor only (password, Google or email code) for everyone. No MFA prompt, no `mfa_required` denials. | `MfaPolicy.required_for?` (`api/app/services/mfa_policy.rb`) |
| Step-up before sensitive actions | A fresh **first** factor within 10 minutes. The API's 403 says `level: "first_factor"`, so Clerk asks the person to re-enter their password or an emailed code. Nobody is sent to enrollment. | `MfaPolicy.recently_step_up_verified?`, `step_up_level`; `api/app/controllers/concerns/recent_verification.rb` |
| Which actions step up | Turning on any part of a company's employee app, setting demo early access, starting a view-only "Sign in as" (view-as), and the employee app's protected changes (profile edits, electronic-delivery consent, claiming or reactivating a link). Turning things off, ending early access and the demo kill switch never step up. | `employee_app_switch/update.rb`, `admin/employee_app_switches_controller.rb`, `view_as_grants_controller.rb`, `employee_portal/*` |
| View-as | Available (it no longer waits for `REQUIRE_MFA`); still needs `VIEW_AS_READY=true`, the RLS guard in `raise` and `CLERK_AUTHORIZED_PARTIES`. | `api/app/models/view_as_grant.rb` |
| Employee app switch readiness | The check "Two-step sign-in is required" shows **Not required yet** (status `waived`) for **every company, demo and live**, with the detail "Two-step sign-in isn't required yet; it will be turned on for everyone before real employees use the app." It doesn't block turning on. | `employee_app_switch/readiness.rb` (`mfa_check`) |
| `production:readiness` | The MFA lines below report **WARN** (advisory), not FAIL, with a detail saying MFA is intentionally off pending the Clerk Pro rollout. The run passes on them. The Clerk key itself must still be accepted. | `api/app/services/production_readiness.rb` (`mfa_check`, `clerk_backend_check`) |
| Employee service attestation | Its signed `service_checks_passed` covers only the four `employee_web:` checks, so intentionally-off MFA (and the payroll tax-table checks) never mark the employee service unhealthy. | `ProductionReadiness#employee_service_checks`, `employee_app_switch/service_attestation.rb` |

Because the switch doesn't block real companies while MFA is off, **turning MFA on before real employees use the app is a process step, not a system gate.** Schedule the flip before any live company's employee app is opened to its employees.

### 0.2 When `REQUIRE_MFA=true`

| Fact | Where |
|---|---|
| `REQUIRE_MFA` is parsed as a boolean (`1/true/t/yes/y/on`). Default is off. | `MfaPolicy.enabled?` |
| MFA is required for **every** user, every role, employees included. | `MfaPolicy.required_for?` |
| A session counts as verified only if the token has the claim `two_factor_enabled == true` **and** `fva[1] >= 0`. A new-device email code alone (`fva` like `[1,0]` with no claim) is refused. | `MfaPolicy.verified_second_factor?`; spec `api/spec/requests/mfa_enforcement_spec.rb` |
| Every Clerk-authenticated request runs `enforce_mfa!`, and so does the employee API. A route-enumeration spec fails if any Clerk route lacks it. | `concerns/clerk_authenticatable.rb`, `concerns/mfa_enforceable.rb`, `employee_portal/base_controller.rb`, `api/spec/routing/clerk_mfa_coverage_spec.rb` |
| A denial returns `403 {code: "mfa_required"}` and writes a `security` audit event `authentication#mfa_required_denied`. | `mfa_enforceable.rb`, `MfaPolicy.record_denial!` |
| `GET /api/v1/auth/me` returns `200 {mfa_required: true, mfa_verified: false}` (not a 403) so the staff app can show its prompt. | `auth_controller.rb` |
| Step-up needs a fresh **second** factor (`level: "second_factor"`); an unenrolled session gets `mfa_enrollment_required`. | `recent_verification.rb` |
| The switch readiness MFA check is a hard check again: Payroll web **and** the employee service must both report `REQUIRE_MFA` with recorded evidence. | `readiness.rb` (`mfa_check`) |
| WebSocket tickets are refused without a verified second factor. | `cable_ticket_service.rb`; `application_cable/connection.rb` |

### 0.3 Readiness lines that touch MFA

`bundle exec rails production:readiness` (`api/lib/tasks/production_readiness.rake`):

| Check | MFA off | MFA on: passes when |
|---|---|---|
| `MFA enforcement has instance-bound evidence` | WARN | `CLERK_MFA_ATTESTED_INSTANCE_ID` looks like `ins_…` and `CLERK_MFA_EVIDENCE_REF` is present (one line, ≤ 500 bytes) |
| `Clerk Backend API accepts the configured key and matches MFA evidence` | PASS if the key works and the instance matches; WARN if the key works but the instance doesn't match yet; **FAIL if Clerk rejects the key** | `GET https://api.clerk.com/v1/instance` returns 200 and its `id` equals `CLERK_MFA_ATTESTED_INSTANCE_ID` |
| `Clerk session token includes the MFA enrollment claim` | PASS (not checked) | `CLERK_MFA_SAMPLE_TOKEN_FILE` points to a correctly signed session token issued in the last 15 minutes whose `two_factor_enabled` is a JSON boolean |
| `Pre-flip MFA check: Clerk session token includes boolean two_factor_enabled claim` | WARN until a valid sample token is supplied (then PASS) | Same sample-token test, run whether or not the flag is on, so the claim can be proved before the flip |

Judge by line, not exit code. The `2027 payroll tax tables are verified` line is a payroll-calendar check and is unrelated to MFA.

What the checks **cannot** see: whether Clerk actually has authenticator and backup codes enabled, or who has enrolled. `docs/PRODUCTION_READINESS_CHECKLIST.md` says so directly: the evidence reference is a human attestation of the Clerk dashboard state. Step 4 produces that evidence.

---

## 1. Preconditions

Do not start until every box is checked.

- [ ] **The MFA-ready code is deployed** on Payroll web, worker and the employee service (`MfaPolicy.recently_step_up_verified?` exists in the deployed commit).
- [ ] **Rehearsal done** on the separate Clerk development instance (never the instance serving production), with Clerk's **Require multi-factor authentication** on: an enrolled staff user passes; an unenrolled staff user and an unenrolled employee each get Clerk's set-up-two-step step during sign-in (or the app's prompt); a new-device email code alone is refused; backup-code sign-in passes; the employee app's **My info → Sign-in & security** page shows Clerk's Security section. Record where the evidence is.
- [ ] **Clerk production is live** and the owner can sign in.
- [ ] **Two recovery admins** exist for Payroll, each with: a Clerk dashboard login that has its own two-step sign-in, a Payroll staff account that works today, and the ability to reach the Render dashboard or a named person who can. (`docs/OPERATOR_AND_RECOVERY_ACCEPTANCE.md`; `docs/PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md`.)
- [ ] **Roster written down**, by role not name: active staff users, active client users, and employee logins by company. The Payroll user list is the source; Clerk shows who has signed in.
- [ ] **Notices sent** at least 48 hours before the flip using [MFA_ROLLOUT_NOTICE_TEMPLATE.md](MFA_ROLLOUT_NOTICE_TEMPLATE.md): the staff and client version, and the employee version for every company whose employee app is on. Name a support contact who is reachable all weekend, and tell each client's managers so they can help their employees.
- [ ] **Rollback values written** in the access-controlled record: current `REQUIRE_MFA`, `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF` (all empty or unset today) on each of the three services, and the Clerk **Require multi-factor authentication** setting (off today).
- [ ] **Quiet period agreed:** no payroll run, check printing or import in progress, no one mid-edit. Anyone signed in when the flag flips is shown the enrollment prompt on their next request and loses unsaved form changes.
- [ ] **Baseline readiness saved:** run `bundle exec rails production:readiness` in a Render shell on Payroll web and keep the output. Expect the MFA lines as WARN (§0.3) and nothing new failing.

---

## 2. Ordered steps

Times are guides. The order is not.

### Step 1: Buy Clerk Pro (owner)

Why first: Clerk's MFA "requires a paid plan for production use, but you can try it for free in development mode" ([Clerk: sign-up and sign-in options](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options)). The pricing table lists MFA as Hobby "No", Pro "Yes" ([Clerk pricing](https://clerk.com/pricing)).

1. Clerk Dashboard → the **production** application → **Billing** → upgrade to **Pro**. Choose monthly or annual.
2. Confirm the plan shows Pro. Do this at least a day before the flip so enrollment can happen (Step 5).

Buying Pro changes nothing for users by itself.

### Step 2: Check the session token claim (owner)

1. Dashboard → **Sessions** → **Customize session token** → **Claims**.
2. Make sure this entry is present next to any existing claims, then **Save**:

   ```json
   {
     "two_factor_enabled": "{{user.two_factor_enabled}}"
   }
   ```

   This is the template from `docs/PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md`. Clerk's shortcode table lists `{{user.two_factor_enabled}}` as a boolean, and a standalone shortcode keeps its type in the token, so it arrives as a JSON `true` or `false` ([Clerk JWT templates: shortcodes](https://clerk.com/docs/guides/sessions/jwt-templates#available-shortcodes); [customize session tokens](https://clerk.com/docs/guides/sessions/customize-session-tokens)). Do **not** wrap it in other text; an interpolated shortcode becomes a string and the app treats only a boolean `true` as enrolled.
3. Keep custom claims under about 1.2 KB (Clerk's guidance).
4. Clerk refreshes the session token about every 60 seconds, so the claim can lag a change by up to a minute.

**This step must be finished and verified (Step 4) before the flip.** If the claim is missing, nobody is "enrolled" as far as the API is concerned, and every user, including enrolled ones, is refused after the flip.

### Step 3: Enable strategies in Clerk (owner)

Dashboard → **User & authentication** → **Multi-factor** ([Clerk docs](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options#multi-factor-authentication)). Then **Save**.

| Setting | Value | Why |
|---|---|---|
| Authenticator application (TOTP) | **On** | Primary second factor. |
| Backup codes | **On** | Single-use recovery. Clerk requires another strategy first; it is generated at the end of authenticator enrollment ([MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery)). |
| SMS verification code | **Off** | Decided: no SMS. It also costs $0.01 per message on Pro. |
| **Require multi-factor authentication** | **Off for now; turn it On in Step 6** | Everyone is required now, so this instance-wide toggle matches the app's rule and is wanted: Clerk then walks an unenrolled user through setting up the second step during sign-in, on the staff and employee sites alike. (The earlier advice to keep it off existed only because employees were exempt.) Turn it on at the flip, not before, so the enrollment window (Step 5) happens on people's own time. |
| Passkeys satisfy multi-factor authentication | **Off** (leave as is) | The app requires the `two_factor_enabled` claim; a passkey sign-in on its own would not satisfy it. |

Also confirm, under the same Clerk instance, that **User & authentication → Email → Sign-in with email → Email verification code** is on (cutover runbook). It is how people who sign in with Google pass the first-factor step-up while MFA is off.

**Device Trust (formerly Client Trust):** this Clerk setting emails a code on a new device for password sign-ins by users with no second factor ([Clerk Device Trust](https://clerk.com/docs/guides/protect/device-trust)). Leave it as it is. The API does not accept that email code as a second factor (spec `mfa_enforcement_spec.rb`), so it neither helps nor hurts enforcement. Expect some people on new devices to see two prompts after enrolling; see [§5](#5-known-gaps).

### Step 4: Verify on test accounts (owner or recovery admin)

Use dedicated test accounts that are not a real person's login: one staff account (for example a manager or accountant) and one employee login on a demo company (Harbor Finch).

1. Sign in on the production site. The app still lets you in (the flag is off).
2. Open the account settings: on Payroll, **Account & security** (`/app/account-security`); on the employee app, **My info → Sign-in & security** (`/security`). Go to **Security → Two-step verification → Authenticator app**. Scan the QR code, enter the code, and **save the backup codes** in the evidence location.
3. Get a fresh session token and decode it **locally**. Do not paste it into a website. In the browser console on that site: `await window.Clerk.session.getToken({skipCache: true})`. Check:
   - `two_factor_enabled` is the JSON boolean `true`;
   - `fva` has two integers, for example `[3, -1]` right after a password sign-in.
4. Sign out, sign in again with the password **and** the authenticator code. Fetch a token again: `fva[1]` must now be `>= 0` (for example `[1, 0]`).
5. Repeat on a test account with **no** second factor: the claim must be the JSON boolean `false` (not missing, not the string `"false"`).
6. Run readiness with a sample token. The pre-flip line works with the flag off, so no Render variable changes yet:

   ```bash
   umask 077
   # put the token from item 4 into a private file, then:
   CLERK_MFA_SAMPLE_TOKEN_FILE=/path/to/private-file bundle exec rails production:readiness
   rm -f /path/to/private-file
   ```

   `Pre-flip MFA check: Clerk session token includes boolean two_factor_enabled claim` must say `PASS`. For the full set, run once more with the flag on **for this shell only** (nothing changes on Render):

   ```bash
   REQUIRE_MFA=true \
   CLERK_MFA_ATTESTED_INSTANCE_ID=ins_xxxxxxxx \
   CLERK_MFA_EVIDENCE_REF=<non-secret reference> \
   CLERK_MFA_SAMPLE_TOKEN_FILE=/path/to/private-file \
   bundle exec rails production:readiness
   ```

   All four MFA lines must say `PASS`. Fetch the token no more than 15 minutes before running. To read the instance ID without printing the key: `curl -s -H "Authorization: Bearer $CLERK_SECRET_KEY" https://api.clerk.com/v1/instance | ruby -rjson -e 'puts JSON.parse(STDIN.read)["id"]'`. Keep tokens out of shell history, logs and retained evidence.

   If any line fails, stop and fix the Clerk setting. Do not proceed.

### Step 5: Enrollment window (everyone, before the flip)

Goal: as many people as possible enroll and save backup codes **before** `REQUIRE_MFA=true`. Enrolling early takes a few minutes. Enrolling after the flip works too: Clerk's set-up step (Step 6 turns it on) or the app's prompt walks them through it, but they are blocked until they finish.

**Where people enroll:**

- **Staff and client users:** Payroll → **Account & security** (`/app/account-security`), which embeds Clerk's account settings. Clerk's hosted Account Portal (`https://accounts.shimizu-technology.com/user`) also works; check it loads the Security section on a test account first.
- **Employees:** the employee app → **My info → Sign-in & security** (`/security`), which embeds the same Clerk settings with the company's branding. After the flip, an employee who hasn't enrolled sees **Set up two-step sign-in**, which opens the same page.

Order of enrollment:

1. **Recovery admins first.** Each enrolls, saves backup codes in separate storage (a password manager entry or printed copy kept apart from the phone), signs out, signs back in with the authenticator code, and confirms `fva[1] >= 0` as in Step 4. Each then removes and re-adds their own factor once (or has the other admin reset it, §3.3) to prove recovery works.
2. **Cornerstone staff.**
3. **Client users.** Send the notice and offer a 10-minute call.
4. **Employees**, company by company, with the employee notice. Their manager is the first line of help.
5. Track a simple table by role and company: notified, enrolled, signed in with second factor. Clerk shows each user's enrolled methods under **Users → the user → Two step verifications**.

**Go/no-go for the flip:** both recovery admins verified, plus every staff user who runs payroll. Client users and employees who have not enrolled are not a blocker; they enroll at their next sign-in, with support on call. Anyone without a smartphone can use a desktop authenticator, such as a password manager's one-time-code feature, or wait for support.

### Step 6: Flip (owner)

Do these together, within a few minutes:

1. In the Render dashboard, set the same values on **Payroll web**, **Payroll worker** and **the employee API** (`cornerstone-payroll-employee-api`, when it exists):

   | Variable | Value |
   |---|---|
   | `REQUIRE_MFA` | `true` |
   | `CLERK_MFA_ATTESTED_INSTANCE_ID` | the production instance ID (`ins_…`) read from Clerk in Step 4 |
   | `CLERK_MFA_EVIDENCE_REF` | a non-secret pointer to the access-controlled evidence (for example a folder and date): the dashboard screenshots of Step 3, the Step 4 results and the Step 5 recovery-admin checks |

   The evidence ref must be one line and at most 500 bytes. Save each service, then **Manual Deploy → Deploy latest commit** (or restart) so the new environment loads; confirm `/up` returns 200 with HSTS.
2. In Clerk: **User & authentication → Multi-factor → Require multi-factor authentication → On**. Save.

The employee API must get the values at the same time as Payroll web: it enforces sign-in for employees itself, and the switch readiness MFA check stays failed until both services report `REQUIRE_MFA` with evidence. The Clerk instance does not change in this rollout, so no JWKS cache clear is needed.

### Step 7: Readiness runs (owner or recovery admin)

In a Render shell on Payroll web, and again on the employee API, with a fresh token from the enrolled test account (as in Step 4 item 6):

```bash
umask 077
# token file as in Step 4
CLERK_MFA_SAMPLE_TOKEN_FILE=/path/to/private-file bundle exec rails production:readiness
rm -f /path/to/private-file
```

Expected: every MFA line `PASS`; they are hard FAILs now, no longer WARNs. On the employee API all four `employee_web:` lines must still pass. The `2027 payroll tax tables are verified` line is unrelated. Save the final `EVIDENCE {...}` line with the release evidence (it is safe to retain, per `docs/PRODUCTION_READINESS_CHECKLIST.md`).

Then open **Employee app switch** for a company in Payroll: "Two-step sign-in is required" must show **Passed**.

### Step 8: Verify allowed and denied sessions

Use real browsers (a private window each). Record the result of each row in the evidence location.

| # | Session | Expected |
|---|---|---|
| 1 | Test staff account, enrolled, signed in with password + authenticator | App loads; `GET /api/v1/auth/me` has `mfa_required: true, mfa_verified: true`. |
| 2 | Same account, sign in with a backup code instead of the authenticator | App loads. (Burns that code; regenerate afterwards.) |
| 3 | Test staff account with **no** second factor, signs in fresh | Clerk asks it to set up the second step during sign-in. If a session somehow reaches the app, it shows "Multi-factor authentication required"; every other API route returns 403 `mfa_required`, with one `authentication#mfa_required_denied` audit event. |
| 4 | Staff account that was signed in before the flip, with a new-device email code but no authenticator | Denied (`mfa_required`). The email code is not accepted as a second factor. |
| 5 | A client user, enrolled | Loads on its client subdomain; company scope unchanged. |
| 6 | Employee test account (demo company), enrolled | Pay screens load after password + authenticator. |
| 7 | Employee test account with **no** second factor | Clerk's set-up step at sign-in; a pre-flip session sees **Complete two-step sign-in** or **Set up two-step sign-in** (→ Sign-in & security), and `/api/v1/employee/*` returns 403 `mfa_required`. |
| 8 | Step-up: turn on a switch, start a view-as, or edit a phone number on the employee app | Clerk asks for the **second** factor (`level: "second_factor"`), not a password. |
| 9 | Live updates (WebSocket) for an enrolled staff user | Connects; for a non-enrolled user the ticket request returns 403. |
| 10 | A deactivated user | Still refused, unchanged. |

Roll back (§3.4) if rows 1, 2 or 6 fail, or if a recovery admin cannot sign in.

### Step 9: After the flip

- [ ] Watch the support contact for the first day. Check `authentication#mfa_required_denied` events at the end of the first day; a person denied repeatedly after enrolling is probably still on an old session (sign out and in again).
- [ ] Fill in the "Clerk production identity and MFA" row of `docs/OPERATOR_AND_RECOVERY_ACCEPTANCE.md` with the date, operator, reviewer and evidence location (no secrets).
- [ ] Add a short line to the production-readiness evidence set noting the date, the commit, and the readiness result.
- [ ] Reset the Step 4 test accounts or keep them documented as test accounts. Do not leave test tokens on disk.

---

## 3. Recovery

### 3.1 Someone lost or replaced their phone

1. **They have backup codes:** sign in with password, choose "Use another method", enter one backup code. Then, in account settings (Payroll **Account & security**, or the employee app's **Sign-in & security**), add the new phone and **regenerate backup codes** ([Clerk MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery)). Each code works once.
2. **They have no backup codes:** a recovery admin resets their two-step sign-in (3.3). At their next sign-in Clerk asks them to set it up again on the new phone.
3. **They are still signed in on another device** (a session with `fva[1]` still fresh): they can add a new authenticator from account settings there before they lose that session.

Employees ask their manager first; the manager contacts Cornerstone support, who confirms identity before a recovery admin resets anything.

### 3.2 Backup codes

- Each is single-use. Clerk generates a set when the authenticator is enrolled and the user can regenerate them from their profile.
- Store them apart from the phone. A password manager entry or a printed copy in a safe place both work. Never keep them only in a note on the same phone.
- Removing a user's last second factor makes Clerk delete their backup codes and disable MFA for that user. If they re-enroll, they get new codes.

### 3.3 Who can reset a user's two-step sign-in

Clerk has no self-service reset in the sign-in flow. A reset happens in the Clerk Dashboard or through the Clerk Backend API ([MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery)).

- **Who:** the two recovery admins (the owner and the second admin), because they hold Clerk dashboard access.
- **How:** Dashboard → **Users** → the user → **Two step verifications** → the menu next to **Authenticator app** → **Remove method**. There is no "reset all" button, and backup codes have no remove option (Clerk deletes them with the last factor). The Backend API alternative is `users.disableUserMFA(userId)`.
- **Before resetting,** verify identity out of band: call back on a number already on file or speak in person; never reset on an email or text alone. Log who, when, and how identity was checked (no secrets).
- **A reset does not sign out existing sessions.** If the account may be compromised, also end its sessions in the Dashboard (Users → the user → Sessions) before the person re-enrolls.
- **The two recovery admins reset each other.** That is why both must have separate Clerk logins, separate backup codes and a working second factor before the flip. If both are locked out, use the break-glass in 3.4.

### 3.4 Rollback and break-glass (no data is lost)

Neither setting writes payroll data, and enrolled factors stay in Clerk. Undo **both**: Clerk's toggle alone would still force enrollment at sign-in, and `REQUIRE_MFA` alone would still refuse unverified sessions.

1. Clerk: **Require multi-factor authentication → Off**. Save.
2. Render → Payroll web, worker and the employee API: set `REQUIRE_MFA=false`.
3. Redeploy or restart each. Within a couple of minutes everyone signs in with their first factor again, and the system is back in MFA-ready mode (§0.1): step-up asks for a password or email code, the switch shows two-step sign-in as **Not required yet**, and the readiness MFA lines are WARNs.
4. Leave `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF` in place or clear them; either is safe.
5. Fix the cause (3.3 for a locked user, Step 2 for a missing claim, Step 3 for strategy settings), then repeat from Step 4.
6. Do not downgrade Clerk Pro or delete the instance during an incident. The cutover runbook keeps the production instance intact for investigation.

Roll back immediately if: a recovery admin cannot sign in; enrolled users are refused (probably a missing or string-typed `two_factor_enabled` claim); or the readiness MFA lines fail after the flip.

---

## 4. Impact by group

| Group | Required? | Before the flip | After the flip | What they do |
|---|---|---|---|---|
| **Cornerstone staff** (super admin, org admin, admin, manager, accountant) | Yes | Enroll authenticator + backup codes in the window (Account & security). | Sign in with password or Google, then the authenticator code. Step-up asks for the code again. | Follow the staff notice. Recovery admins go first. |
| **Client users** (role client) | Yes | Enroll from the notice. | Same as staff, on their client address. | Notice plus a short call. |
| **Employees** (`employee`, `portal_employee`) | **Yes** | Enroll from the employee notice (My info → Sign-in & security). | Sign in with password, Google or email code, then the authenticator code. Protected changes ask for the code again. | Employee notice; their manager helps first. |
| **Dual-role users** (staff or client with an employee link) | Yes, everywhere | Enroll like staff. One enrollment covers both sites. | Same as staff. | Staff notice. |
| **New invited users** after the flip | Yes | n/a | Clerk asks them to set up the second step during their first sign-in. | Add one line to invitation emails. |

Notes:

- Google sign-in does not skip the second factor. Only sessions with the claim `two_factor_enabled == true` and a verified second factor pass.
- Practice-company, demo and other special accounts are required too. List them in the roster.
- Existing browser sessions are not cut off by the flip alone, but their next API request returns 403 and the app shows its prompt.

---

## 5. Known gaps

| # | Gap | Severity | Effect | Suggested follow-up |
|---|---|---|---|---|
| 1 | **Enrolling probably does not refresh an existing session.** The check needs `fva[1] >= 0`, which Clerk sets when a second factor is used. Someone who enrolls from inside a pre-flip session may need to sign out and in. Confirm in the rehearsal. | Medium | A new enrollee is blocked and confused after doing everything right. | The staff prompt and the employee "Set up two-step sign-in" screen say to try again; if the rehearsal shows a sign-out is needed, reword them to say so. |
| 2 | **Clerk's set-up step on our sign-in forms.** With Clerk's Require MFA on, the embedded `<SignIn>` (staff `Login.tsx`, employee `ClerkAuth.tsx`, both `routing="hash"`) must show Clerk's set-up step for an unenrolled user. | Medium | If it doesn't, unenrolled users land on the app's own prompt instead, which still works. | Rehearse on the development instance (precondition). |
| 3 | **Invited users who have not enrolled can't reach the bind step until they do.** | Low | Their first visit includes the set-up step. | Add a line to invitation emails and the notice. |
| 4 | **Readiness checks the attestation, not the provider.** It cannot tell whether TOTP/backup codes are on in Clerk or who has enrolled. | Low–medium | The roster in Step 5 is manual. | Show enrolled/not enrolled in the staff user list from `two_factor_enabled`. |
| 5 | **Mid-session flip drops unsaved work.** The first 403 swaps the app to the prompt. | Low | Anyone mid-form loses it. | Procedural: quiet period. |
| 6 | **Two-prompt experience on new devices.** Device Trust's email code and the authenticator code can both appear; the app ignores the email code for enforcement. | Low | Confusing but safe. | Mention in the notices. |
| 7 | **No system gate on real employees before the flip.** While MFA is off, a live company's employee app can be turned on (owner decision, Nov 25, 2026: MFA behaves the same for every company). | Process | Real employees could use the app before two-step sign-in is on. | Flip before opening a live company's employee app to its employees. |
| 8 | **AIRE is out of scope.** This runbook covers Payroll only; AIRE uses its own Clerk setup and `REQUIRE_MFA`. | Info | No change to AIRE. | Separate runbook when AIRE is scheduled. |

---

## 6. Evidence to keep (private location, referenced by `CLERK_MFA_EVIDENCE_REF`)

- Clerk plan page showing Pro, and the Multi-factor page showing authenticator and backup codes on, SMS off, **Require multi-factor authentication** on (after Step 6).
- The Customize session token claims page.
- Step 4 results for the enrolled and not-enrolled test accounts, staff and employee (decoded claim values only, no tokens).
- The Step 5 table (counts by role and company: enrolled, signed in with second factor).
- Final `EVIDENCE {...}` lines from Step 7 (Payroll web and the employee API) and the Step 8 result table.
- The recovery-admin exercises (3.3).

## Sources

- Repo: [M3 plan](../MILESTONE_3_FOUNDATIONS_BUILD_PLAN_2026-11-22.md), [M4 plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md), [identity cutover runbook](../PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md), [operator and recovery acceptance](../OPERATOR_AND_RECOVERY_ACCEPTANCE.md), [production readiness checklist](../PRODUCTION_READINESS_CHECKLIST.md), [M4 employee platform runbook](M4_EMPLOYEE_PLATFORM_RUNBOOK.md), [employee app switch](M4_EMPLOYEE_APP_SWITCH.md).
- Clerk (checked 2026-11-25): [pricing](https://clerk.com/pricing), [sign-up and sign-in options](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options), [MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery), [customize session tokens](https://clerk.com/docs/guides/sessions/customize-session-tokens), [JWT template shortcodes](https://clerk.com/docs/guides/sessions/jwt-templates), [session tokens (`fva`)](https://clerk.com/docs/guides/sessions/session-tokens), [reverification](https://clerk.com/docs/guides/secure/reverification), [Device Trust](https://clerk.com/docs/guides/protect/device-trust).
- Clerk's docs do not say whether a Device Trust email code writes `fva[1] = 0` for a user with no second factor. The API refuses that case regardless (spec `mfa_enforcement_spec.rb`). Re-check on the development instance in the rehearsal.
