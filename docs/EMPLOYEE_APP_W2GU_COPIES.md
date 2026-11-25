# W-2GU copies in the employee app (M4-5)

This slice posts each employee's 2026 W-2GU (Copy B over Copy C, with the IRS notice behind) to the employee app, alongside the paper copy. It's switched off by default: nothing posts or shows until a company's `employee_portal.features.tax_forms` switch is on (M4-9). Paper W-2s still go out in the pilot (§0 D5).

Plan reference: [Milestone 4 build plan](MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) §1.3, §4 "M4-5" and §8a.

## When a copy posts

Staff post a company's copies for a tax year with `POST /api/v1/admin/employee_tax_forms/post_copies { year }` (client administration access). That queues `PostEmployeeW2GuCopiesJob`, which runs `EmployeeDocuments::PostW2GuCopies`. Nothing posts unless the staff download would print the same copies as final:

- the `tax_forms` switch is on, and the year has an IRS template (2026 only);
- Cornerstone files the year's W-2s for the client;
- the W-2 readiness mark is current on these exact inputs, and the filing-responsibility gate allows filing-ready output (`W2GuOfficialCopies.snapshot`, shared with the staff download);
- every value fits the form for the whole report.

The PDFs are drawn outside the company lock. The lock is then taken again, the inputs are read again uncached, and nothing posts if they changed meanwhile. The job retries that case a few times.

Each copy is the single-employee path of `W2GuOfficialCopies` (`employee_id:`), which only makes final copies. It's frozen once in `employee_documents` with `employee_id` and `tax_year` as its source and a SHA-256 fingerprint, like the pay stubs. A demo company's copy prints like a live client's, with no practice or draft stamp.

Posting is idempotent: an employee who already has a copy for the year (posted or withdrawn) is skipped, so a rerun posts only what's missing.

Each copy also records the W-2 inputs fingerprint it was drawn from. `GET /api/v1/admin/employee_tax_forms?year=2026` lists the year's copies with their notice delivery, and flags `inputs_changed_since_posting` when the year's figures no longer match. A posted copy is never redrawn; staff decide whether to withdraw it.

## What the employee sees

- `GET /api/v1/employee/tax_forms`: `{ tax_forms: [{ id, tax_year, kind: "w2gu", status, corrected, posted_at, pdf_available, available_through }] }`, newest year first.
- `GET /api/v1/employee/tax_forms/:id`: one of those rows.
- `GET /api/v1/employee/tax_forms/:id/pdf`: the frozen file, `Cache-Control: no-store`, served only when its bytes still match the fingerprint.

Every read is audited (`employee_tax_form#listed`, `#viewed`, `#pdf_downloaded`). Every failure, including a switch that's off, another employee's copy or another company's, is the same empty 404.

`GET /api/v1/employee/context` returns the company's `w2_delivery` (`mailed`, `handed_out` or `null`). Staff set it with `PATCH /api/v1/admin/employee_app_settings/w2_delivery`. The app says "Your W-2 will be mailed here" only when it's `mailed`. Former employees always see "mailed to your last address".

## Former employees and retention

A former employee sees every copy posted for them, which covers each year they were paid. An electronically furnished W-2 must stay available through October 15 of the following year (26 CFR 31.6051-1(j)). So:

- when a copy posts, the employee's open former links whose access would end sooner are extended to the end of that October 15 (Guam time), with an audit entry;
- when a link becomes former after a copy posted, its end date is never earlier than that date.

A link whose access already ended stays closed.

## Withdrawing a copy

`POST /api/v1/admin/employee_tax_forms/:id/withdraw { reason }` marks a posted copy withdrawn, with who, when and the reason. The employee app keeps the row, without a PDF, and says "A corrected form is being prepared". The reason isn't shown to the employee. Posting never brings a withdrawn copy back. W-2c posting is a later slice.

## The notice email

Each newly posted copy queues `SendEmployeeTaxFormNoticeJob`. The email's subject is "IMPORTANT TAX RETURN DOCUMENT AVAILABLE", and it carries the employer's name and a link to the app, never an amount or an SSN. It goes only to the employee's own `employees.email`, only once that address is verified, and only while the employee has app access. It's sent only while `PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true`. For a demo company it goes through `DemoOutbound`, so an address that isn't on the allow-list is dropped.

One `employee_document_notices` row per copy records the outcome: `sent`, `skipped` (with the reason) or `failed` (retried).

## Bounces

`delivery_status` on each notice starts as `unknown`. Resend reports delivery through signed webhooks, which `POST /api/v1/integrations/email_events` receives:

- `email.delivered`, `email.delivery_delayed`, `email.bounced` and `email.complained` update the matching notice by its Resend message id;
- a bounce or complaint is final and is audited for staff, without the address;
- events for other email are ignored.

**Needed before bounce tracking is live in production:**

1. In Resend, add a webhook for `https://<payroll API host>/api/v1/integrations/email_events` with those four events.
2. Set `RESEND_WEBHOOK_SECRET` to the webhook's signing secret (`whsec_...`) on the payroll API service.

Until then the endpoint is a 404 and every notice's delivery stays `unknown`. That's fine for the pilot, because paper goes out anyway. Before electronic-only W-2s are switched on, bounce tracking must be live and a bounce must lead to a mailed paper notice within 30 days. That follow-up isn't built yet (M4-6).
