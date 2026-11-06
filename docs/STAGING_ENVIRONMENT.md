# Staging environment

This is a restricted rehearsal for Leon and Chels using production-cloned data. It is not a disposable public demo. Use production Rails behavior with the separate staging deployment flag. Do not change company payroll environments to obtain staging containment.

## Environment contract

Names only; supply values privately through the hosting secret manager. Never put connection strings, encryption material, recipient lists, tokens, or fingerprints in Git or an acceptance report.

Before deploying this version, set `DEPLOYMENT_ENV=production` on each existing production Rails service/worker. Existing running processes are unaffected; the next production boot refuses an absent or misspelled flag. Production frontend builds require matching `DEPLOYMENT_ENV=production` and `VITE_DEPLOYMENT_ENV=production`. Staging uses matching staging flags. Nonempty unknown/case/whitespace values and mismatches fail closed. Development/test may omit both flags.

Required containment settings:

- `DEPLOYMENT_ENV`, `RAILS_ENV`, `DATABASE_URL`, `STAGING_DATABASE_HOSTS`, `PRODUCTION_DATABASE_HOSTS`
- `STAGING_STORAGE_ENDPOINT`, `PRODUCTION_STORAGE_ENDPOINT`, `STAGING_STORAGE_ACCOUNT_ID`, `PRODUCTION_STORAGE_ACCOUNT_ID`, `STAGING_STORAGE_REGION`
- `STAGING_STORAGE_BUCKET`, `PRODUCTION_STORAGE_BUCKET`, `STAGING_STORAGE_ACCESS_KEY_SHA256`, `PRODUCTION_STORAGE_ACCESS_KEY_SHA256`
- `CLERK_ISSUER`, `CLERK_JWKS_URL`, `CLERK_SECRET_KEY`, `STAGING_CLERK_ISSUER`, `PRODUCTION_CLERK_ISSUER`, `STAGING_TESTER_BINDINGS`
- `STAGING_INTEGRATION_HOSTS`, `PRODUCTION_INTEGRATION_HOSTS`, `PRODUCTION_FRONTEND_HOSTS`, `STAGING_AIRE_BASE_URL`, `CORNERSTONE_PAYROLL_EVENTS_URL`
- `STAGING_AIRE_FRONTEND_ORIGIN`, `STAGING_PAYROLL_FRONTEND_ORIGIN`, `STAGING_FRONTEND_ORIGIN`, `FRONTEND_URL`, `CORS_ORIGINS`, `STAGING_ACCESS_GATE_ASSERTED`
- `AUTH_ENABLED`, `SECRET_KEY_BASE`, `PRODUCTION_SECRET_KEY_BASE_SHA256`, `STAGING_PAYROLL_SHARED_SECRET`, `PRODUCTION_PAYROLL_SHARED_SECRET_SHA256`

Payroll database/storage/runtime settings:

- `MIGRATION_DATABASE_URL`, `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL`, `CABLE_DATABASE_URL`, `MIGRATION_CACHE_DATABASE_URL`, `MIGRATION_QUEUE_DATABASE_URL`, `MIGRATION_CABLE_DATABASE_URL`
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME`, `R2_BUCKET`, `R2_ENDPOINT`, `ACTIVE_STORAGE_SERVICE`
- `TIME_TRACKING_ALLOWED_HOSTS`, `USE_SOLID_QUEUE`, `SOLID_QUEUE_IN_PUMA`
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`, `RAILS_MASTER_KEY`

Optional shared production credentials (all three settings are required together):

- `STAGING_SHARES_PRODUCTION_CLERK`, `STAGING_SHARES_PRODUCTION_STORAGE`, `STAGING_STORAGE_WRITE_PREFIX`

Optional tester-mail delivery:

- `STAGING_MAIL_ALLOWLIST`, `RESEND_API_KEY`, `STAGING_RESEND_API_KEY_SHA256`, `PRODUCTION_RESEND_API_KEY_SHA256`, `MAILER_FROM_EMAIL`, `RESEND_FROM_EMAIL`, `INVOICE_MAILER_FROM_EMAIL`

Frontend build context and connection:

- `VITE_DEPLOYMENT_ENV`, `VITE_STAGING_SNAPSHOT_AT`, `VITE_STAGING_CODE_SHA`, `VITE_API_URL`, `VITE_CLERK_PUBLISHABLE_KEY`, `VITE_AUTH_ENABLED`
- `VITE_SITE_URL`, `VITE_CLERK_JWT_TEMPLATE`, `VITE_STAGING_AIRE_FRONTEND_ORIGIN`, `VITE_STAGING_PAYROLL_FRONTEND_ORIGIN`

Keep these absent in staging:

- `CST_INGEST_URL`, `CST_API_TOKEN`, `CST_SHARED_SECRET`, `OPENROUTER_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `R2_PUBLIC_URL`
- `VITE_PUBLIC_POSTHOG_KEY`, `VITE_PUBLIC_POSTHOG_ENABLED`, `GOOGLE_MAPS_API_KEY`, `VITE_GOOGLE_MAPS_API_KEY`

The code independently disables analytics, external AI/OCR, geocoding and tax ingestion when the staging flag is set. Supplying an accidental provider key does not enable these operations; copied AI/tax/legacy auth credentials fail boot.

CI production compilation explicitly supplies the matching production flags. Docker builds take both deployment flags and all staging metadata/origins as explicit build arguments; they have no deployment default. The staging image smoke check uses reserved synthetic hosts only. Publishing a usable staging image requires repository variables `STAGING_API_URL`, `STAGING_SNAPSHOT_AT` and `STAGING_AIRE_FRONTEND_ORIGIN`, plus the existing `STAGING_CLERK_PUBLISHABLE_KEY` secret; the workflow uses its full Git SHA. Missing or unsafe values fail the build. Set these privately before the lead publishes/deploys; a successful smoke-image build is not a configured rehearsal environment.

## Assertions and transport behavior

Database host lists are exact endpoint hostnames, including both Neon pooled and direct endpoints. Inventory production-deny endpoints independently. All role/migration URLs and resolved Rails settings reject hostaddr/service/options routing indirection, multi-host lists, sockets and ambiguous database names. Only supported TLS/timeout connection query options are accepted. Unset libpq routing overrides before every staging command: `PGHOST`, `PGHOSTADDR`, `PGPORT`, `PGDATABASE`, `PGSERVICE`, `PGSERVICEFILE`, `PGSYSCONFDIR`, `PGOPTIONS`, `PGTARGETSESSIONATTRS`, `PGLOADBALANCEHOSTS`. Set the target in the explicit URLs instead. The sole exception is the exact, fixed lock/statement/idle-transaction timeout string generated by Payroll `db:safe_prepare`; additional or altered options, including role/search-path settings, remain forbidden. This exception never permits routing overrides. A pre-connect guard rejects unsafe parameters before opening a socket; live checks verify the selected libpq host/address against approved DNS resolution, reject denied literal addresses, and read backend address/port/database identity before mutation. Every clone/readiness task repeats the checks. These checks do not replace independent Neon branch identity verification. No secret values appear in assertion errors.

In the default separate-credentials mode, the bucket name must contain a separate `staging` segment and differ from the production bucket. The configured access-key ID must hash to the approved staging SHA-256 and differ from the production access-key fingerprint. Use a bucket-scoped staging principal, not an account-wide or production credential. This assertion cannot inspect provider IAM; the lead must verify scope privately. Both Active Storage construction/presigning and application transports enforce containment. Old blob service names must resolve only to these staging configurations. Copy needed object bytes into the staging bucket; a database clone does not copy them. Missing objects are an explicit rehearsal limitation. The storage endpoint and account are independent staging assertions, and in the default mode must differ from the declared production endpoint/account. R2 requires its exact account HTTPS authority; S3 requires the explicitly approved regional authority and account assertion. Arbitrary endpoints, HTTP, credentials/query/fragment/paths and ambient SDK endpoint overrides are refused at construction and again before operations. Raw object presigns/direct uploads and framework blob redirect/proxy/disk routes are held in staging; serializers omit unmarked media URLs. Use the marked application download endpoints for supported documents; source images/media remain visibly unavailable. Provider account/IAM scope still requires independent verification.

### Shared production credentials option

Leon may explicitly opt into the existing production Clerk instance and production storage credentials for a production clone. Both sharing flags must be the exact lowercase true value, and the write prefix must be `staging/YYYY-MM-DD/` with a real calendar date and trailing slash. Keep that prefix stable for the rehearsal. Missing, empty, false, misspelled or partial settings refuse staging boot. To restore separate credentials, remove all three settings. Production, development and test deployments do not enable this exception.

In this mode the independently asserted staging issuer, bucket, account, endpoint and access-key fingerprint may equal production's. Their actual configured values must still match the assertions exactly. The configured JWKS URL must still match the issuer. Production's dev-tier Clerk test keys are supported. Bind only Leon and Chels using their existing production subjects; configure still verifies their primary emails with Clerk before clearing copied local Clerk IDs and rebinding testers. Runtime access remains restricted to the exact bound local ID, email and subject. All backend/app-managed Clerk mutations, including invitations and profile changes for testers, are blocked in shared mode. Shared-instance browser sign-in/session effects still apply.

Storage reads may use any cloned key. New keys are generated under the approved prefix before their references are saved. R2 and the app-owned Active Storage S3 service reject uploads, metadata writes and composition destinations outside it. Protected single and prefix deletes return without contacting storage and emit a redacted event, including Rails blob delete, purge, queued purge and replacement cleanup. Cloned DB attachment/document records may be removed in staging; the production object remains. Untracked variants outside the prefix are blocked; tracked derivative blobs receive new prefixed keys. Raw object URLs, presigned/direct uploads and framework delivery routes remain blocked. Supported document downloads still pass through the marked API response. Unsupported export formats remain held.

This option does not change capture-only mail, reminders, AI/tax/geocoding blocks, integration allowlists, database guards, labels, quarantine, readiness, signing keys or the staging shared-secret requirement. Bucket-scoped R2 authority must be verified privately by the operator; this code does not change token permissions or create a bucket. The other setup, clone and refresh steps below still apply. Reusing credentials does not authorize provider-side changes or production data repairs.

### Tester identity

By default, use a separate Clerk development instance with test keys. `STAGING_TESTER_BINDINGS` is a JSON array of explicit `user_id`, `email` and `clerk_subject` records for the named testers (at most two), with unique IDs, emails and subjects. The legacy email-to-subject map is rejected. Configure requires each exact local ID/email pair to exist, rejects a subject already owned by another local row, and reads the approved Clerk instance to prove that subject owns the matching verified primary email before making any binding writes. Provider failure or mismatch holds configuration. Dry-run configuration performs these read-only identity checks too. Preserve local IDs/roles and employee UUIDs. Runtime auth and cable require the exact bound triple and do not auto-provision, email-rebind or profile-sync staging logins. Do not enroll real employees; provider-side verification email/SMS settings remain an operator responsibility.

`STAGING_ACCESS_GATE_ASSERTED` is an explicit operator assertion that all frontend/API/default deployment aliases are protected for these two testers, including public AIRE and Active Storage routes. Set it only after verifying the gate. It is not an access-control implementation. Keep service callbacks behind the independent staging shared-secret guard, with a route that does not require an interactive browser login. CORS and the staging ribbon do not protect cloned PII.

Integration requests require standard-port HTTPS and exact approved staging hosts. Known production hosts and the explicit production-host list are always denied, even if mistakenly allowlisted. Redirects/SDK traffic also encounter the final Net::HTTP guard. Private staging HTTP exceptions are not supported by this production-like profile. Browser account linking uses the explicit staging frontend origins.

Default mail is capture-only with a redacted log event; there is no provider request. The optional exact-address allowlist must be a subset of the named testers. Delivered samples have a `[STAGING]` subject prefix, filtered To/Cc/Bcc/Reply-To, plain-text content without remote HTML resources, and no attachments or caller-supplied headers. Enabling delivery requires a separately asserted staging Resend key. Captures use a `staging-captured` reference and must never be represented as real inbox delivery evidence. Captured invoice schedules are cancelled with an explicit capture event, without delivery records or a sent invoice; optional real test delivery records only the submitted tester recipients. Conventional Action Mailer passes through the same transport.

PDF reports/checks/stubs contain a warning on every page; check samples have a large center watermark. CSV bytes and downloaded filenames are marked. Machine filing/bank formats that cannot safely carry the warning are disabled. ZIP report members are individually marked; unsupported members hold the package. The root ribbon also prints, remains on login/kiosk/personal pages, and displays the snapshot timestamp and code SHA. Frontend metadata and URLs are build-time settings; rebuild after changing them.

## Clone procedure: execution stays stopped

Follow the coordinated pair procedure in the October 24 staging research A7. The lead provisions resources later; this code creates none.

1. Freeze the exact two code SHAs, migration lists, parent identities, shared-secret policy and capture timestamps. Two DB branches are not an atomic distributed snapshot. Pause/drain connected mutations or record/reconcile the snapshot gap. Archive a private baseline and inventory storage separately.
2. Keep every web, worker, scheduler and auth-accessible frontend stopped. Verify the child endpoints and independent staging credentials. Configure containment assertions and new signing/shared secrets before invoking Rails. The clone tasks run from a controlled one-off process, not a web or queue owner.
3. Run `bundle exec rails staging:clone:quarantine` for a read-only count plan. Review privately. Run `APPLY=true bundle exec rails staging:clone:quarantine` once on each clone. This creates `staging_quarantines` inside a transaction, recording source table, ID, old dispatch state and timestamp only. It finishes copied queue jobs, removes copied execution/recurring/runtime registrations and clears/revokes copied authentication material. It holds copied pending dispatch without falsifying success or deleting frozen evidence. Payroll quarantine also manifests pending/failed AIRE verification events, cancels copied invoice mail, disables invoice recurrence/reminders, removes sessions/delegations/cable tickets, revokes finance API tokens and rotates outstanding invitation tokens.
4. Migrate under one controlled owner: `bundle exec rails db:safe_prepare` with verified staging direct migration URLs. Do not use schema-load/reset/seeds against the clone. Preserve a pre-migration snapshot and measure migration locks/time on the restored data. Keep both apps' connected delivery held until the selected pair is ready.
5. Run `bundle exec rails staging:clone:configure` for a dry-run preflight. Then run `APPLY=true bundle exec rails staging:clone:configure`. Payroll rewrites AIRE source base/authorization URLs and encrypted shared secrets, disables other sources, and rebinds tester Clerk IDs. The configure phase clears copied identity/session markers on users and binds only the verified tester triples. The quarantine phase above owns schedule/token cleanup and copied receipt/calendar/correction/tax/bootstrap/verification dispatch suppression.
6. Run `bundle exec rails staging:clone:verify`. Output is counts only, including selected/quarantined candidates and completion. Inspect the private ID manifest through controlled DB access if required; do not publish it. A repeated quarantine skips already-contained clones so newly created staging work survives. Both tasks refuse non-staging or mismatched DB endpoints; separate queue/cache/cable databases are unsupported and rejected by this profile; dry runs create no tables and write no records.
7. Preserve decryptability: Payroll credentials take precedence over environment encryption keys. Use a staging credentials bundle containing only the necessary encryption material, or a verified environment-only source with no conflict. Do not replace encryption keys while retaining ciphertext. AIRE currently has no encrypted app attributes, but production boot still requires the complete key set. Re-encryption/sanitization is a separate sealed operator procedure covering every retained encrypted attribute.
8. Verify tester role/client grants, rotate tester kiosk PINs under the new signing key, and create fresh staging account links/delegations. Do not recover production PINs or rotate immutable employee UUIDs. Installation identity is deliberately preserved for an isolated replay; new endpoints/secrets still distinguish environments. If a separate installation identity is needed, use the supported connection rebind/reconciliation procedure; do not rewrite frozen payloads.
9. Start only the designated queue owners after both apps pass containment. Payroll uses its dedicated worker; AIRE uses Solid Queue in Puma. Run `bundle exec rails staging:readiness` after startup. `production:readiness` selects the staging profile only for the staging deployment flag; production checks remain unchanged. Staging checks containment, completion, DB, migrations, retained encrypted data and a recent worker heartbeat, with the effective Solid Queue adapter and intended execution ownership, and no live Clerk/Resend/storage probes. A liveness `/up` response is not acceptance.
10. Rehearse the accountant's required repairs and connected flow with all output marked. Record actual SHAs, snapshot gap, decryption result, queue restart/retry evidence and Chels's acceptance. Synthetic automated tests do not certify an actual production clone or live provider configuration.

## Refresh

Put staging into maintenance, stop its execution owners, archive acceptance results and the old manifest, and capture a new coordinated pair. Create new child branches rather than silently resetting a running rehearsal. Repeat quarantine, migrations, configuration, private key/decryption checks, PIN/auth/connection setup and readiness. Rebuild the frontends with the new snapshot timestamp and SHAs. Clear old browser/Clerk sessions and tell Chels previous test edits are gone. Give any retained rollback copies a restricted owner and deletion date.

## Teardown

Save non-sensitive acceptance evidence and any separately approved encrypted audit records. Stop only named staging workers/schedulers/web processes. Remove the staging Render services, Netlify sites/aliases, Neon child endpoints/branches, buckets/keys, auth instance and access-gateway rules under the lead's authorization. Expire copied data/dumps on the agreed date. Confirm production parents, services and buckets remain intact and staging billing resources are gone; stopping a web process does not remove DB/storage charges.
