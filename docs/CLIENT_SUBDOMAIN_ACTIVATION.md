# Activate a client employee subdomain

M3-6 adds the plumbing. Existing company slugs are empty and `subdomain_enabled` defaults to false. The enabled host serves a branded coming-soon page until the employee portal ships. Staff and client offices use `payroll.shimizu-technology.com`.

1. Assign an active live company a unique `subdomain_slug`. Set the employee app's name, logo, colors and Help contacts on the company's **Employee app** page (Settings for Cornerstone staff with client administration, or the client portal for the client's own users). An uploaded logo is served by the API at a fingerprinted public URL. The legacy `branding` key `logo_url` still works for an external image when no logo is uploaded. Use a publicly accessible HTTPS logo URL and six-digit hex colors. Use a stable public image URL with no query or fragment. Presigned URLs expose their signature in the public response and expire. Use a public asset hostname for R2 or S3 images. Keep `subdomain_enabled` false during infrastructure setup.
2. Add `<slug>.shimizu-technology.com` as a domain alias on the Payroll Netlify project. Add the per-client CNAME to the Netlify target shown in the project. Set a Cloudflare CNAME to Netlify to **DNS only** (grey cloud). Wildcard TLS on Netlify requires Netlify DNS or a custom certificate. If using wildcard DNS, verify Netlify routing and TLS for the intended aliases and preserve existing service records. Check that the alias serves the Payroll build over HTTPS. [Netlify domain aliases](https://docs.netlify.com/manage/domains/configure-domains/add-a-domain-alias/)
3. After the M3-0b Clerk production cutover on `shimizu-technology.com`, keep **Allowed subdomains** enabled and add the exact client hostname when preparing employee sign-in. Keep the payroll hostname on the list. Under the milestone's Clerk plan, sibling subdomains share the root instance without a paid satellite. Recheck plan availability during cutover. A client's own domain is deferred. [Clerk production setup](https://clerk.com/docs/guides/development/deployment/production) · [Clerk subdomain allowlist](https://clerk.com/docs/guides/dashboard/dns-domains/subdomain-allowlist)
4. Set `subdomain_enabled` to true in the company's current operating profile after approval. Rails derives the exact HTTPS origin for CORS and JWT `azp` from the effective profile of a live, active company in an active organization. The registry refreshes after commits in the web process and has a 45-second cache lifetime. Keep the existing static `CORS_ORIGINS` and `CLERK_AUTHORIZED_PARTIES` entries for Payroll. Use the profile to manage tenant origins.
5. Verify the branded page, the public branding response, and a CORS preflight from the exact alias. Verify a disabled host gets a branding 404 and a preflight without an allow-origin header. Branding and tenant-origin auth or employee requests share a 30-per-minute per-IP limit, including preflights. The branding response is credential-free. To roll back, switch the profile off and follow the hostname cleanup steps below.

## Rename or retire an enabled slug

1. Set `subdomain_enabled` to false in the effective profile and in any scheduled profile that would turn the old slug back on. Allow the registry cache to refresh, then confirm the old hostname gets a branding 404 and its origin is rejected.
2. Remove the old hostname from the Clerk allowlist. Remove its dedicated DNS record, confirm it has stopped resolving after the DNS TTL, then remove the old Netlify alias. Check any wildcard routing for the old hostname and ensure it cannot resolve to an unclaimed alias.
3. Save the new slug and complete the activation steps for the new hostname before turning it on. Tell the employer when the new link is ready. For retirement, clear the slug after cleanup.

M4 moves employee aliases to a dedicated employee Netlify site. Move each existing alias and update its DNS target as part of that rollout.

For local browser QA, a Vite dev server on loopback accepts `/?tenantHost=<slug>.shimizu-technology.com`. Point `VITE_API_URL` to your local Rails API and use isolated test fixtures. The override is available only in Vite development builds on loopback.

## Employee app branding and Help contacts

The **Employee app** page sets, per company:

- **Name employees see** (`branding.display_name`, up to 60 characters; blank uses the company name) and **Home Screen name** (`branding.app_name`, up to 30; phones cut labels off at about 12).
- **Logo:** PNG or WebP, up to 1 MB and 2,400 pixels a side. **SVG isn't supported**, because denylist sanitizing is unreliable and phones need a raster Home Screen icon. Only image chunks are kept: PNG text, EXIF and time chunks are dropped, and PNG pixel data must inflate to exactly the size its header describes. WebP must be one still image (animation is refused) and keeps only `VP8 `, `VP8L`, `VP8X`, `ALPH` and `ICCP`. Each upload gets its own storage key. A square logo, at least 512×512, works best. The page warns, without blocking, about a non-square logo or one under 256 pixels. Stored in R2 under `tenant-brand/company-<id>/<sha256>-<random>`.
- **Brand color** and an optional **accent**. The page shows the button shade the employee app will use (`web/src/lib/tenant-brand-colors.ts`): white text always gets at least 4.5:1, and a light color is never used behind white text.
- **Main phone:** the company's phone on file, shown on the sign-in screen and on Help when no contacts are set, unless the switch is off.
- **Help contacts:** up to 5 people (name, role, phone, email, "text OK"), in order. They are served only to signed-in employees of that company and never in the public branding response.

Every change is audited (`employee_app_settings#update_branding`, `#upload_logo`, `#remove_logo`, `#update_help_contacts`).

The public branding response is `name`, `app_name`, `logo_url`, `primary_color`, `accent_color` and `main_phone`. It never includes Help contacts, emails or storage keys.

### Set MoSa's branding (company 6, not seeded)

Set it on MoSa's Employee app page when its subdomain is prepared (M4-10), and confirm the badge with MoSa's:

- **Logo:** upload the "Joint" badge PNG from the official site, `https://mosasjointguam.com/assets/image_1771348149002-8oH8FEyv.png` (351×429 PNG, SHA-256 `c279dbfd…60000dc`). It's the header, footer and hero logo on the site. The "HotBox" badge is the 2014 food-truck origin and is the current Instagram profile picture. The page will warn that it isn't square; ask MoSa's for a square PNG of at least 512×512 (or a larger master file) for the Home Screen icon.
- **Name employees see:** `MoSa's`. **Home Screen name:** `MoSa's Pay`.
- **Brand color:** `#1898CF` (logo blue). Buttons automatically use `#137AA7`, the computed shade with white text at 4.5:1 or better. The audit's hand-picked `#1A6F99` (5.56:1) also passes if MoSa's prefers it; enter it as the brand color.
- **Accent color:** `#FADF06` (logo yellow). It only ever appears with dark text.
- **Help contacts:** Emma, Sara and Mo, once they confirm what employees should see (phone or email, and whether texting is OK).
