# Local production copy

A copy of Cornerstone Payroll on this Mac that runs the production code path (`RAILS_ENV=production`, `DEPLOYMENT_ENV=local`) with its own database, Redis, Clerk development instance and HTTPS hosts. Nothing in it touches production, staging, the shared local Postgres, Resend, R2 or PostHog.

```sh
ops/local-prod/up.sh       # bring it up (safe to rerun; migrates and rebuilds what changed)
ops/local-prod/smoke.sh    # check it end to end
ops/local-prod/down.sh     # stop everything; keeps the data
ops/local-prod/down.sh --purge   # stop and delete all of its data
```

Agents: set `DEV_LIFECYCLE_SESSION=<your session id>` when running `up.sh` and `down.sh`. Up then claims Caddy and the three Rails processes, and down releases them. Postgres and Redis are refused by dev-lifecycle's protected-name rule, so their pid files and `down.sh` cover them.

## What runs

| What | Where | Notes |
|---|---|---|
| Staff site | `https://payroll.cornerstone.localhost:8443` | Built `staff` surface, Netlify `_headers` and `_redirects` translated to Caddy |
| Staff API | `https://api.cornerstone.localhost:8443` → Puma `127.0.0.1:3110` | `APP_PROCESS_ROLE` unset (`all`) |
| Worker | `bin/jobs` | Solid Queue, same database |
| Employee API | `https://employee-api.cornerstone.localhost:8443` → Puma `127.0.0.1:3111` | `employee_web`, pool 3, one Puma process, guard `raise` |
| Employee app | `https://<slug>.cornerstone.localhost:8443` (`harborfinch`, `harborfinch-catering`) | Built `employee` surface |
| PostgreSQL 16 | `127.0.0.1:55432`, its own cluster | Owner `cornerstone_owner` (bypasses RLS, like Neon's owner); runtime role `payroll_app` (no BYPASSRLS) |
| Redis | `127.0.0.1:56379` | Shared rate-limit store for web and employee API |
| Caddy | `:8443`, admin `127.0.0.1:2099` | mkcert certificate for `*.cornerstone.localhost` |

All state lives in `~/.local/share/cornerstone-local-prod` (override with `LOCAL_PROD_HOME`):

- `secrets.env`, `env/*.env` (mode 600);
- `pg/`, `redis/`, `logs/`, `run/` (pid files);
- `certs/`, `mail/` (captured mail, one JSON file per message), `web/`, `Caddyfile`;
- `storage/` (Active Storage and the R2 service's disk objects, through `LOCAL_STORAGE_ROOT`).

Clerk keys are read from `~/.config/shimizu/clerk-payroll-local.env` and are never printed. `clerk_setup.py` changes an instance only if it is a development instance and either:
- its id matches an optional `CLERK_INSTANCE_ID=ins_…` line in that file, or
- it already allows at least one origin, and every one is under `.localhost`.

A brand-new instance with no allowed origins needs the `CLERK_INSTANCE_ID` line.

So a staging or shared test instance is never repointed.

### Safety rails

- **Settings come only from the generated env files.** The API skips `api/.env` when `DEPLOYMENT_ENV=local`. `up.sh` stops if `web/` has a `.env*` file other than `.env.example`.
- **Secrets stay off the command line.** psql reads passwords from `pgpass` (mode 600), and SQL that sets passwords goes in on stdin.
- **Pid files are checked before anything is signalled.** A pid must be a positive integer, and its process's command line must match the service (Puma on its own port, `bin/jobs`, this Caddyfile, Redis on 56379, Postgres on this data directory). Anything else is reported and left alone.
- **Ports are checked before each start.** If something else already listens on a port the mirror needs, `up.sh` stops.
- **The data directory must be the mirror's own.** `LOCAL_PROD_HOME` is normalised (no trailing slash, real parent directory). It must not be a symlink, and its marker must not be one. It must not be a shared or top-level directory (`/`, `/Users`, `/tmp`, `$TMPDIR`, `$HOME`, `~/.local`, `~/.local/share`, `~/.config`, `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Library`), nor a directory containing this repo.
- **`up.sh` never adopts an existing directory.** It uses a missing or empty directory, or one already carrying the `.cornerstone-local-prod` marker.
- **`down.sh --purge` deletes only a marked directory.** It checks that directory the same way, and nothing may still be using it: no live mirror service, no process naming the directory, nothing on the mirror's ports.

### Database and RLS

`up.sh` follows the RLS runbook:
- `db:safe_prepare` on the owner connection;
- idempotent loading of `db/cache_schema.rb`, `db/queue_schema.rb` and `db/cable_schema.rb` into their configured databases when their tables are not yet present (`solid_cache_entries`, `solid_queue_jobs`, `solid_cable_messages`);
- `db/rls_runtime_role.sql` (with the interactive `\password` replaced by a generated password);
- `rls:install` (shadow), then the seed;
- `rls:enforce` (all protected tables enabled and forced).

| | Shadow (`LOCAL_PROD_RLS_PHASE=shadow`) | Enforced (default) |
|---|---|---|
| Staff web, worker guard | `log` | `raise`, `RLS_EXPECT_ENFORCED=true` |
| Employee API guard | `raise` | `raise`, `RLS_EXPECT_ENFORCED=true` |

Every app process gets complete URLs: `DATABASE_URL` (owner; cache, queue and cable pools) and `RLS_DATABASE_URL` (`payroll_app`; the primary pool). `MIGRATION_DATABASE_URL` is given only to owner maintenance commands. Local mode refuses `PG*` routing variables, so none are exported.

`up.sh` never un-enforces a database. Asked for shadow on an enforced database, it stops with a message. To run in shadow, start from fresh data (`down.sh --purge`, then `LOCAL_PROD_RLS_PHASE=shadow up.sh`), or run `rls:disable` first.

To rehearse a rollback, run any `rls:*` task with the maintenance environment:

```sh
cd api && bash -c 'set -a; . ~/.local/share/cornerstone-local-prod/env/maint.env; set +a; bundle exec rails rls:status'
```

### Data

The first `up.sh` seeds:
- the tax tables and consent wording (`db:seed`);
- a fictional organization ("Cornerstone Payroll Local") with one super admin (`payroll.admin+clerk_test@example.com`);
- the Harbor Finch demo employers (`DemoCompany::Seed`);
- the draft Employee App Terms.

The employee app switch, subdomains and invitations stay off. Turn them on in the app, as staff would in production.

### Signing in

- **Staff:** `payroll.admin+clerk_test@example.com`. The password is `LP_STAFF_PASSWORD` in `secrets.env`.
- **Other `+clerk_test` addresses:** use email code `424242`.
- **Demo allow-list (`DEMO_EMAIL_ALLOWLIST`):** `up.sh` sets a safe fictional default list (`demo.client+clerk_test@example.com,demo.employee+clerk_test@example.com,demo.manager+clerk_test@example.com,demo.viewer+clerk_test@example.com`) so demo client logins and demo employee invitations can be tested. Override with `LOCAL_PROD_DEMO_EMAIL_ALLOWLIST='...'` before running `up.sh`.
- **Sign in as (`VIEW_AS_READY`):** `up.sh` sets `VIEW_AS_READY=true` by default (override with `LOCAL_PROD_VIEW_AS_READY=false`) so super admins granted `users.view_as_allowed=true` can test view-only support sessions.
- **Sessions:** Clerk keeps them per host, so the staff site and each employee address sign in separately.

## Trusting the certificate (once per Mac)

Servers and the smoke check trust mkcert's root through `certs/ca-bundle.pem`. A browser on this Mac needs it in the keychain, once:

```sh
mkcert -install
```

It asks for the Mac's login password at `Password:` in Terminal (this is `sudo`, to add the root to the System keychain). macOS may then show a dialog asking to change certificate trust settings: enter the same password and click **Update Settings**. Undo it with `mkcert -uninstall`.

## Known differences from production

- **Two-step sign-in is off** (`REQUIRE_MFA=false`). The Clerk development instance has no authenticator app or backup codes turned on, and the Backend API can't change that. So the switch page's MFA check shows *waived*, as in production before the MFA rollout. To turn it on, enable Authenticator app (and the `two_factor_enabled` session-token claim) for "Cornerstone Payroll Local" in the Clerk dashboard. Then run `up.sh` with `LOCAL_PROD_REQUIRE_MFA=true`, and add `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF` to `up.sh`'s common environment for the readiness check. With it on and no second factor available, every sign-in (staff, client and employee) stops at two-step setup, which is how the gate itself can be checked.
- **`production:readiness` fails these lines on purpose:**
  - "this is a hosted deployment, not a local production copy";
  - live Clerk keys (`pk_live_`);
  - R2 as the storage service, and Resend credentials;
  - the R2 and Resend live probes.
- **Mail is captured, not sent.** Each message is a JSON file in `mail/`, including invite links.
- **External services are refused:** OpenRouter (AI intake), Resend, R2, AIRE and time-tracking hosts. Outbound traffic is allowed only to loopback and Clerk.
- **Port 8443 appears in every URL.** Port 443 on this Mac belongs to Tailscale.
