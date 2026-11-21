# Client profitability

**Reports → Client profitability** (`/reports/client-profitability`) shows, for each client and period: hours, staff cost, fees, margin, margin %, and fees per hour. Tax-prep fees get their own column. Internal/overhead time, unassigned hours and pending hours are shown on separate lines.

- **Hours** come from Cornerstone Tax's Work Hours feed (Tax `docs/PAYROLL_WORK_HOURS_FEED.md`, schema 1.x).
- **Cost** comes from the payroll that Payroll runs for Cornerstone's own staff.
- **Fees** come from issued invoices in Invoice Center (`InvoiceServiceFeeRevenue`).

Tax never receives pay data, and Payroll only reads from Tax.

Only organization admins and super admins can open it (capability `view_client_profitability`). Managers and accountants can't, because the report shows what each staff member costs.

**Organization.** Every request works on the organization chosen in the switcher. The web app sends it as `X-Organization-Id`. The server checks it the same way the finance controllers do: an org admin may only name their own organization, and a super admin must name one. The financial-book header is ignored here, so the report always uses the book saved in Setup.

## Setup

1. **Shared secret.** Generate one long random value, for example `openssl rand -hex 32`. Set it as `PAYROLL_WORK_HOURS_SECRET` on **both** the Tax server and the Payroll API server. It is separate from the time summary's `PAYROLL_SHARED_SECRET`; don't reuse one for the other. Payroll never stores the secret in its database or sends it in a request.
2. **Tax address.** On the Payroll API server, set `CORNERSTONE_TAX_API_URL` to Tax's API origin, for example `https://api.cornerstone-tax.example`. It must use `https://`. A plain `http://localhost` address works only outside production. If Tax is served under a path prefix, include it. The prefix becomes part of the signed path, so Tax must see that same path.
3. **Staff payroll client.** On **Setup**, choose the Payroll client that runs Cornerstone's own staff payroll. On production that is "Cornerstone". This is a saved setting (`client_profitability_settings.practice_company_id`), not a hard-coded id. The page calls it "the client that runs Cornerstone's own staff payroll" because "practice" already means practice copies (test workspaces) elsewhere in Payroll.
4. **Financial book.** The default book is used unless you choose another. Only invoices in that book count as fees.
5. **Tax-prep services.** Tick the services that are tax preparation (see below).
6. **Refresh hours from Tax**, then **Link clients & staff**.

Until both environment variables are set, the page shows a "not connected" panel listing what's missing. It makes no calls to Tax, and the nightly refresh does nothing.

## Pulling hours

- **Refresh hours from Tax** (Setup) queues `TaxWorkHoursImportJob` for whole months, up to 24 months back and never past today. If the job can't be queued, the refresh is marked failed straight away and the page says to try again.
- **Nightly**, `TaxWorkHoursNightlyRefreshJob` (`config/recurring.yml`, 2am) refreshes last month through today for each organization that has chosen its staff payroll client.
- **One refresh at a time.**
  - Manual and nightly refreshes both start through `WorkHourImport.reserve!`, under the organization row lock.
  - A partial unique index allows only one queued or running import per organization.
  - A worker claims an import (`claim!`) and renews a 5-minute lease after each month.
  - If a worker dies, the next job retry waits out the lease, then takes the import over. A queued import that no worker picks up within 15 minutes, or a running one past its lease, is marked "interrupted" when the next refresh starts.
  - Rows are replaced only while the worker still holds its claim, checked under a row lock inside the replacement transaction. A slow worker that lost its claim can't overwrite newer hours.
- The Setup section isn't the only place that watches a refresh. The page keeps watching it from any section, picks up one already running on the server (for example the nightly job), and reloads the report when it ends.
- The feed allows at most 62 days per request and doesn't paginate, so Payroll asks for one calendar month at a time.
- **Signing** (`TaxWorkHours::Signer`) follows the contract exactly. The string to sign is `METHOD\npath\ncanonical query\ntimestamp\nsha256(body)`; the signature is hex HMAC-SHA256 of it, sent with `X-Work-Hours-Timestamp` and `X-Work-Hours-Signature`. Each query key is sent once. `spec/services/tax_work_hours/signer_spec.rb` pins the doc example's signature, computed with Tax's own code.
- **Timeouts and retries.** Connecting times out after 5 seconds and reading after 30. Timeouts, refused connections and HTTP 429/500/502/504 are retried twice, after 0.5 and then 1 second. A 401 (wrong secret or clock skew beyond ±5 minutes), 503 (secret not set on Tax), 422, or an unreadable payload is not retried. The refresh records a plain-language reason that never includes the secret.
- **Atomic replace.** Every month is fetched first. Then, in one transaction under a per-organization advisory lock, every stored row dated inside the refreshed range is deleted and the new rows are inserted. If any month fails, nothing stored changes. Rows outside the range are kept.
- **Stored data.** `work_hour_imports` records each pull: its range, when it ran, who asked, and Tax's pending, denied and open-clock counts. `work_hour_rows` holds the feed rows as sent: Tax user id and email, work date, Tax client id and name, `system_kind`, unassigned, category, task, period, hours, entry ids and approval state.

## Linking (Payroll side only)

- **Tax client → Payroll client.** Fees are keyed by the payroll client (`companies`) that an invoice is explicitly linked to, so each Tax client is linked to a company (`work_hour_client_links`) or marked **Internal / overhead**. Tax's own internal client (`system_kind: "internal"`) counts as overhead automatically. Suggestions compare names after removing punctuation and words like Inc, LLC and Corp. An exact match is marked "same name"; otherwise the best match sharing at least half its words is marked "similar name". Every suggestion must be confirmed.
- **Tax user → employee.** Each Tax user is linked to an employee of the staff payroll client, or marked **Not on payroll**, for an owner paid by draw. Their hours are then shown with no cost. The suggestion is an exact email match, or a unique first-name match with the start of the email.
- Links are saved, editable and reused for every period. **Unlink** keeps the row (marked inactive, with who changed it); linking again reactivates it.
- Changing the staff payroll client sends people linked to the old client's employees back to "needs linking". An employee link must always point at the current staff payroll client.
- If a client or the staff payroll client is moved to another organization, this organization's report stops reading it.
- Anything not linked stays visible: hours for an unlinked Tax client show under **Not tied to a client → Not linked yet**, hours with no client in Tax show as **No client chosen in Tax**, and an unlinked person's hours show with no cost.

## How the numbers are calculated

**Period.** One month, one quarter, or a custom range of whole months (up to 24). Hours count by **work date**, staff pay by **pay date**, and fees by **service month**.

**Cost per person.** Total cost always equals the Annual Payroll Summary's **Total payroll cost** for the staff payroll client and the same pay dates. The report doesn't re-derive it; it asks that service (`AnnualPayrollSummary#payroll_cost_by_employee`, using the same sources as `#period_row`). That total includes:
- gross pay
- non-taxable pay
- the employer's Social Security and Medicare
- employer contributions, such as retirement match and employer benefit items
- imported QuickBooks or prior-provider paychecks linked to an employee, and imported adjustments, from locked batches

Voided runs, reversed paychecks and legacy-disposition items are excluded, as in the existing reports.

**Imported pay not linked to an employee** is left out of the Annual Payroll Summary's total, so it is left out here too. It is shown on its own line, "Imported pay not linked to an employee", and is never in a total or on a client. Link the worker in Data Migration to count it. `spec/services/client_profitability/reconciliation_spec.rb` checks that the two reports agree.

**Allocation.** Each person's cost is split across every place they logged hours in the period, in proportion to approved hours: clients, overhead, unlinked Tax clients and "no client". Tax's `clock` hours count as approved. If one employee has several Tax identities, their hours are pooled and their cost is split once; the staff table shows them on one row. Splits are to the cent, and the parts always add back to the person's cost. Pay with nowhere to go appears under **Pay not matched to hours** and still counts in the total cost. That covers:
- a person with no hours in the period
- an employee not linked to any Tax user

**Pending hours.** Hours still waiting for approval in Tax are always shown and are costed only when **Count pending hours in cost** is on.

**Overhead.** Internal time gets its share of cost on its own line. **Spread internal / overhead time across clients** moves that cost onto clients in proportion to their hours. The overhead line stays visible for reference, and the totals count it once.

**Fees.** `InvoiceServiceFeeRevenue` gives issued service-fee value by linked client and service month:
- reimbursements are excluded
- discounts are spread across lines
- drafts and voids are excluded
- uncollectible invoices still count
- payments and credits don't change the value

Invoices not linked to a payroll client are shown as **Fees not linked to a client**.

**Columns.**
- **Margin** = fees − cost.
- **Margin %** = margin ÷ fees.
- **Fees per hour** = fees ÷ hours (counted hours, which include pending hours when that toggle is on).

## Tax prep

Invoice lines didn't distinguish tax prep before this report, so there is now a classification. In **Setup**, tick the services that count as tax preparation. The list comes from the book's saved services and from product/service names already used on issued fee lines.

A service-fee line counts as tax prep when its product/service name matches a ticked name, ignoring case and extra spaces. The invoice discount is spread over tax prep in proportion, as for all fees (`InvoiceServiceFeeRevenue`'s `tax_prep_service_names:`).

This classification needs no change to issued invoices, which stay immutable, and it applies to past invoices as soon as a name is ticked. Lines with an empty product/service name, as on some older invoices and imported originals, can't be classified and count as other fees.

## Limits

- Pay is matched by pay date and hours by work date. A paycheck that covers late-September work but is paid in October costs October's hours, so single months can look uneven. Quarters smooth this out.
- A Tax client links to exactly one Payroll client. If one Payroll client has several Tax clients, link each of them to it.
- Fees can only be joined when the invoice is explicitly linked to a payroll client. Payroll doesn't guess a client from a recipient's name.
- Owners or staff paid outside Payroll have no cost unless their pay runs through the staff payroll client.
- The report uses whatever hours were last pulled. Refresh after Tax approvals change. Months that haven't been pulled are flagged at the top of the report.
- **CSV export** (`/export`) holds the same lines as the screen, plus one row per person, and is recorded in Activity History.
