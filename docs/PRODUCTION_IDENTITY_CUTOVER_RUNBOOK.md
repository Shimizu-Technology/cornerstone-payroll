# Cornerstone and AIRE production identity cutover

Last reviewed: `2026-09-14T14:32:45+10:00`

This runbook moves Cornerstone Payroll and AIRE from Clerk development identities to separate production identity environments without performing a production payroll. It is the operating procedure for the identity control in [Payroll operator and recovery acceptance](OPERATOR_AND_RECOVERY_ACCEPTANCE.md); it does not replace the production-readiness gate or authorize a live payroll.

## Verified starting point

The following state was observed through provider consoles and safe deployed checks on September 14, 2026. Recheck it at the start of the maintenance window because provider state can change independently of this repository.

### Cornerstone Payroll

- The application still uses Clerk development keys in production. The deployed readiness gate passes 24 of 26 controls and fails only production Clerk keys and MFA attestation.
- A separate, unused Clerk production instance has been created for `payroll.shimizu-technology.com`. It is in invite-only mode. No production identity invitations have been sent and no application keys have been changed.
- The staged instance allows verified email-code sign-up and sign-in. Password sign-up and sign-in are enabled with an eight-character minimum and compromised-password rejection. Phone, username, passkeys, mobile biometrics, and Web3 sign-in are off.
- The development instance uses Google social sign-in through Clerk shared credentials. The production Google connection exists but reports `Setup required`; production requires custom Google OAuth credentials.
- Development and staged-production session settings match: seven-day maximum lifetime, ten-minute reverification window, no inactivity timeout, and no multi-session handling. Clerk Organizations are disabled; Cornerstone's company and role boundaries remain application-owned.
- The earlier inventory found 15 development Clerk users. Re-inventory immediately before cutover; do not use this count as the migration source of truth.

### AIRE

- AIRE still uses a Clerk development instance in production. The deployed readiness gate passes 21 of 23 controls and fails only production Clerk identity and MFA attestation.
- No AIRE Clerk production instance exists. Clerk rejected the `aire-services-guam.netlify.app` hostname because a `netlify.app` domain cannot be used for a production application.
- `aireservicesguam.com` is the public Wix site. `app.aireservicesguam.com` was unassigned when inspected and is the proposed application hostname.
- The Netlify account has an overdue $20 invoice. The dashboard currently blocks the custom-domain work needed for the AIRE production identity setup.
- The development instance uses the same verified email-code and password settings as Cornerstone and also uses Google social sign-in through Clerk shared credentials. A production AIRE instance will require its own Google OAuth credentials if Google sign-in is retained.
- The AIRE Netlify production environment does not define `VITE_CLERK_JWT_TEMPLATE`; the deployed frontend requests Clerk's default session token.
- The earlier inventory found 34 development Clerk users. Re-inventory immediately before cutover; do not use this count as the migration source of truth.

## Decisions and authority required

Record each decision before changing a domain, subscription, user, or live key. Payment, subscription, invitation, and DNS changes require an explicitly authorized operator at action time.

| Decision | Recommended value | Recorded decision |
| --- | --- | --- |
| Netlify overdue invoice | Pay the $20 invoice, then verify the account is unrestricted | Pending |
| AIRE application hostname | `app.aireservicesguam.com` | Pending |
| Clerk plan | Pro, billed monthly initially unless the owner explicitly prefers annual billing | Pending |
| Cornerstone recovery administrators | Two named, active Cornerstone administrators | Pending |
| AIRE recovery administrators | Two named, active AIRE administrators, including the regular payroll operator | Pending |
| Cornerstone Google sign-in | Preserve it with production Google OAuth credentials for the least disruptive cutover | Pending |
| AIRE Google sign-in | Preserve it with production Google OAuth credentials for the least disruptive cutover | Pending |
| Password sign-in | Prefer Google plus email code and disable passwords; if retained, approve a stronger production password policy before invitations | Pending |
| Maintenance window | A time when Cornerstone and AIRE operators are signed out and available to verify recovery | Pending |
| Release operator and reviewer | Two different named people | Pending |
| Rollback deadline | A precise ChST date and time after successful verification | Pending |

## No-lockout preconditions

Do not begin the live key switch until every item below is true.

- [ ] Netlify billing is current and `app.aireservicesguam.com` is attached to the AIRE site with valid TLS.
- [ ] Separate production Clerk instances exist for Cornerstone and AIRE, and their application domains show verified.
- [ ] Both instances are invite-only and reproduce the approved email, password, session, invitation, and organization policies.
- [ ] Each Google connection is either configured with production OAuth credentials and tested, or its removal has explicit written approval and affected users have a tested alternative.
- [ ] Password sign-in is disabled or has an explicitly approved production policy. Do not silently preserve the current eight-character minimum with minimum-strength enforcement off.
- [ ] Clerk Pro is active and the approved MFA strategy is enabled in both production instances.
- [ ] Two recovery administrators per application have enrolled MFA, stored backup codes separately, signed out, signed back in, and completed a recovery exercise.
- [ ] Current development Clerk users and active application users have been reconciled by verified primary email. Disabled and cross-company accounts are called out explicitly.
- [ ] Every intended production user has a migration or invitation disposition. No invitation is sent from an unattended script.
- [ ] The current frontend and backend key values are retained in an access-controlled rollback record. Store values only in the approved secret manager, never in this repository or a ticket.
- [ ] The Netlify and Render environment-variable changes are prepared, but not saved, for both applications.
- [ ] The release operator, independent reviewer, maintenance window, rollback deadline, and test accounts are present.

## Provider preparation

### 1. Restore and verify Netlify account access

1. An authorized person pays or resolves the overdue invoice.
2. Confirm the Netlify dashboard is unrestricted and the AIRE site remains published.
3. Add `app.aireservicesguam.com` to the AIRE Netlify site.
4. Add only the DNS record Netlify specifies. Do not move the Wix apex domain or replace its nameservers.
5. Wait for Netlify TLS to become active, then prove HTTP redirects to HTTPS and HTTPS returns the AIRE application with HSTS.

### 2. Finish the Clerk production instances

For each application:

1. Verify the exact application hostname before accepting Clerk's DNS records.
2. Use a secondary-application domain so Clerk does not claim the shared `shimizu-technology.com` or `aireservicesguam.com` apex identity domain.
3. Keep access mode invite-only.
4. Reproduce the approved user-authentication and session settings.
5. Keep Clerk Organizations disabled unless the application is deliberately migrated to Clerk-managed tenancy in a separate reviewed change. Both applications currently enforce tenancy and roles in their own databases.
6. Enable the selected MFA strategy. Authenticator applications plus recovery codes are the baseline for privileged users.
7. Do not set application `REQUIRE_MFA=true` yet; it is an attestation that comes after provider-side enforcement and recovery have been proved.

For Google sign-in in each application where it is retained:

1. Create or select a production Google OAuth web client owned by Shimizu Technology.
2. Use the exact authorized origin and redirect URI shown by the verified Clerk production connection. Do not copy the development `clerk.shared.lcl.dev` callback.
3. Store the client secret only in Google and Clerk.
4. Test Google sign-in with a designated non-payroll test identity before inviting the complete user inventory.

### 3. Prepare identities

1. Export or inspect the complete development Clerk user inventory and the active application-user inventory without placing PII in source control.
2. Reconcile by Clerk's verified primary email, not by display name or the first email address.
3. Give every active user one disposition: migrate, invite/recreate, intentionally deactivate, or investigate. A blank disposition is a no-go.
4. Invite or migrate the two recovery administrators first. Confirm that each links to the intended existing application user and receives the expected local role and company access.
5. Enroll and recover both administrators before preparing the remaining users.
6. Prepare the remaining invitations or migration in controlled batches. Confirm delivery and ownership; do not send them merely to make the provider user count match.

## Coordinated application switch

The frontend and backend cannot accept different Clerk environments as a steady state. Treat the following as one maintenance-window release. Do not process payroll or edit time during the window.

### Cornerstone

- Netlify: replace `VITE_CLERK_PUBLISHABLE_KEY` with the production publishable key and publish the prepared frontend deploy.
- Render web and worker: replace `CLERK_PUBLISHABLE_KEY` and `CLERK_SECRET_KEY` together. If `CLERK_INSTANCE_ID`, `CLERK_ISSUER`, `CLERK_API_BASE`, or `CLERK_AUDIENCE` are explicitly configured, update or remove stale development values as required by the production instance.
- Deploy the web and worker from the same approved Cornerstone revision.

### AIRE

- Netlify: replace `VITE_CLERK_PUBLISHABLE_KEY` with the AIRE production publishable key. Leave `VITE_CLERK_JWT_TEMPLATE` unset unless a separate reviewed change deliberately introduces and verifies a matching production template.
- Render: replace `CLERK_SECRET_KEY`, `CLERK_JWKS_URL`, and any explicit `CLERK_ISSUER` or `CLERK_AUDIENCE` values as one prepared change.
- Deploy from the same approved AIRE revision used by the readiness evidence.

After both sides of an application are live, verify identity behavior before moving to the next application. Never paste keys into a command whose output will be retained.

## Verification matrix

Use non-payroll actions wherever possible. Record result, timestamp in ChST, operator, reviewer, deployed revision, and a redacted evidence location.

| Test | Cornerstone | AIRE |
| --- | --- | --- |
| Signed-out protected route redirects to sign-in | Pending | Pending |
| Recovery administrator signs in with MFA | Pending | Pending |
| Second recovery administrator signs in and completes recovery | Pending | Pending |
| Email-code sign-in works | Pending | Pending |
| Google sign-in works, if retained | Pending | Pending |
| Active staff account receives the correct local role | Pending | Pending |
| Client or ordinary employee cannot enter an admin route | Pending | Pending |
| Inactive local user is rejected despite a valid Clerk identity | Pending | Pending |
| Cross-company or cross-organization URL/API access is rejected | Pending | Pending |
| Existing browser session fails safely after the issuer change | Pending | Pending |
| New session can call the authenticated API | Pending | Pending |
| WebSocket/Cable authentication works where applicable | Pending | Pending |
| Public health endpoint remains healthy with HSTS | Pending | Pending |

Only after the matrix passes:

1. set `REQUIRE_MFA=true` in the relevant backend environment;
2. deploy the attestation change;
3. run the complete deployed `production:readiness` task;
4. require Cornerstone to pass 26 of 26 and AIRE to pass 23 of 23; and
5. keep production payroll paused until operator and recovery acceptance is complete.

## Rollback

Rollback immediately if both recovery administrators cannot sign in, a valid local user maps to the wrong record, inactive or cross-company access succeeds, frontend and backend issuers disagree, or either readiness gate regresses outside the planned MFA/key transition.

1. Stop further invitations and user changes.
2. Restore the prior frontend publishable key and republish the last known-good frontend deploy.
3. Restore the prior backend Clerk values from the access-controlled rollback record and redeploy the matching web/worker revision.
4. Remove or reset `REQUIRE_MFA` only if the previous provider environment did not enforce MFA; record why the attestation changed.
5. Confirm the prior recovery administrator can sign in and the authenticated API responds.
6. Record the failure, affected identities, exact rollback time, and corrective owner without including tokens or secret values.
7. Keep the new production Clerk instances intact for investigation unless the incident owner explicitly authorizes deletion.

## Acceptance record

| Field | Value |
| --- | --- |
| Maintenance window in ChST | |
| Cornerstone revision | |
| AIRE revision | |
| Release operator | |
| Independent reviewer | |
| Cornerstone recovery administrators | |
| AIRE recovery administrators | |
| Rollback deadline in ChST | |
| User-inventory evidence | |
| MFA enrollment/recovery evidence | |
| Verification-matrix evidence | |
| Cornerstone readiness result | |
| AIRE readiness result | |
| Rollback required | Yes / No |
| Final disposition | Go / No-go |

Any missing decision, unreconciled identity, untested recovery path, failed verification row, or incomplete readiness gate is a no-go. The cutover closes identity readiness only; the remaining database, document, queue, monitoring, Chels operator, MoSa parallel-cycle, and AIRE shadow/live-cycle controls remain separate requirements.
