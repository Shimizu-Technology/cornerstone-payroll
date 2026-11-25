# Two-step sign-in rollout runbook (gate G3)

**Who does this:** the owner (Clerk, Render and Netlify logins) with one recovery admin as the second pair of eyes.
**Planned window:** weekend of November 28–29, 2026 (ChST). Not on a payroll cutoff day, and not while anyone is mid-entry on a pay period.
**What it does:** turns on `REQUIRE_MFA=true` so Cornerstone staff and client users must sign in with a second factor (authenticator app or backup code). Employee-only users are not required to enroll.
**Gate:** G3 in [the M4 build plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) (line 184). Clerk Pro is bought at this gate.
**Cost:** Clerk Pro $25/month, or $20/month billed annually (M4 plan line 22; [Clerk pricing](https://clerk.com/pricing), checked 2026-11-25).

This repo is public. Do not write names, emails, tokens, instance secrets or backup codes into this file, a PR, a ticket or a chat. Record them in the access-controlled evidence location and refer to them by role.

---

## 0. What the system does today (read this first)

| Fact | Where |
|---|---|
| `REQUIRE_MFA` is parsed as a boolean (`1/true/t/yes/y/on`). Default is off. | `api/app/services/mfa_policy.rb:13-15` |
| MFA is required for every user except employee-only users (`employee` and `portal_employee` roles). Dual-role users (staff or client who also have an employee link) are required. | `mfa_policy.rb:17-23` |
| A session counts as verified only if the token has the claim `two_factor_enabled == true` **and** `fva[1] >= 0`. A new-device email code alone (`fva` like `[1,0]` with no claim) is refused. | `mfa_policy.rb:25-31`; spec `api/spec/requests/mfa_enforcement_spec.rb:102-109` |
| Every Clerk-authenticated request runs `enforce_mfa!` (not tied to URL prefix). A route-enumeration spec fails if any Clerk route lacks it. | `api/app/controllers/concerns/clerk_authenticatable.rb:12`, `api/app/controllers/concerns/mfa_enforceable.rb:12-14`, `api/spec/routing/clerk_mfa_coverage_spec.rb` |
| The employee API controller also enforces it. | `api/app/controllers/api/v1/employee_portal/base_controller.rb:9` |
| First sign-in by an invited user is also checked before the account is bound. | `clerk_authenticatable.rb:56-61` |
| A denial returns `403 {code: "mfa_required"}` and writes a `security` audit event `authentication#mfa_required_denied`. | `mfa_enforceable.rb:20-30`; `mfa_policy.rb:53-71` |
| `GET /api/v1/auth/me` returns `200 {mfa_required: true, mfa_verified: false}` (not a 403) so the web app can show the enrollment prompt. | `api/app/controllers/api/v1/auth_controller.rb:38-41,51-55` |
| WebSocket tickets are refused without a verified second factor, and the socket re-checks a server-side marker. | `api/app/services/cable_ticket_service.rb:8-22`; `api/app/channels/application_cable/connection.rb:28-35` |
| Session step-up for sensitive changes (`require_recent_verification!`) exists with specs but has **no callers yet**. It is not part of this rollout. | `api/app/controllers/concerns/recent_verification.rb:8-31` |

### Readiness checks that touch MFA

`bundle exec rails production:readiness` (`api/lib/tasks/production_readiness.rake`) has three MFA lines:

| Check | Passes when | Code |
|---|---|---|
| `MFA enforcement has instance-bound evidence` | `REQUIRE_MFA` is on, `CLERK_MFA_ATTESTED_INSTANCE_ID` looks like `ins_…`, and `CLERK_MFA_EVIDENCE_REF` is present (≤ 500 bytes, one line) | `production_readiness.rb:191,314-325` |
| `Clerk Backend API accepts the configured key and matches MFA evidence` | `GET https://api.clerk.com/v1/instance` returns 200 and its `id` equals `CLERK_MFA_ATTESTED_INSTANCE_ID` | `production_readiness.rb:250,397-402` |
| `Clerk session token includes the MFA enrollment claim` | With `REQUIRE_MFA` on: `CLERK_MFA_SAMPLE_TOKEN_FILE` points to a correctly signed session token issued in the last 15 minutes whose `two_factor_enabled` is a JSON boolean (`true` or `false`) | `production_readiness.rb:251,404-419` |

Before the flip, the first two fail and the third passes trivially (it returns `true` while `REQUIRE_MFA` is off). As of November 24 the baseline was 31 of 34 with the two MFA-evidence lines and the 2027 tax tables failing (M3 plan line 874); the M4 runbook expects the same two MFA lines to fail before G3 (`docs/rollout/M4_EMPLOYEE_PLATFORM_RUNBOOK.md:98-103`). Judge by line, not exit code.

What the checks **cannot** see: whether Clerk actually has authenticator and backup codes enabled, or who has enrolled. `docs/PRODUCTION_READINESS_CHECKLIST.md:38` says so directly: the evidence reference is a human attestation of the Clerk dashboard state. Step 6 below produces that evidence.

---

## 1. Preconditions

Do not start until every box is checked.

- [ ] **M4-1 code is deployed** on Payroll web and worker (the claim-aware `MfaPolicy` above). Confirm the deployed commit includes it.
- [ ] **Rehearsal done** on the separate Clerk development instance (never the instance serving production): enrolled user passes, unenrolled user gets `mfa_required`, new-device email code alone is refused, backup-code sign-in passes. Record where the evidence is. (M3 plan §2.2 item 5, line 358; M4-1 acceptance, M4 plan line 226.)
- [ ] **Clerk production is live** (M3-0b, done November 24, 2026; M3 plan §4.9) and the owner can sign in.
- [ ] **Two recovery admins** exist for Payroll, each with: a Clerk dashboard login that has its own two-step sign-in, a Payroll staff account that works today, and the ability to reach the Render dashboard or a named person who can. (`docs/OPERATOR_AND_RECOVERY_ACCEPTANCE.md:57-60`; `docs/PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md:41,60`.)
- [ ] **Roster written down**, by role not name: every active staff user, every active client user, and every user with both a staff/client role and an employee link (dual-role). The Payroll user list is the source; Clerk shows who has signed in. Employee-only users are listed separately because they are not affected.
- [ ] **Notice sent** at least 48 hours before the flip using [MFA_ROLLOUT_NOTICE_TEMPLATE.md](MFA_ROLLOUT_NOTICE_TEMPLATE.md), with a named support contact who is reachable all weekend.
- [ ] **Rollback values written** in the access-controlled record: current `REQUIRE_MFA`, `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF` (all empty or unset today), and the two services they live on.
- [ ] **Quiet period agreed:** no payroll run, check printing or import in progress, no one mid-edit. Anyone signed in when the flag flips is shown the enrollment prompt on their next request and loses unsaved form changes.
- [ ] **Baseline readiness saved:** run `bundle exec rails production:readiness` in a Render shell on Payroll web and keep the output. Expect exactly the known failures above (and nothing new).
- [ ] **Employee site (if live):** you know which of the employee API's variables must match (`REQUIRE_MFA`, `CLERK_MFA_ATTESTED_INSTANCE_ID`, `CLERK_MFA_EVIDENCE_REF`; `ops/render/employee-web.render.yaml:63-78`). It is set in step 8.

---

## 2. Ordered steps

Times are guides. The order is not.

### Step 1: Buy Clerk Pro (owner)

Why first: Clerk's MFA "requires a paid plan for production use, but you can try it for free in development mode" ([Clerk: sign-up and sign-in options](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options)). The pricing table lists MFA as Hobby "No", Pro "Yes" ([Clerk pricing](https://clerk.com/pricing)).

1. Clerk Dashboard → the **production** application → **Billing** → upgrade to **Pro**. Choose monthly or annual.
2. Confirm the plan shows Pro. Do this at least a day before the flip so enrollment can happen (Step 5).

Buying Pro changes nothing for users by itself. Nobody is asked to do anything until Step 3 turns strategies on.

### Step 2: Check the session token claim (owner)

1. Dashboard → **Sessions** → **Customize session token** → **Claims**.
2. Make sure this entry is present next to any existing claims, then **Save**:

   ```json
   {
     "two_factor_enabled": "{{user.two_factor_enabled}}"
   }
   ```

   This is the template from `docs/PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md:151-157`. Clerk's shortcode table lists `{{user.two_factor_enabled}}` as a boolean, and a standalone shortcode keeps its type in the token, so it arrives as a JSON `true` or `false` ([Clerk JWT templates: shortcodes](https://clerk.com/docs/guides/sessions/jwt-templates#available-shortcodes); [customize session tokens](https://clerk.com/docs/guides/sessions/customize-session-tokens)). Do **not** wrap it in other text; an interpolated shortcode becomes a string and the app treats only a boolean `true` as enrolled (`mfa_policy.rb:29-31`).
3. Keep custom claims under about 1.2 KB (Clerk's guidance).
4. Clerk refreshes the session token about every 60 seconds, so the claim can lag a change by up to a minute.

**This step must be finished and verified (Step 4) before the flip.** If the claim is missing, nobody is "enrolled" as far as the API is concerned, and every staff and client user, including enrolled ones, is refused after the flip.

### Step 3: Enable strategies in Clerk (owner)

Dashboard → **User & authentication** → **Multi-factor** ([Clerk docs](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options#multi-factor-authentication)). Then **Save**.

| Setting | Value | Why |
|---|---|---|
| Authenticator application (TOTP) | **On** | Primary second factor. |
| Backup codes | **On** | Single-use recovery. Clerk requires another strategy first; it is generated at the end of authenticator enrollment ([MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery)). |
| SMS verification code | **Off** | Decided: no SMS. It also costs $0.01 per message on Pro. |
| **Require multi-factor authentication** | **Off. Do not turn this on.** | This Clerk toggle is instance-wide. It would force every user, including employee-only users, to enroll before sign-in finishes, which contradicts decision D9 (employees are not required). The app enforces by role through `REQUIRE_MFA` instead. |
| Passkeys satisfy multi-factor authentication | **Off** (leave as is) | The app requires the `two_factor_enabled` claim; a passkey sign-in on its own would not satisfy it. |

Also confirm, under the same Clerk instance, that **User & authentication → Email → Sign-in with email → Email verification code** is on (cutover runbook lines 159-160). Employees who sign in with Google need it for first-factor step-up later.

**Device Trust (formerly Client Trust):** this Clerk setting emails a code on a new device for password sign-ins by users with no second factor. It is on by default for apps created after November 14, 2025 and is included on every plan ([Clerk Device Trust](https://clerk.com/docs/guides/protect/device-trust)). Leave it as it is. The API does not accept that email code as a second factor (spec `mfa_enforcement_spec.rb:102-109`), so it neither helps nor hurts staff enforcement. Expect staff on new devices to see two prompts after enrolling in some cases; see [§5 gaps](#5-gaps-in-the-code-that-affect-this-rollout).

### Step 4: Verify on a test account (owner or recovery admin)

Use one dedicated test staff account that is not a real person's login and that is not an employee-only user. It must exist in Payroll with a role that is required (for example a manager or accountant) so that `required_for?` is true.

1. Sign in on the production site. The app still lets you in (the flag is off).
2. Open the account settings (see Step 5 for how), **Security → Two-step verification → Authenticator app**. Scan the QR code, enter the code, and **save the backup codes** in the evidence location.
3. Get a fresh session token for this account and decode it **locally**. Do not paste it into a website. In the browser console on the Payroll site: `await window.Clerk.session.getToken({skipCache: true})`. Check:
   - `two_factor_enabled` is the JSON boolean `true`;
   - `fva` has two integers, for example `[3, -1]` right after a password sign-in.
4. Sign out, sign in again with the password **and** the authenticator code. Fetch a token again: `fva[1]` must now be `>= 0` (for example `[1, 0]`).
5. Repeat on a second test account with **no** second factor: the claim must be the JSON boolean `false` (not missing, not the string `"false"`).
6. Do a **dry run of readiness with the flag on, for this shell only**, on Payroll web. Nothing is changed on Render, because the variables exist only for this one command:

   ```bash
   umask 077
   # put the token from step 4 into a private file, then:
   REQUIRE_MFA=true \
   CLERK_MFA_ATTESTED_INSTANCE_ID=ins_xxxxxxxx \
   CLERK_MFA_EVIDENCE_REF=<non-secret reference> \
   CLERK_MFA_SAMPLE_TOKEN_FILE=/path/to/private-file \
   bundle exec rails production:readiness
   rm -f /path/to/private-file
   ```

   The three MFA lines must say `PASS`. Fetch the token no more than 15 minutes before running (it only has to be correctly signed and recently issued; it does not need to be unexpired). To read the instance ID without printing the key: `curl -s -H "Authorization: Bearer $CLERK_SECRET_KEY" https://api.clerk.com/v1/instance | ruby -rjson -e 'puts JSON.parse(STDIN.read)["id"]'`. Keep tokens out of shell history, logs and retained evidence (cutover runbook line 167).

   This dry run is the only pre-flip proof that the claim reaches the API in the shape it expects. If any line fails, stop and fix the Clerk setting. Do not proceed.

### Step 5: Enrollment window (everyone, before the flip)

Goal: every required user has enrolled and saved backup codes **before** `REQUIRE_MFA=true`. Enrolling early costs a user two minutes. Enrolling after the flip works too, but it happens while they are blocked and the support contact is the only help.

**Where people enroll.** The signed-in Payroll app has no account-settings link. The only in-app route to Clerk's account screen is the prompt shown after the flip (`web/src/pages/Login.tsx:30-62`, which opens Clerk's user profile with `openUserProfile()`). So before the flip, use Clerk's hosted Account Portal: `https://accounts.shimizu-technology.com/user` (the Account Portal host from the cutover records, M3 plan line 748). **Open this URL yourself on the test account during Step 4 and confirm it loads the profile screen with a Security section before you send it to anyone.** If it does not, fall back to the post-flip prompt for everyone and shorten the window, and note it in the evidence log.

Order of enrollment:

1. **Recovery admins first.** Each enrolls, saves backup codes in separate storage (a password manager entry or printed copy kept apart from the phone), signs out, signs back in with the authenticator code, and confirms `fva[1] >= 0` as in Step 4. Each then removes and re-adds their own factor once (or has the other admin reset it, §3.3) to prove recovery works. This is the acceptance row "Recovery administrator signs in with MFA" (cutover runbook lines 135-136).
2. **Cornerstone staff.**
3. **Client users** (for example the active client's admins). Send the notice and offer a 10-minute call.
4. **Dual-role users.** They are required, even if they mainly use the employee site. Treat them as staff.
5. Track a simple table by role: invited, enrolled, signed in with second factor. Clerk shows each user's enrolled methods under **Users → the user → Two step verifications**.

**Go/no-go for the flip:** both recovery admins verified, plus every staff user who runs payroll. Client users who have not enrolled are not a blocker; they enroll at first sign-in after the flip, with support on call. Anyone without a smartphone is a blocker for that person only. They can use a desktop authenticator, such as a password manager's one-time-code feature, or wait for support.

### Step 6: Flip `REQUIRE_MFA=true` on Render web and worker (owner)

In the Render dashboard, for **Payroll web** and **Payroll worker** (same values on both):

| Variable | Value |
|---|---|
| `REQUIRE_MFA` | `true` |
| `CLERK_MFA_ATTESTED_INSTANCE_ID` | the production instance ID (`ins_…`) read from Clerk in Step 4 |
| `CLERK_MFA_EVIDENCE_REF` | a non-secret pointer to the access-controlled evidence (for example a folder and date): the dashboard screenshots of Step 3, the Step 4 results and the Step 5 recovery-admin checks |

Notes:

- Cutover runbook lines 116 and 167 define these two values. The evidence ref must be one line and at most 500 bytes.
- Save both services, then **Manual Deploy → Deploy latest commit** (or restart) on both so the new environment is loaded. Render also restarts on an env change; confirm the deploy finishes and `/up` returns 200 with HSTS.
- Do the flip on both services within a few minutes of each other. Web enforces sign-in; the worker needs the same values so a readiness run there agrees.
- The Clerk instance does not change in this rollout, so no JWKS cache clear is needed.

### Step 7: Readiness run (owner or recovery admin)

In a Render shell on Payroll web, with a fresh token from the enrolled test account (as in Step 4 item 6):

```bash
umask 077
# token file as in Step 4
CLERK_MFA_SAMPLE_TOKEN_FILE=/path/to/private-file bundle exec rails production:readiness
rm -f /path/to/private-file
```

Expected: every line `PASS`, including all three MFA lines. If only the 2027 tax-table line still fails, that is the known unrelated failure. Save the final `EVIDENCE {...}` line with the release evidence (it is safe to retain, per `docs/PRODUCTION_READINESS_CHECKLIST.md:36`).

### Step 8: Employee API (when live), same values

On `cornerstone-payroll-employee-api` set the same three variables, redeploy, and re-run readiness there. All four `employee_web:` lines must still pass, and now the MFA lines pass as well (`docs/rollout/M4_EMPLOYEE_PLATFORM_RUNBOOK.md:98-103`). Dual-role users are required there; employee-only users are not. Skip this step if the employee service has not been created yet, and do it as part of creating it.

### Step 9: Verify allowed and denied sessions

Use real browsers (a private window each). Record the result of each row in the evidence location.

| # | Session | Expected |
|---|---|---|
| 1 | Test staff account, enrolled, signed in with password + authenticator | App loads; `GET /api/v1/auth/me` has `mfa_required: true, mfa_verified: true`. |
| 2 | Same account, sign in with a backup code instead of the authenticator | App loads. (Burns that code; regenerate afterwards.) |
| 3 | Test staff account with **no** second factor, signed in | After sign-in, the app shows "Multi-factor authentication required" with **Open account settings**; every other API route returns 403 `mfa_required`; there is one `authentication#mfa_required_denied` audit event. |
| 4 | Row 3 user enrolls from that prompt, signs out, signs in again with the authenticator | App loads. Expect to need the sign-out and sign-in: the existing session was created with `fva[1] = -1` (see §5 gap 3; confirm in the rehearsal whether enrolling alone refreshes it). |
| 5 | Staff account that was signed in before the flip, with a new device email code but no authenticator | Denied (`mfa_required`). The email code is not accepted as a second factor. |
| 6 | A client user, enrolled | Loads on its client subdomain; company scope unchanged. |
| 7 | A client user, not enrolled | Same prompt as row 3, in the app's style. |
| 8 | An employee-only user (or the employee test account) | **Allowed** with only a first factor on `/api/v1/employee/*` and `/auth/me`. No MFA prompt. |
| 9 | A dual-role user with no second factor | Denied on `/api/v1/employee/*` as well as staff routes (`employee_portal/base_controller.rb:9`). |
| 10 | Live updates (WebSocket) for an enrolled user | Connects; for a non-enrolled user the ticket request returns 403 (`cable_ticket_service.rb:10-16`). |
| 11 | A deactivated user | Still refused (`Account inactive` or unbound), unchanged. |

Roll back (§3.4) if rows 1, 2 or 8 fail, or if a recovery admin cannot sign in.

### Step 10: After the flip

- [ ] Watch the support contact for the first day. Check `authentication#mfa_required_denied` events once at the end of the first day; a person denied repeatedly after enrolling is probably still on an old session.
- [ ] Fill in the "Clerk production identity and MFA" row of `docs/OPERATOR_AND_RECOVERY_ACCEPTANCE.md:113` with the date, operator, reviewer and evidence location (no secrets).
- [ ] Add a short line to the production-readiness evidence set noting the date, the commit, and the readiness result.
- [ ] Reset the Step 4 test accounts or keep them documented as test accounts. Do not leave test tokens on disk.

---

## 3. Recovery

### 3.1 Someone lost or replaced their phone

1. **They have backup codes:** sign in with password, choose "Use another method", enter one backup code. Then, in account settings, re-enroll the new phone and **regenerate backup codes** (Security tab; [Clerk MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery)). Each code works once.
2. **They have no backup codes:** a recovery admin resets their two-step sign-in (3.3). They then sign in with the password only, hit the app's "Multi-factor authentication required" prompt, and enroll the new phone.
3. **They are still signed in on another device** (a session with `fva[1]` still fresh): they can add a new authenticator from account settings there before they lose that session.

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

`REQUIRE_MFA` only changes whether the API checks the second factor. It writes nothing to payroll data, and enrolled factors stay in Clerk.

1. Render → Payroll web and worker (and the employee API if set): set `REQUIRE_MFA=false`.
2. Redeploy or restart each. Within a couple of minutes everyone signs in with their first factor again, as before the flip.
3. Leave `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF` in place or clear them; either is safe. Expect the two MFA readiness lines to fail again (the known pre-G3 state).
4. Fix the cause (3.3 for a locked user, Step 2 for a missing claim, Step 3 for strategy settings), then repeat from Step 4.
5. Do not downgrade Clerk Pro or delete the instance during an incident. Cutover runbook lines 174-179 keep the production instance intact for investigation.

Roll back immediately if: a recovery admin cannot sign in; enrolled users are refused (probably a missing or string-typed `two_factor_enabled` claim); or the readiness MFA lines fail after the flip.

---

## 4. Impact by group

| Group | Required? | Before the flip | After the flip | What they do |
|---|---|---|---|---|
| **Cornerstone staff** (super admin, org admin, admin, manager, accountant) | Yes | Enroll authenticator + backup codes in the window. | Sign in with password or Google, then the authenticator code. | Follow the notice. Recovery admins go first. |
| **Current client users** (role client) | Yes | Enroll from the notice. | Same as staff, on their client address. | Notice plus a short call. |
| **Employee-only users** (`employee`, `portal_employee`) | **No** | Nothing. | Nothing. They sign in as now. Later, sensitive changes ask for a fresh first-factor check (password or emailed code), per decision D9. | No action. Do not send them the staff notice. |
| **Dual-role users** (staff or client + an employee link) | **Yes**, on all routes including the employee site | Enroll like staff. | Treated as staff everywhere. | Send them the staff notice. |
| **New invited users** after the flip | Yes | n/a | Must enroll before the first successful bind. | Add one line to invitation emails (§5 gap 5). |

Notes:

- Google sign-in does not skip the second factor for required users. Only users with the claim `two_factor_enabled == true` and a verified second factor pass.
- Practice-company and other special accounts: the policy decides by role only (`mfa_policy.rb:17-23`). A practice or demo login in a staff role is required too. List them in the roster.
- Existing browser sessions are not cut off by the env flip alone, but their next API request returns 403 and the app shows the enrollment prompt.

---

## 5. Gaps in the code that affect this rollout

None of these are fixed in this PR. Severity is for the rollout, not for the product overall.

| # | Gap | Severity | Effect | Suggested follow-up |
|---|---|---|---|---|
| 1 | **No readiness check for the claim before the flip.** The sample-token check returns `true` when `REQUIRE_MFA` is off (`production_readiness.rb:404-405`), so a missing claim is first detected after the flip, by which time every required user is refused. | **High for the rollout** (mitigated by Step 4 dry run) | A skipped Step 2 or 4 locks out all staff and clients until `REQUIRE_MFA=false`. | Let readiness accept an explicit `CHECK_MFA_CLAIM=true`, or run the sample check whenever a token file is supplied, regardless of the flag. |
| 2 | **No in-app account-settings or enrollment entry point while signed in.** `openUserProfile()` appears only in the post-flip prompt (`web/src/pages/Login.tsx:31,55`); there is no user menu link. The Account Portal URL in Step 5 is the stand-in. | **Medium** | The enrollment window depends on a URL outside the app; people will ask where to go. | Add an "Account and security" link in the staff app's user menu that calls `openUserProfile()`. |
| 3 | **Enrolling probably does not refresh the session.** The app's own prompt tells the user to sign out and back in after adding a factor (`Login.tsx:49-52`), and the check needs `fva[1] >= 0`, which Clerk sets when a second factor is used. "Check verification" only re-reads the token. Confirm in the Step 4 rehearsal whether enrolling alone ever clears the prompt; if it does, drop this gap. | **Medium** | A new enrollee is blocked and confused after doing everything right. | Trigger Clerk's second-factor reverification (`useReverification`, `useStepUpRequest.ts`) or sign the user out automatically after enrollment. Reword the prompt to say "sign out, then sign in and enter your code". |
| 4 | **Prompt wording.** "Add a second factor under Security" does not say authenticator app, does not mention backup codes, and gives no support contact (`Login.tsx:47-52`). | **Low–medium** | More support calls. | Rewrite using the notice template's wording; add the support contact. |
| 5 | **Invited users who have not enrolled can't reach the bind step.** The first sign-in is denied before binding (`clerk_authenticatable.rb:56-61`). They see the same prompt. | **Low** | They must enroll first; invitation emails do not say so. | Add a line to invitation emails and the notice. |
| 6 | **`mfa_enrollment_required` is unhandled in the web app.** The step-up path returns it (`recent_verification.rb:33-37`) but no web code reads that code. Step-up has no callers yet, so it is dormant. | **Low now, high once step-up ships** | A step-up call from an unenrolled staff user would show a generic 403 message. | Handle `mfa_enrollment_required` like `mfa_required` before wiring `require_recent_verification!` to any route. |
| 7 | **Readiness checks the attestation, not the provider.** It cannot tell whether TOTP/backup codes are on in Clerk or who has enrolled (`PRODUCTION_READINESS_CHECKLIST.md:38`). Nothing in Payroll shows enrollment status per user. | **Low–medium** | The roster in Step 5 is manual; a "Require MFA" Clerk toggle left on by mistake would not be caught. | Show enrolled/not enrolled in the staff user list from `two_factor_enabled`, and note the Clerk toggle in the evidence checklist. |
| 8 | **Mid-session flip drops unsaved work.** The first 403 swaps the whole app to the login prompt (`AuthContext.tsx:167-173`, `App.tsx:92`). | **Low** | Anyone mid-form loses it. | Procedural: quiet period (Step 1 precondition). |
| 9 | **Two-prompt experience on new devices.** Device Trust's email code and the authenticator code can both appear for staff on a new device; the app ignores the email code for enforcement. | **Low** | Confusing but safe. | Mention in the notice. Revisit after launch. |
| 10 | **AIRE is out of scope.** This runbook covers Payroll only; AIRE uses its own Clerk setup and `REQUIRE_MFA` (cutover runbook lines 24, 118-123). | **Info** | No change to AIRE. | Separate runbook when AIRE is scheduled. |

---

## 6. Evidence to keep (private location, referenced by `CLERK_MFA_EVIDENCE_REF`)

- Clerk plan page showing Pro, and the Multi-factor page showing authenticator and backup codes on, SMS off, **Require multi-factor authentication** off.
- The Customize session token claims page.
- Step 4 results for the enrolled and not-enrolled test accounts (decoded claim values only, no tokens).
- The Step 5 table (counts by role: enrolled, signed in with second factor).
- Final `EVIDENCE {...}` line from Step 7 and the Step 9 result table.
- The recovery-admin exercises (3.3).

## Sources

- Repo: [M3 plan §2.2 and §4.9](../MILESTONE_3_FOUNDATIONS_BUILD_PLAN_2026-11-22.md), [M4 plan G3, D9, M4-1](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md), [identity cutover runbook](../PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md), [operator and recovery acceptance](../OPERATOR_AND_RECOVERY_ACCEPTANCE.md), [production readiness checklist](../PRODUCTION_READINESS_CHECKLIST.md), [M4 employee platform runbook](M4_EMPLOYEE_PLATFORM_RUNBOOK.md).
- Clerk (checked 2026-11-25): [pricing](https://clerk.com/pricing), [sign-up and sign-in options](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options), [MFA recovery](https://clerk.com/docs/guides/secure/mfa-recovery), [customize session tokens](https://clerk.com/docs/guides/sessions/customize-session-tokens), [JWT template shortcodes](https://clerk.com/docs/guides/sessions/jwt-templates), [session tokens (`fva`)](https://clerk.com/docs/guides/sessions/session-tokens), [reverification](https://clerk.com/docs/guides/secure/reverification), [Device Trust](https://clerk.com/docs/guides/protect/device-trust).
- Clerk's docs do not say whether a Device Trust email code writes `fva[1] = 0` for a user with no second factor. M4 plan line 103 records that it does; the API refuses that case regardless (spec `mfa_enforcement_spec.rb:102-109`). Re-check on the development instance in the Step 4 rehearsal.
