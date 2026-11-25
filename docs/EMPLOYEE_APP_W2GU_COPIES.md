# W-2GU copies in the employee app (M4-5)

This slice posts each employee's 2026 W-2GU (Copy B over Copy C, with the IRS notice behind) to the employee app, alongside the paper copy. It's switched off by default: nothing posts or shows until a company's `employee_portal.features.tax_forms` switch is on (M4-9). Paper W-2s still go out in the pilot (§0 D5).

Plan reference: [Milestone 4 build plan](MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) §1.3, §4 "M4-5" and §8a.

## When a copy posts

Staff with client administration access can post and review copies in **Employee app W-2 copies** on the client's **Year-end checklist**. Select the tax year, mark the W-2s ready on the current figures, then choose **Post 2026 copies**. Posting runs in the background. Use **Refresh list** to see the copies and email notices. The same panel lets staff record how paper copies are delivered or withdraw an individual copy with a reason.

The screen calls `POST /api/v1/admin/employee_tax_forms/post_copies { year }`. The endpoint queues `PostEmployeeW2GuCopiesJob`, which runs `EmployeeDocuments::PostW2GuCopies`. Nothing posts unless the staff download would print the same copies as final:

- the `tax_forms` switch is on, and the year has an IRS template (2026 only);
- Cornerstone files the year's W-2s for the client;
- the W-2 readiness mark is current on these exact inputs, and the filing-responsibility gate allows filing-ready output (`W2GuOfficialCopies.snapshot`, shared with the staff download);
- every value fits the form for the whole report.

The PDFs are drawn and uploaded to storage before any lock is held. Posting then takes the company lock and a shared lock on the year's annual tax rules (the SS wage base is in the fingerprint), in the payroll lock order, reads the inputs again uncached, and commits the rows under those locks. If anything changed, nothing posts and the uploads are deleted. The job retries that case a few times.

Each copy is the single-employee path of `W2GuOfficialCopies` (`employee_id:`), which only makes final copies. It's frozen once in `employee_documents` with `employee_id` and `tax_year` as its source and a SHA-256 fingerprint, like the pay stubs. A demo company's copy prints like a live client's, with no practice or draft stamp.

Posting is idempotent: an employee who already has a copy for the year (posted or withdrawn) is skipped, so a rerun posts only what's missing.

Each copy also records the W-2 inputs fingerprint it was drawn from. `GET /api/v1/admin/employee_tax_forms?year=2026` lists the year's copies with their notice delivery, and flags `inputs_changed_since_posting` when the year's figures no longer match. A posted copy is never redrawn; staff decide whether to withdraw it.

## What the employee sees

- `GET /api/v1/employee/tax_forms`: `{ tax_forms: [{ id, tax_year, kind: "w2gu", status, corrected, posted_at, pdf_available, available_through }] }`, newest year first.
- `GET /api/v1/employee/tax_forms/:id`: one of those rows.
- `GET /api/v1/employee/tax_forms/:id/pdf`: the frozen file, `Cache-Control: no-store`, served only when its bytes still match the fingerprint. After the bytes come back from storage, the link, the switch and the copy are read again, so a withdrawal, a revoked link or a switch turned off during the fetch is still a 404.

Every read is audited (`employee_tax_form#listed`, `#viewed`, `#pdf_downloaded`). Every failure, including a switch that's off, another employee's copy or another company's, is the same empty 404.

`GET /api/v1/employee/context` returns the company's `w2_delivery` (`mailed`, `handed_out` or `null`). Staff set it with `PATCH /api/v1/admin/employee_app_settings/w2_delivery`. The app says "Your W-2 will be mailed here" only when it's `mailed`. Former employees always see "mailed to your last address".

## Former employees and retention

A former employee sees every copy posted for them, which covers each year they were paid. An electronically furnished W-2 must stay available through October 15 of the following year (26 CFR 31.6051-1(j)). So:

- when a copy posts, the employee's open former links whose access would end sooner are extended to the end of that October 15 (Guam time), with an audit entry;
- when a link becomes former after a copy posted, its end date is never earlier than that date.

That longer window covers tax forms and pay stubs only. Profile reads (contact details, emergency contacts, address requests) end at the link's original cutoff, kept in `former_profile_access_until`, and the context then reports `profile_requests: false`.

A link whose access already ended stays closed.

## Withdrawing a copy

`POST /api/v1/admin/employee_tax_forms/:id/withdraw { reason }` marks a posted copy withdrawn, with who, when and the reason. The employee app keeps the row, without a PDF, and says "A corrected form is being prepared". The reason isn't shown to the employee. Posting never brings a withdrawn copy back. W-2c posting is a later slice.

## The notice email

Each newly posted copy gets a `pending` notice row in the same transaction that posts it. After that commits, `DispatchEmployeeTaxFormNoticesJob` sends the company's pending notices, and the same job runs every 10 minutes for every company (`config/recurring.yml`), so a notice whose job was lost is still sent. Posting again also adds a pending notice for any posted copy that has none. The email's subject is "IMPORTANT TAX RETURN DOCUMENT AVAILABLE", and it carries the employer's name and a link to the app, never an amount or an SSN. It goes only to the employee's own `employees.email`, only once that address is verified, and only while the employee has app access. It's sent only while `PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true`. For a demo company it goes through `DemoOutbound`, so an address that isn't on the allow-list is dropped.

One `employee_document_notices` row per copy records the outcome: `pending`, `sent`, `skipped` (with the reason, including `email_delivery_disabled` while notification email is off) or `failed`. The sweep retries a failed send after 10 minutes, up to 5 attempts in all.

## Bounces

`delivery_status` on each notice starts as `unknown`. Resend reports delivery through signed webhooks, which `POST /api/v1/integrations/email_events` receives:

- every verified event is stored in `email_provider_events` before the endpoint answers, once per Svix event id, so a replay changes nothing. The row keeps the Resend message id, event type, mapped status, bounce type and time, never an address;
- `email.delivered`, `email.delivery_delayed`, `email.bounced` and `email.complained` then update the notice with that Resend message id. An event that arrives before the notice records its id is applied when the send commits, or by the sweep;
- events apply oldest first, and an event older than the one already applied never overwrites it;
- a bounce or complaint is final and is audited for staff, without the address;
- events for other email match no notice and are deleted after 90 days;
- nothing in the webhook body is logged: the endpoint masks its parameters before Rails logs them, and the global log filter also hides `cc`, `bcc`, `recipients`, `reply_to`, and `to`/`from` inside a payload's `data`.

### Set up and verify bounce tracking

1. In the Resend dashboard, open **Webhooks** and add an endpoint at `https://<payroll-api-host>/api/v1/integrations/email_events`. Use the payroll API's public HTTPS host. Select `email.delivered`, `email.delivery_delayed`, `email.bounced` and `email.complained`. [Resend webhook setup](https://resend.com/docs/webhooks/introduction)
2. Open the endpoint's details and copy its **Signing Secret** (`whsec_…`) into the payroll API service's secret environment as `RESEND_WEBHOOK_SECRET`. Reload the API with the new setting. [Resend signature verification](https://resend.com/docs/webhooks/verify-webhooks-requests)
3. Run `bin/rails production:readiness` on the payroll API. The signing-secret check reports `PASS` when the setting has the expected `whsec_` prefix and `WARN` when it is missing or has the wrong format. Verify delivery separately in Resend.
4. Send a generic test message to Resend's simulated bounce address. In the webhook's event log, confirm the signed `email.bounced` request received HTTP `204`. For an end-to-end notice test, use an isolated test company with a fictional employee and explicitly allowed test delivery, then refresh the W-2 copy list and confirm the notice shows **Bounced**. A test message sent directly through Resend has no payroll notice to update. [Resend test addresses](https://resend.com/changelog/sending-test-emails)

Without the secret the endpoint returns `404` and notice delivery stays unknown. Keep sending paper W-2s throughout the pilot. Electronic-only delivery still requires live bounce tracking and a mailed paper notice within 30 days of a bounce. The mailed follow-up is part of M4-6.
