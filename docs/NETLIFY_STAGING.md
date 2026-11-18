# Proposed Netlify staging migration — approval required

Status: draft only, 2026-11-18. Chels's active QA continues at the existing Drop sites.
Do not merge, deploy, create/push `staging`, or change any Netlify setting until Leon approves.
No settings, data, secrets, existing upload tools or sites are changed by this proposal.

## Current path and source limits

Leon identified `cornerstone-payroll-staging` as a manual Netlify Drop site, separate from the Git-connected `cornerstone-payroll` production site. Uploads published to the manual site's primary URL count as production deploys even though the application is staging.

An inspection of tracked main and staging-v2 trees found no `netlify deploy`, Netlify deploy API uploader, or staging site ID. `.github/workflows/` has no Drop publishing job. `docs/STAGING_ENVIRONMENT.md` lists frontend flags, metadata, Clerk and API variables by name; it does not define a tracked staging frontend `.env` path. `web/.env.example` and `api/.env.example` and `ops/staging-v2/runtime.env.example` are templates, not frontend deployment configuration. Payroll docs also describe the ignored `ops/staging-v2/runtime.env` for its separate container stack; do not source it into a Netlify frontend build. Do not print or copy private env contents.

AIRE's `.github/workflows/staging-v2.yml` builds GHCR API/web images on staging-v2 (web publishing requires repository staging variables and a publishable-key secret). Payroll's `ops/staging-v2/deploy.sh` and its poller manage the separate certified container pair, not Netlify. `ops/payroll-release-day/release_day.rb` is a data-rehearsal runner and explicitly does not deploy. These paths stay intact. Payroll's release-day README refers to private operational scripts/receipts; those and the MacBook-only release/upload scripts and env filenames could not be verified on this Mac mini. Locating their actual Drop upload command is a cutover prerequisite; do not claim they have been replaced.

## Proposed build path

Keep production on `main` with its existing `web` base, `npm run build` command and `dist` publish directory. After approval, create `staging` from the reviewed **QA candidate**, containing this configuration; do not blindly replace Chels's code with main. Record the frontend SHA, both backend SHAs and snapshot timestamp as one accepted pair.

`web/netlify.toml` overrides only non-production build commands. Branch deploys accept only `staging`; Deploy Previews also use staging containment. `scripts/netlify-staging-build.mjs` requires dedicated variables and overwrites inherited production Vite API/auth/flags before `npm run build`. No upload CLI or production publish is involved. Missing staging configuration fails before npm starts. Existing Vite containment validates API hosts, snapshot, test Clerk key, flags and peer origins again. Backend changes are not deployed by Netlify.

The wrapper supports previews safely, but stable branch URLs are the first migration target. PRs must contain this config to use it. Old branches without it retain their old behavior. Preview login, CORS and return URLs must be separately approved before using an arbitrary PR URL.

## Exact operator setup after Leon's approval

On `cornerstone-payroll` only:

1. Project configuration → Developer settings → Continuous deployment → Branches and deploy contexts → Configure: retain production branch `main`; set Branch deploys to **Let me add individual branches**, enter only `staging`, Save. Do not select All. Confirm repository `Shimizu-Technology/cornerstone-payroll`, base `web`, command `npm run build`, publish `dist`, and that `web/netlify.toml` is the configuration file actually resolved. If settings differ, stop for review rather than changing production.
2. Project configuration → Environment variables: add these with **Builds** scope and contextual values for the `staging` branch (and **Deploy Previews** only if that path is approved):
   - `NETLIFY_STAGING_API_URL`: independently verified existing staging API HTTPS URL, including its API path. Never copy the production value; require a staging hostname. Confirm deployed backend SHA and containment with the QA owner.
   - `NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY`: the existing approved staging `pk_test_` key.
   - `NETLIFY_STAGING_SNAPSHOT_AT`: the actual clone capture timestamp, not build time.
   - `NETLIFY_STAGING_CLERK_JWT_TEMPLATE`: only if the approved staging login currently needs a named template; otherwise omit.
   Netlify supplies `COMMIT_REF` and `DEPLOY_PRIME_URL`. The wrapper sets both deployment flags to `staging`, requires auth, disables analytics/maps, records the actual full SHA, and sets both stable staging peer origins. Production variables stay unchanged. Backend credentials, shared secrets and databases never belong in frontend variables.
3. Optional later: in Branches and deploy contexts, enable Deploy Previews for the approved PR workflow. Do not enable untrusted fork access to staging data/variables.
4. Before the first deploy, verify equivalent restricted tester access for branch, preview and immutable deployment aliases. The app handles production-cloned PII: a URL, CORS or a staging ribbon is not an access gate. Netlify site-wide protection may affect production; do not turn it on blindly. If the existing gateway cannot cover these aliases safely, hold cutover. This is a blocker, not an instruction to expose the clone.
5. Prepare additive staging-backend CORS/`FRONTEND_URL`/`STAGING_FRONTEND_ORIGIN` and paired `STAGING_AIRE_FRONTEND_ORIGIN` / `STAGING_PAYROLL_FRONTEND_ORIGIN` assertions plus Clerk allowed origins/redirects for the new frontend URLs. Preserve the old origins and active sessions; if backend exact-origin guards cannot accept both, schedule a separate approved coordinated transition. No backend setting is changed here.
6. Only after these checks and approval, push the reviewed staging candidate, inspect the deploy's resolved build config and environment, then execute the QA plan below. Switch the private release tool away from Drop only after acceptance; retain the old sites for fallback. Never use `netlify deploy --prod` against the main site as a staging shortcut.

## QA URLs and acceptance

Proposed stable URLs (not created or verified live):

- Payroll: `https://staging--cornerstone-payroll.netlify.app`
- AIRE: `https://staging--aire-services-guam.netlify.app`

Optional previews: `https://deploy-preview-<PR>--cornerstone-payroll.netlify.app`. The wrapper keeps cross-app links on the stable staging pair so previewing one app does not silently move the other to unreviewed code. These are separate origins: old local storage/Clerk sessions are not carried over automatically.

Affected-flow execution: agent runs offline contract checks now; Leon/Chels execute hosted acceptance after approval. Starting fixture: the existing approved paired staging clone and named tester accounts, with its snapshot and both deployed backend SHAs recorded privately. Do not reset or reseed active QA.

- Required, **passed locally**: inherited production API/key/auth settings are replaced; missing dedicated config, live keys, production APIs, bad metadata and production context fail closed; PR context selects staging.
- Required, **passed locally**: production ignore behavior and non-production build behavior checked separately; see local validation handoff.
- Required, **not_run (approval gate)**: access denied for unauthorized users on stable and immutable aliases; authorized login on desktop and phone; visible staging ribbon with the correct snapshot/frontend SHA; network requests exclusively to the verified staging APIs; cross-app links stay on the accepted staging pair; refresh/login recovery works.
- Required, **not_run (approval gate)**: Chels's existing rehearsal saved outcomes remain unchanged; new staging test edits survive refresh and are isolated from production. Record role, frontend/backend SHAs, URLs, viewport, visible/saved outcome, and acceptance before switching the QA link.

## Ignore rules and release impact

AIRE #216 is merged: its ignore script skips only production when frontend/shared inputs are unchanged. `branch-deploy` and `deploy-preview` exit 1 (build), including frontend changes. This PR preserves that rule.

Payroll #490 remains held. Its proposed script has the same non-production bypass. This PR does not merge or duplicate that held implementation. Both PRs add `web/netlify.toml`, so reconcile the add/add by retaining #490's `[build] ignore = "bash scripts/netlify-ignore-build.sh"` plus this PR's two context tables. Verify both build/skip paths after integration. This PR alone relies on the current production UI build settings, and does not install the production ignore rule.

Merging this change may trigger one production build because a frontend build input changes; it does not change production API or command. This draft is intentionally created with `[skip netlify]` in its commit and PR title to avoid deployment during proposal/review. Keep that marker until approved. No staging branch is created here.

## Credit estimate and limitations

[Netlify documents](https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/how-credits-work/) 15 credits per production publish and zero deploy credits for branch deploys/Deploy Previews. Requests/bandwidth and other usage can still cost credits.

Reproducible proxy: `git log origin/staging-v2 --first-parent --since=2026-10-19T00:00:00Z --until=2026-11-18T00:00:00Z --format=%H -- web` counts **34** frontend-affecting first-parent commits in 30 days. If each caused one manual staging publish, savings would be **510 credits/month** for this repo; combined AIRE/Payroll proxy is **675 credits/month** (45 × 15). This is a scenario estimate, not measured deployment frequency: batching reduces it, repeated uploads increase it, staging-v2 last advanced Nov 5/6, and manual uploads can come from other branches. Netlify history and MacBook release logs are unavailable here, so actual savings are unverified. The reliable unit saving is 15 credits for every Drop production publish replaced.

References: [branch deploy setup](https://docs.netlify.com/deploy/deploy-types/branch-deploys/), [preview setup](https://docs.netlify.com/deploy/deploy-types/deploy-previews/), [context variables](https://docs.netlify.com/build/environment-variables/overview/).
