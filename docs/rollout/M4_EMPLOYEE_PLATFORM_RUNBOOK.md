# Employee site and service: setup runbook (M4-10)

**Who does this:** Leon or the lead, with Render, Netlify, Cloudflare and Clerk logins.
**When:** after Clerk production is live (M3-0b). Plan: [M4-10](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md), gate G5.
**What it sets up:** one new Render service (the employee API), one new Netlify site (the employee website), and two employee addresses: `mosas.shimizu-technology.com` and one for Cornerstone's own test sign-ups.

Nothing here is switched on for employees. Every step is safe to do before M4-9 opens the switch. No staging this milestone.

Each step has a ✅ check. Do the check before the next step. If a check fails, stop and look at **Rollback** at the bottom.

## 0. Before you start

- [ ] The PR that added this runbook is merged and the Payroll API, worker and site have deployed from `main`.
- [ ] Clerk production is live and `pk_live_` / `sk_live_` keys are on the Payroll API (M3-0b).
- [ ] You know the **shared Redis (Valkey) URL** that Payroll web uses for rate limits (`RACK_ATTACK_REDIS_URL`). If Payroll web has none, stop and ask: see Open questions.
- [ ] You can open a shell on the Payroll API service in Render.
- [ ] Neon check, once. In a Render shell on Payroll web:
  `bundle exec rails runner 'puts ActiveRecord::Base.connection.select_value("SHOW max_connections")'`
  Write the number down. Part 1 uses it.

Names used below. Change them only if the name is taken.

| Thing | Value |
|---|---|
| Render service | `cornerstone-payroll-employee-api` |
| Employee API URL | `https://cornerstone-payroll-employee-api.onrender.com` |
| Netlify site | `cornerstone-payroll-employee` |
| Employee site URL | `https://cornerstone-payroll-employee.netlify.app` |
| MoSa's address | `mosas.shimizu-technology.com` (company 6) |
| Team test address | `cornerstone.shimizu-technology.com` (company 1) |

If Render adds a suffix to the service URL, use the URL it shows everywhere below.

## 1. Render: the employee API service

The values are also in [`ops/render/employee-web.render.yaml`](../../ops/render/employee-web.render.yaml). That file is not applied by anything. Enter the values by hand.

### 1.1 Create it

Render → New → Web Service → the `cornerstone-payroll` repo.

| Field | Value |
|---|---|
| Name | `cornerstone-payroll-employee-api` |
| Region | Singapore (same as the database) |
| Branch | `main` |
| Root directory | `api` |
| Language | Ruby |
| Build command, Start command | Copy from the Payroll API web service (Settings → Build & Deploy) |
| Instance type | **Starter** ($7 a month) |
| Health check path | `/up` |
| Pre-deploy command | **Leave empty.** Payroll web migrates. This service never does. |
| Build filter | Include `api/**` only |

### 1.2 Environment variables

Copy every variable from the Payroll API web service, **except** `MIGRATION_DATABASE_URL` (do not copy that one). Then set these on the new service:

| Variable | Value |
|---|---|
| `APP_PROCESS_ROLE` | `employee_web` |
| `DB_POOL_MAX` | `3` |
| `RAILS_MAX_THREADS` | `3` |
| `WEB_CONCURRENCY` | `1` |
| `SOLID_QUEUE_IN_PUMA` | `false` |
| `RACK_ATTACK_REDIS_URL` | The same shared Redis URL as Payroll web (use the internal URL) |

The full name list is in the YAML file. The three `ACTIVE_RECORD_ENCRYPTION_*` values must match Payroll web exactly. If Payroll web has none of them, it reads them from Rails credentials. In that case `RAILS_MASTER_KEY` is enough.

Don't change anything on the Payroll services.

### 1.3 Check it

Wait for the first deploy to go live, then:

```bash
API=https://cornerstone-payroll-employee-api.onrender.com
curl -si $API/up | head -1                                    # HTTP/2 200
curl -s  $API/health/dependencies                             # {"status":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' $API/api/v1/admin/companies   # 404
curl -s -o /dev/null -w '%{http_code}\n' $API/cable                    # 404
curl -si $API/up | grep -i strict-transport                   # present
```

Then in a Render shell on the **employee** service:

```bash
bundle exec rails production:readiness
```

✅ Every line says PASS, including these four (and `shared rate-limit store accepts a write and delete round trip`, which proves Redis is reachable):

- `employee_web: process role booted as employee_web without payroll routes or Cable`
- `employee_web: database pool is capped at 3, matches DB_POOL_MAX and runs one Puma process` (also needs `WEB_CONCURRENCY` of 1 or less and `SOLID_QUEUE_IN_PUMA` off)
- `employee_web: rate-limit counters use the shared Redis store`
- `employee_web: Clerk authorized parties are explicit production HTTPS origins`

**Before Clerk Pro and `REQUIRE_MFA=true` (gate G3), two MFA lines are expected to FAIL.** Nothing else may fail, and all four `employee_web:` lines must pass:

- `MFA enforcement has instance-bound evidence` (needs `REQUIRE_MFA=true` plus `CLERK_MFA_ATTESTED_INSTANCE_ID` and `CLERK_MFA_EVIDENCE_REF`)
- `Clerk Backend API accepts the configured key and matches MFA evidence` (fails while `CLERK_MFA_ATTESTED_INSTANCE_ID` is empty or differs from the Clerk instance id)

The command ends with `Production readiness failed`, so judge the list by line, not by the exit code. After G3 sets the MFA values, every line passes.

`/up` doesn't touch the database, so a database problem won't restart the service. `/health/dependencies` does check the database. Use it for monitors, not as the Render health check.

### 1.4 Neon connection budget

Only the **primary** pool uses Neon's direct endpoint (`RLS_DATABASE_URL`). The cache, queue and cable pools use the pooled endpoint (`DATABASE_URL`), which shares connections.

`DB_POOL_MAX` is a limit **per pool, per process**.

| Service | Direct connections (primary pool) | Pooled connections |
|---|---|---|
| Payroll web | up to 5 (pool is `DB_POOL_MAX`, or `RAILS_MAX_THREADS`, or 5) | up to 5 per pool |
| Payroll worker | up to 5 per worker process, 2 processes: up to 10 | up to 5 per pool, per process |
| **Employee web** | **3** | up to 3 per pool (cable pool stays idle) |
| Migrations, console, readiness runs | about 3 at a time | |

Direct total, worst case: 5 + 10 + 3 + 3 = **about 21**. The M3 plan estimated 25–35 at peak.

Rule: the direct total must stay under **half** of the `max_connections` number from step 0. Neon's plan said 100 or more on the small compute sizes, so there's room. If the number you wrote down is under 50, stop and ask before going on.

The employee service adds 3 direct connections. It doesn't change how many Payroll uses. To lower it later, set `DB_POOL_MAX=2` (the readiness check allows 1 to 3). The Payroll rows are estimates from the defaults in `api/config/database.yml` and `puma.rb`. Check them against the real variables on the Payroll services.

## 2. Netlify: site 2 (employee website)

### 2.1 Create it

Netlify → Add new site → Import from Git → `cornerstone-payroll`.

| Field | Value |
|---|---|
| Site name | `cornerstone-payroll-employee` |
| Branch | `main` |
| Base directory | `web` |
| Build command, Publish directory | Leave as shown. `web/netlify.toml` sets `npm run build` and `dist`. |

Both Netlify sites read the same `web/netlify.toml`. What makes this one the employee site is the environment variable below.

### 2.2 Environment variables (Site configuration → Environment variables)

| Variable | Value |
|---|---|
| `VITE_APP_SURFACE` | `employee` |
| `VITE_API_URL` | `https://cornerstone-payroll-employee-api.onrender.com/api/v1` |
| `VITE_CLERK_PUBLISHABLE_KEY` | The production `pk_live_` key |
| `VITE_AUTH_ENABLED` | `true` |
| `DEPLOYMENT_ENV` and `VITE_DEPLOYMENT_ENV` | `production` (both) |

The build **fails on purpose** if `VITE_API_URL` or the Clerk key is missing. It writes them into the site's Content-Security-Policy. If you change either later, redeploy.

### 2.3 Turn off extras (Site configuration → Build & deploy → Continuous deployment)

- [ ] Deploy previews: **off** (Don't deploy pull requests).
- [ ] Branch deploys: **None**.
- [ ] Production branch: `main` only.

The ignore script also skips every non-production build on this site. And it skips docs-only and API-only merges on **both** sites. Test it any time with `bash web/scripts/test-netlify-ignore-build.sh`.

### 2.4 Check the first deploy

The first deploy costs about 15 credits. Trigger it from the Deploys page.

```bash
curl -sI https://cornerstone-payroll-employee.netlify.app/ | grep -iE 'HTTP/|cache-control|content-security|strict-transport|x-frame|x-content-type|referrer|x-robots'
```

✅ You see all of these:

- `cache-control: no-store`
- a `content-security-policy` that lists the employee API URL and `clerk.shimizu-technology.com`
- `x-frame-options: DENY`, `x-content-type-options: nosniff`, `referrer-policy: no-referrer`, `x-robots-tag: noindex, nofollow`

```bash
curl -s https://cornerstone-payroll-employee.netlify.app/robots.txt        # Disallow: /
curl -s -o /dev/null -w '%{http_code}\n' https://cornerstone-payroll-employee.netlify.app/some/deep/link   # 200 (app shell)
```

Today the page itself is the "Employee portal coming soon" placeholder. The real app is M4-8.

Caching note: the whole site is `no-store`, including the JavaScript files. That's the safe choice for pay data. The employee bundle is about 137 KB compressed, so a phone re-downloads it on each visit. Not worth changing now.

## 3. Add an employee address (do this twice)

Do **MoSa's** first, then the **team test address**. Steps follow [`CLIENT_SUBDOMAIN_ACTIVATION.md`](../CLIENT_SUBDOMAIN_ACTIVATION.md).

| | MoSa's | Team test |
|---|---|---|
| Company | 6 | 1 |
| Slug | `mosas` | `cornerstone` |
| Address | `mosas.shimizu-technology.com` | `cornerstone.shimizu-technology.com` |

### 3.1 Slug and branding (Render shell on Payroll web)

Check the company first. It must be a **live** company, and its `name` is shown publicly:

```ruby
c = Company.find(6)   # use 1 for the team address
puts [c.name, c.payroll_environment, c.subdomain_slug.inspect, c.branding.inspect].join(" | ")
```

Then set the slug and branding. The logo must be a public HTTPS image URL with no query string. Colors are six-digit hex. Skip `branding` for now if you have no logo yet.

```ruby
TenantScope.as_system(reason: "M4-10 employee address") do
  Company.find(6).update!(
    subdomain_slug: "mosas",
    branding: { "logo_url" => "https://…", "primary_color" => "#1d5fd2", "accent_color" => "#0f766e" }
  )
end
```

✅ The call returns `true`. An error means a rule failed (reserved slug, not live, profile already enabled). Fix it, don't work around it.

**Leave `subdomain_enabled` off.** M4-9 turns it on, with the other checks.

### 3.2 Netlify alias

Site 2 → Domain management → Add a domain alias → the address.

If the address is already an alias on the **Payroll** site, remove it there first.

### 3.3 Cloudflare DNS

Add a CNAME: name `mosas` (or `cornerstone`), target `cornerstone-payroll-employee.netlify.app`, proxy **DNS only** (grey cloud). Don't add a wildcard record.

### 3.4 Clerk

Clerk dashboard (production) → Domains → Allowed subdomains → add the exact address. Keep `payroll.shimizu-technology.com` on the list.

### 3.5 Smoke check

Wait until Netlify shows the certificate as issued (a few minutes).

```bash
HOST=mosas.shimizu-technology.com
API=https://cornerstone-payroll-employee-api.onrender.com

# TLS: certificate is valid for the host
curl -sv https://$HOST/ -o /dev/null 2>&1 | grep -E 'subject:|expire date|SSL certificate verify ok'

# Headers: same list as step 2.4
curl -sI https://$HOST/ | grep -iE 'HTTP/|cache-control|content-security|strict-transport|x-frame|x-robots'

# Branding and CORS (limit: 30 a minute per IP, so run this block once)
curl -si "$API/api/v1/public/tenant_branding?host=$HOST" -H "Origin: https://$HOST"
curl -si -X OPTIONS "$API/api/v1/public/tenant_branding?host=$HOST" \
  -H "Origin: https://$HOST" -H "Access-Control-Request-Method: GET"
curl -si "$API/api/v1/public/tenant_branding?host=other-client.shimizu-technology.com" \
  -H "Origin: https://other-client.shimizu-technology.com" | head -3

# Credentialed CORS (sign-in calls): preflight for the auth endpoint
curl -si -X OPTIONS "$API/api/v1/auth/me" \
  -H "Origin: https://$HOST" -H "Access-Control-Request-Method: GET" -H "Access-Control-Request-Headers: authorization"
```

Expected, **while `subdomain_enabled` is still off** (the state before M4-9):

- TLS valid, headers present.
- Branding: `404`. The branding preflight has **no** `access-control-allow-origin`. The unknown client also gets `404` and no CORS header.

Expected **after M4-9 turns the company on** (re-run the same block, wait 45 seconds after the switch):

- Branding: `200` with `{"name":…,"logo_url":…,"primary_color":…,"accent_color":…}` for **this** company only.
- The branding preflight has `access-control-allow-origin: https://mosas.shimizu-technology.com` and **no** `access-control-allow-credentials` header. The branding endpoint is credential-free (`api/config/initializers/cors.rb`).
- The `/api/v1/auth/me` preflight has `access-control-allow-origin: https://mosas.shimizu-technology.com` **and** `access-control-allow-credentials: true`. This one carries sign-in, so it is credentialed.
- The unknown client still gets `404` and no CORS header.

While `subdomain_enabled` is off, the `/api/v1/auth/me` preflight has no `access-control-allow-origin` either.

Then look in the browser (on a phone too): the page loads over HTTPS with no certificate warning. Until M4-8 ships, you see the "coming soon" placeholder. After M4-8, you also see the client's name and logo. Open the browser console and make sure there are **no Content-Security-Policy errors**.

Write the date and result for each address in the go-live record (M4-12).

## 4. After M4-8 ships: check the Content-Security-Policy once

The policy is written for Clerk's production sign-in, but no Clerk screen exists in the employee build yet. When M4-8 deploys, sign in on the team address with a test login and watch the console. A blocked script or request is a CSP error.

- Fix it in `web/scripts/finalize-surface-dist.mjs` (the policy) or `web/deploy/employee/_headers.template` (the other headers), then deploy.
- Add only the exact origin that was blocked. The policy already carries the hosts Clerk documents for production sign-in, bot protection and fraud protection ([Clerk CSP guide](https://clerk.com/docs/guides/secure/best-practices/csp-headers)): `https://challenges.cloudflare.com`, `https://*.protect.clerk.com` (scripts and frames), `https://*.protect.clerk.com:*` (connections) and `https://img.clerk.com`. Those are the only wildcards allowed. Don't add a bare `*`, any other wildcard, `unsafe-eval`, or `unsafe-inline` for scripts, and don't relax `frame-ancestors`, `object-src` or `connect-src`.

## 5. Alerts

Set these up before anyone is invited. Until a tool is chosen, check by hand every day during the first week (Render → the employee service → Logs, search the event name).

| Alert | Where it comes from | Fire when |
|---|---|---|
| Employee API 5xx | Render logs: `"event":"http.request"` with `"status":5xx` on the employee service | 5 or more in 5 minutes |
| Employee API down | Render notifications (deploy failed, instance unhealthy), plus an uptime monitor on `$API/health/dependencies` | any failure for 2 checks in a row |
| Employee site down | Uptime monitor on `https://mosas.shimizu-technology.com/` and on the team address | any failure for 2 checks in a row |
| Rate-limit hits | Render logs: `"event":"http.rate_limited.payroll"`. Look at the `throttle` field: `employee/…`, `auth/ip`, `tenant_branding/ip`. | more than 20 in 10 minutes |
| Activation lockouts | Render logs: `"event":"employee_links.activation_locked"` (warn, one per locked invite). An audit row `employee_links#activation_locked` is kept for each. | any lockout |
| Activation lockout burst | Render logs: `"event":"employee_links.activation_lock_alert"` (error): 3 invites at one company locked within an hour. Audit row `employee_links#activation_lock_alert`; M4-9 shows it in the admin screens. | any |
| Database pool pressure | Render logs: `"event":"db.pool_checkout"` | repeated, or `wait_ms` over 500 |
| Redis fallback | Render logs: `Shared counters unavailable` | any (limits are per process while it lasts) |

A 429 burst from one restaurant on shared Wi-Fi is the thing to watch. M4-2 re-sizes the limits. If it happens before then, tell the lead. Don't raise limits by hand.

## 6. Rollback

Go in this order. Stop as soon as the problem is fixed.

1. **Turn the address off for the client.** Set `subdomain_enabled` to false in the company's current operating profile (M4-9 screen), **and** in any scheduled future operating profile that would turn it back on (see [`CLIENT_SUBDOMAIN_ACTIVATION.md`](../CLIENT_SUBDOMAIN_ACTIVATION.md)). Within 45 seconds the branding endpoint gives 404 and CORS stops allowing the address. Employees see "isn't available".
2. **Bad website deploy.** Netlify → Site 2 → Deploys → pick the last good deploy → Publish deploy. That locks auto-publishing. Unlock it after the fix is merged.
3. **Bad API deploy.** Render → employee service → Events → roll back to the last good deploy.
4. **Take the whole thing down** (in this order). Do steps 2 to 5 for **every enabled address**: MoSa's (company 6, `mosas`) **and** the team address (company 1, `cornerstone`).
   1. Suspend the Render employee service. A suspended service isn't billed.
   2. Remove the address from Clerk's allowed subdomains.
   3. Delete the Cloudflare CNAME. Wait for it to stop resolving.
   4. Remove the Netlify alias.
   5. Clear the slug: `TenantScope.as_system(reason: "M4-10 rollback") { [6, 1].each { |id| Company.find(id).update!(subdomain_slug: nil) } }`. It only works with `subdomain_enabled` off (including scheduled profiles), so do step 1 above for both companies first.
5. **Delete** the Netlify site and the Render service only when you're sure. The employee service owns no data and runs no migrations. Payroll isn't touched by any of these steps.

If Redis is down, the API falls back to per-process counters and keeps serving. Don't roll back for that.

## 7. Costs

| Item | Cost |
|---|---|
| Render employee API (Starter) | **$7 a month** |
| Netlify site 2 | $0 on the shared credit pool. First deploy about 15 credits, each later production deploy about 15. Add +$9 a month (Personal) only if credits run short. |
| Redis / Valkey | $0 extra if Payroll's existing one is reused |
| Neon | $0 extra (3 more direct connections) |
| Clerk Pro | $25 a month, bought at the M4 gate (not part of this slice) |

The M4 plan's gate total is $32 a month. Don't change billing, plans or credit purchases without Leon's OK.

## Open questions

1. **Is there a shared Redis for rate limits today?** The readiness check fails without one, and this runbook assumes Payroll web already has `RACK_ATTACK_REDIS_URL`. If not, a Render Key Value instance is an unbudgeted cost.
2. **Which slug for company 1?** This runbook uses `cornerstone`. Any unreserved 3 to 40 character slug works. Note that company 1's `name` will be shown publicly on that address.
3. **Where do alerts go?** The log events exist. No log search or alert tool is recorded in the repo.
4. **Is company 1 a live company?** The registry only serves live companies. If company 1 is a test workspace, the team address can't use it. Check in step 3.1.
