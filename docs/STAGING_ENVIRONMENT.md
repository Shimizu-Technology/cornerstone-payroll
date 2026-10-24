# Staging environment

This is a restricted rehearsal for Leon and Chels using production-cloned data. It is not a disposable public demo. Use production Rails behavior with the separate staging deployment flag. Do not change company payroll environments to obtain staging containment.

## Environment contract

Names only; supply values privately through the hosting secret manager. Never put connection strings, encryption material, recipient lists, tokens, or fingerprints in Git or an acceptance report.

Required containment settings:

- `DEPLOYMENT_ENV`, `RAILS_ENV`, `DATABASE_URL`, `STAGING_DATABASE_HOSTS`, `PRODUCTION_DATABASE_HOSTS`
- `STAGING_STORAGE_BUCKET`, `PRODUCTION_STORAGE_BUCKET`, `STAGING_STORAGE_ACCESS_KEY_SHA256`, `PRODUCTION_STORAGE_ACCESS_KEY_SHA256`
- `CLERK_ISSUER`, `CLERK_JWKS_URL`, `CLERK_SECRET_KEY`, `STAGING_CLERK_ISSUER`, `PRODUCTION_CLERK_ISSUER`, `STAGING_TESTER_BINDINGS`
- `STAGING_INTEGRATION_HOSTS`, `PRODUCTION_INTEGRATION_HOSTS`, `STAGING_AIRE_BASE_URL`, `CORNERSTONE_PAYROLL_EVENTS_URL`
- `STAGING_AIRE_FRONTEND_ORIGIN`, `STAGING_PAYROLL_FRONTEND_ORIGIN`, `STAGING_FRONTEND_ORIGIN`, `FRONTEND_URL`, `CORS_ORIGINS`, `STAGING_ACCESS_GATE_ASSERTED`
- `AUTH_ENABLED`, `SECRET_KEY_BASE`, `PRODUCTION_SECRET_KEY_BASE_SHA256`, `STAGING_PAYROLL_SHARED_SECRET`, `PRODUCTION_PAYROLL_SHARED_SECRET_SHA256`

Payroll database/storage/runtime settings:

- `MIGRATION_DATABASE_URL`, `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL`, `CABLE_DATABASE_URL`, `MIGRATION_CACHE_DATABASE_URL`, `MIGRATION_QUEUE_DATABASE_URL`, `MIGRATION_CABLE_DATABASE_URL`
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME`, `R2_BUCKET`, `R2_ENDPOINT`, `ACTIVE_STORAGE_SERVICE`
- `TIME_TRACKING_ALLOWED_HOSTS`, `USE_SOLID_QUEUE`, `SOLID_QUEUE_IN_PUMA`
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`, `RAILS_MASTER_KEY`

Optional tester-mail delivery:

- `STAGING_MAIL_ALLOWLIST`, `RESEND_API_KEY`, `STAGING_RESEND_API_KEY_SHA256`, `PRODUCTION_RESEND_API_KEY_SHA256`, `MAILER_FROM_EMAIL`, `RESEND_FROM_EMAIL`, `INVOICE_MAILER_FROM_EMAIL`

Frontend build context and connection:

- `VITE_DEPLOYMENT_ENV`, `VITE_STAGING_SNAPSHOT_AT`, `VITE_STAGING_CODE_SHA`, `VITE_API_URL`, `VITE_CLERK_PUBLISHABLE_KEY`, `VITE_AUTH_ENABLED`
- `VITE_SITE_URL`, `VITE_CLERK_JWT_TEMPLATE`

Keep these absent in staging:

- `CST_INGEST_URL`, `CST_API_TOKEN`, `CST_SHARED_SECRET`, `OPENROUTER_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `R2_PUBLIC_URL`
- `VITE_PUBLIC_POSTHOG_KEY`, `VITE_PUBLIC_POSTHOG_ENABLED`, `GOOGLE_MAPS_API_KEY`, `VITE_GOOGLE_MAPS_API_KEY`

The code independently disables analytics, external AI/OCR, geocoding and tax ingestion when the staging flag is set. Supplying an accidental provider key does not enable these operations; copied AI/tax/legacy auth credentials fail boot.

## Assertions and transport behavior

Database host lists are exact endpoint hostnames, including both Neon pooled and direct endpoints where used. Populate the production-deny list from the independently verified parent endpoints. Every configured database role and migration URL is checked; clone tasks additionally check the actual Active Record connection host. No hostname or secret value is included in assertion errors. A production database name may be identical on a Neon child, so the name alone is not an isolation test.

The bucket name must contain a separate `staging` segment and differ from the production bucket. The configured access-key ID must hash to the approved staging SHA-256 and differ from the production access-key fingerprint. Use a bucket-scoped staging principal, not an account-wide or production credential. This assertion cannot inspect provider IAM; the lead must verify scope privately. Both Active Storage construction/presigning and application transports enforce containment. Old blob service names must resolve only to these staging configurations. Copy needed object bytes into the staging bucket; a database clone does not copy them. Missing objects are an explicit rehearsal limitation.

Use a separate Clerk development instance with test keys. `STAGING_TESTER_BINDINGS` is a JSON object mapping the two approved email addresses to their staging Clerk subjects. Each email must match exactly one existing local user before configure can apply. Preserve local IDs, roles, grants and AIRE employee payroll UUIDs. Mandatory/optional auth and cable reject other subjects. Do not enable arbitrary employee enrollment in Clerk. Clerk invitations, revocations and profile mutations are checked at transport. Provider-side verification email/SMS settings remain an operator responsibility; do not enroll real employees.

`STAGING_ACCESS_GATE_ASSERTED` is an explicit operator assertion that all frontend/API/default deployment aliases are protected for these two testers, including public AIRE and Active Storage routes. Set it only after verifying the gate. It is not an access-control implementation. Keep service callbacks behind the independent staging shared-secret guard, with a route that does not require an interactive browser login. CORS and the staging ribbon do not protect cloned PII.

Integration requests require standard-port HTTPS and exact approved staging hosts. Known production hosts and the explicit production-host list are always denied, even if mistakenly allowlisted. Redirects/SDK traffic also encounter the final Net::HTTP guard. Private staging HTTP exceptions are not supported by this production-like profile. Browser account linking uses the explicit staging frontend origins.

Default mail is capture-only with a redacted log event; there is no provider request. The optional exact-address allowlist must be a subset of the named testers. Delivered samples have a `[STAGING]` subject prefix, filtered To/Cc/Bcc/Reply-To, plain-text content without remote HTML resources, and no attachments or caller-supplied headers. Enabling delivery requires a separately asserted staging Resend key. Captures use a `staging-captured` reference and must never be represented as real inbox delivery evidence. Captured invoice schedules are cancelled with an explicit capture event, without delivery records or a sent invoice; optional real test delivery records only the submitted tester recipients. Conventional Action Mailer passes through the same transport.

PDF reports/checks/stubs contain a warning on every page; check samples have a large center watermark. CSV bytes and downloaded filenames are marked. Machine filing/bank formats that cannot safely carry the warning are disabled. ZIP report members are individually marked; unsupported members hold the package. The root ribbon also prints, remains on login/kiosk/personal pages, and displays the snapshot timestamp and code SHA. Frontend metadata and URLs are build-time settings; rebuild after changing them.

## Clone procedure: execution stays stopped

Follow the coordinated pair procedure in the October 24 staging research A7. The lead provisions resources later; this code creates none.

1. Freeze the exact two code SHAs, migration lists, parent identities, shared-secret policy and capture timestamps. Two DB branches are not an atomic distributed snapshot. Pause/drain connected mutations or record/reconcile the snapshot gap. Archive a private baseline and inventory storage separately.
2. Keep every web, worker, scheduler and auth-accessible frontend stopped. Verify the child endpoints and independent staging credentials. Configure containment assertions and new signing/shared secrets before invoking Rails. The clone tasks run from a controlled one-off process, not a web or queue owner.
3. Run `bundle exec rails staging:clone:quarantine` for a read-only count plan. Review privately. Run `APPLY=true bundle exec rails staging:clone:quarantine` once on each clone. This creates `staging_quarantines` inside a transaction, recording source table, ID, old dispatch state and timestamp only. It finishes copied queue jobs, removes copied execution/recurring/runtime registrations and clears/revokes copied authentication material. It holds copied pending dispatch without falsifying success or deleting frozen evidence.
4. Migrate under one controlled owner: `bundle exec rails db:safe_prepare` with verified staging direct migration URLs. Do not use schema-load/reset/seeds against the clone. Preserve a pre-migration snapshot and measure migration locks/time on the restored data. Keep both apps' connected delivery held until the selected pair is ready.
5. Run `bundle exec rails staging:clone:configure` for a dry-run preflight. Then run `APPLY=true bundle exec rails staging:clone:configure`. Payroll rewrites AIRE source base/authorization URLs and encrypted shared secrets, disables other sources, and rebinds tester Clerk IDs. Copied receipt/calendar/correction/tax/bootstrap dispatch IDs remain held; invoice recurrences/reminders are disabled and pending mail schedules cancelled. Sessions/delegations/cable tickets are cleared and finance API tokens revoked.
6. Run `bundle exec rails staging:clone:verify`. Output is counts only, including selected/quarantined candidates and completion. Inspect the private ID manifest through controlled DB access if required; do not publish it. A repeated quarantine skips already-contained clones so newly created staging work survives. Both tasks refuse non-staging or mismatched DB endpoints; separate queue/cache/cable databases are unsupported and rejected by this profile; dry runs create no tables and write no records.
7. Preserve decryptability: Payroll credentials take precedence over environment encryption keys. Use a staging credentials bundle containing only the necessary encryption material, or a verified environment-only source with no conflict. Do not replace encryption keys while retaining ciphertext. AIRE currently has no encrypted app attributes, but production boot still requires the complete key set. Re-encryption/sanitization is a separate sealed operator procedure covering every retained encrypted attribute.
8. Verify tester role/client grants, rotate tester kiosk PINs under the new signing key, and create fresh staging account links/delegations. Do not recover production PINs or rotate immutable employee UUIDs. Installation identity is deliberately preserved for an isolated replay; new endpoints/secrets still distinguish environments. If a separate installation identity is needed, use the supported connection rebind/reconciliation procedure; do not rewrite frozen payloads.
9. Start only the designated queue owners after both apps pass containment. Payroll uses its dedicated worker; AIRE uses Solid Queue in Puma. Run `bundle exec rails staging:readiness` after startup. `production:readiness` selects the staging profile only for the staging deployment flag; production checks remain unchanged. Staging checks containment, completion, DB, migrations, retained encrypted data and a recent worker heartbeat, with the effective Solid Queue adapter and intended execution ownership, and no live Clerk/Resend/storage probes. A liveness `/up` response is not acceptance.
10. Rehearse the accountant's required repairs and connected flow with all output marked. Record actual SHAs, snapshot gap, decryption result, queue restart/retry evidence and Chels's acceptance. Synthetic automated tests do not certify an actual production clone or live provider configuration.

## Refresh

Put staging into maintenance, stop its execution owners, archive acceptance results and the old manifest, and capture a new coordinated pair. Create new child branches rather than silently resetting a running rehearsal. Repeat quarantine/configure/migrations, private key/decryption checks, PIN/auth/connection setup and readiness. Rebuild the frontends with the new snapshot timestamp and SHAs. Clear old browser/Clerk sessions and tell Chels previous test edits are gone. Give any retained rollback copies a restricted owner and deletion date.

## Teardown

Save non-sensitive acceptance evidence and any separately approved encrypted audit records. Stop only named staging workers/schedulers/web processes. Remove the staging Render services, Netlify sites/aliases, Neon child endpoints/branches, buckets/keys, auth instance and access-gateway rules under the lead's authorization. Expire copied data/dumps on the agreed date. Confirm production parents, services and buckets remain intact and staging billing resources are gone; stopping a web process does not remove DB/storage charges.
