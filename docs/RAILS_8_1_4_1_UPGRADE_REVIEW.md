# Rails 8.1.4.1 upgrade review

Reviewed November 5, 2026. This change is held for Claude's release decision. It changes dependency constraints, lockfiles, canonical proxy-header middleware, specs and this review. Payroll calculations, source mappings, approval/commit, connected-mode guards and database migrations are unchanged. Full CI and an updated exact-pair integration certificate remain release gates.

## Dependency boundary

The 13 Rails/framework gems move from 8.1.3.1 to 8.1.4.1: Rails, Railties, Active Support, Active Model, Active Record, Active Job, Active Storage, Action Pack, Action View, Action Mailer, Action Mailbox, Action Cable and Action Text. All other gem versions and platforms are unchanged, including Rack 3.2.8, Nokogiri 1.19.7, rails-html-sanitizer 1.7.2, Loofah 2.25.3, MiniMagick 5.3.1 and ruby-vips 2.3.0. The new Action View sanitizer requirement is already satisfied. No unrelated updates or advisory exclusions were added.

## Behavior review

Read the [8.1.4](https://github.com/rails/rails/releases/tag/v8.1.4) and [8.1.4.1](https://github.com/rails/rails/releases/tag/v8.1.4.1) release notes and framework changes. Findings relevant to these apps:

| Area | Finding and acceptance |
| --- | --- |
| Forwarded client IP | When both header families are supplied, different resolved client addresses now raise `ActionDispatch::RemoteIp::IpSpoofAttackError`. Local requests with X-Forwarded-For alone or matching headers reach the real API. A conflict raises even in request logging, outside the inner exception handler; its default exception status is 500. CanonicalProxyHeaders now removes the two untrusted alternative headers before either resolver; hosted acceptance is described below. |
| Parameters | `each_key` now returns the parameters object. App call-site searches found Hash iteration, with no use of a returned unpermitted parameter object for assignment. New specs verify the returned object remains unpermitted and assignment raises. |
| Sessions | Cookie SameSite settings now apply across stores; CacheStore has dropped-session and reset/concurrency fixes. Both apps use API token authentication and load no Rails session middleware in the tested configuration. `Rails.cache` and Rack::Attack caching are separate from `Session::CacheStore`. No session configuration changed. |
| Storage | Blob tempfiles retain an extension only when it agrees with the recorded media type; sanitized filename handling also changes. Video/audio probing now limits accepted container formats, and background video preview handling improves. Common image/video uploads need hosted checks. Neither app uses GCS, so its new signed content-length/CORS requirements are inactive here. |
| ImageMagick | Rails installs a policy through `MiniMagick.cli_env` for every MiniMagick invocation, even when Active Storage uses vips. PDF/PostScript coders and Ghostscript are restricted unless the host policy explicitly permits them. MiniMagick below 5.1 with the MiniMagick variant processor now fails boot; the locked version is 5.3.1 and both apps booted. Do not disable the policy globally. |
| View helpers | `strip_tags` now encodes quotes; tag helpers discard blank attribute names; highlight substitutions escape matches; sanitizer dependency bounds tighten. No app calls to `strip_tags`, `highlight` or `simple_format` were found. Do not decode HTML indiscriminately. ERB mail previews still need a hosted check. |
| Record/query behavior | Schema defaults now preserve their database representation; grouped aggregate/write, callback-ordering and connection-pool fixes may affect callers. Searches found no application consumers of deserialized column defaults or the changed distinct/callback forms. Focused app checks passed; full CI is still required. |
| Other behavior | Fractional duration conversions now preserve subsecond precision; the found app conversion uses a whole-day constant. No new general deprecation-to-error switch was identified. Existing RSpec/Rack deprecated status warnings still warn. MessagePack's safe-string encoding changes matter to mixed-version readers if that optional serializer is configured; no explicit MessagePack serializer was found. |

Sources: [Action Pack](https://github.com/rails/rails/blob/v8.1.4.1/actionpack/CHANGELOG.md), [Active Storage](https://github.com/rails/rails/blob/v8.1.4.1/activestorage/CHANGELOG.md), [Action View](https://github.com/rails/rails/blob/v8.1.4.1/actionview/CHANGELOG.md), [Active Record](https://github.com/rails/rails/blob/v8.1.4.1/activerecord/CHANGELOG.md), [Active Support](https://github.com/rails/rails/blob/v8.1.4.1/activesupport/CHANGELOG.md).

## Canonical proxy headers on Render

On November 5, the lead's hosted probes confirmed that Render replaces a forged X-Forwarded-For value, but preserves client-supplied Forwarded and Client-Ip. Both alternative headers produced 500 responses on the previous candidate. The new `CanonicalProxyHeaders` Rack middleware deletes only `HTTP_FORWARDED` and `HTTP_CLIENT_IP`, retaining `HTTP_X_FORWARDED_FOR` and `REMOTE_ADDR` unchanged. The deployment contract is that all application traffic passes through the existing Render edge and its authoritative X-Forwarded-For chain.

The application registers this middleware after the configuration initializers and before middleware-stack construction, inserting it at index zero. This puts normalization before CORS, Rails request logging, both IP resolvers and Rack::Attack. Spoof checking remains enabled; trusted-proxy CIDRs, throttles and audit logic are unchanged. This is header normalization, not an exception rescue or a blanket trust expansion.

Request regressions assert exact normal API responses for ordinary traffic, a forged XFF prefix, forged Forwarded, forged Client-Ip and matching alternative headers. They assert the middleware is first, audit context and throttle identity resolve from the canonical chain, and request logging records the true client address. AIRE's public index is `/api/v1/site-media`; `/api/v1/site_media` is an ordinary 404 and is also suitable for comparing status behavior through the host.

Hosted acceptance must repeat the lead's matrix on the deployed exact heads, compare normal and forged request log IPs, and verify authenticated audit context and throttle identity through safe staging checks. Keep Render's edge contract and the existing trusted-hop configuration; do not expose the app directly or broaden trust. [Rails IP source](https://github.com/rails/rails/blob/v8.1.4.1/actionpack/lib/action_dispatch/middleware/remote_ip.rb), [Render proxy chain](https://render.com/articles/how-render-handles-ddos-attacks).

## Local evidence and remaining hosted checks

Base: `e09cf85142c4afc4946cd7841a3c827c40dd364a`.

- 117 focused examples passed, covering forwarding/parameters, Rack::Attack, golden calculate/approve/commit, checks, pay stubs, payroll-register PDFs and timecard segmentation. New-spec RuboCop passed. Updated `bin/bundler-audit` reports no vulnerabilities.
- PDFs for checks, stubs and registers use Prawn rather than the changed HTML text helpers. Invoice helpers use number formatting with explicit money precision. No application money code changed.
- Payroll permits an explicit `TRUSTED_PROXY_CIDRS` list. An unset list retains Rails defaults. Verify actual hosted settings and proxy hops; broadening trust does not fix conflicting header families.
- Timecard OCR uses MiniMagick despite the vips variant setting. Normal PDF rendering invokes ImageMagick directly; a fallback opens PDFs through MiniMagick and is exposed to the new policy. The Mac's real PDF raster probe could not complete because Ghostscript is absent from the isolated test PATH; PDF object construction alone does not prove decoding works. Hosted acceptance must preprocess a synthetic PDF and JPEG through the real segmentation path and exercise its fallback, without calling the paid external OCR provider. If the fallback is required and denied, review the narrow host policy allowance or replace that fallback separately; do not broadly re-enable unsafe coders.
- Run the hosted IP gate, login/audit/throttle smoke, document/email previews and exact-pair connected-payroll certificate before release. No hosted requests or writes were made for this review.

Full Payroll CI initially found one schema-metadata expectation affected by the documented raw column-default change: `CompanyAssignment` metadata now returns `"false"`. Its spec explicitly deserializes the raw default before checking false; the persisted-assignment and NOT NULL assertions remain intact. No authorization logic changed.
