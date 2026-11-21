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
6. **Report defaults.** Where the report starts each time it opens; people can still change these on screen for one view. All are saved per organization.
   - **Count pending hours in cost**: off by default.
   - **Spread internal/overhead time across clients**: off by default.
   - **Default period**: month by default (or quarter, or custom months).
7. **Count pay by** (see "Cost basis" below): **pay date** by default, which matches the Annual Payroll Summary, or **work period**.
8. **Refresh hours from Tax**, then **Link clients & staff**.

Until both environment variables are set, the page shows a "not connected" panel listing what's missing. It makes no calls to Tax, and the nightly refresh does nothing.

## Pulling hours

- **Refresh hours from Tax** (Setup) queues `TaxWorkHoursImportJob` for whole months, up to 24 months back and never past today. If the job can't be queued, the refresh is marked failed straight away and the page says to try again.
- **Nightly**, `TaxWorkHoursNightlyRefreshJob` (`config/recurring.yml`, 2am) refreshes last month through today for each organization that has chosen its staff payroll client.
- **One refresh at a time.**
  - Manual and nightly refreshes both start through `WorkHourImport.reserve!`, under the organization row lock.
  - A partial unique index allows only one queued or running import per organization.
  - A worker claims an import (`claim!`) and renews a 5-minute lease after each month.
  - If a worker dies, the next job retry waits out the lease, then takes the import over.
  - A queued import that no worker picks up within 15 minutes is reported as "interrupted, nothing was changed". A job that finally arrives after that can't claim it; the claim marks the import failed instead, so hours never change after the page has said they won't. A running import past its lease, or a queued one, is also marked "interrupted" when the next refresh starts.
  - Rows are replaced only while the worker still holds its claim **and** its lease hasn't ended. The database checks both while the import row is locked inside the replacement transaction. A lease that has ended can't be renewed, even by the worker that held it. A worker that runs out of time, during a slow month or after its last renewal, saves nothing; if nobody took the import over, the refresh is marked "took too long" and can be retried.
  - Locks are always taken in the same order: the organization row, then the import row. That holds both for starting a refresh and for saving one, so a refresh started while another is saving waits instead of deadlocking. The organization row is locked `FOR NO KEY UPDATE`: refreshes still wait for each other, but unrelated writes that only reference the organization (foreign keys) aren't blocked during a save.
- After a refresh finishes, the report and the link queue both reload, so new Tax clients and staff show up without reopening the page.
- The Setup section isn't the only place that watches a refresh. The page keeps watching it from any section, picks up one already running on the server (for example the nightly job), and reloads the report when it ends.
- The feed allows at most 62 days per request and doesn't paginate, so Payroll asks for one calendar month at a time.
- **Signing** (`TaxWorkHours::Signer`) follows the contract exactly. The string to sign is `METHOD\npath\ncanonical query\ntimestamp\nsha256(body)`; the signature is hex HMAC-SHA256 of it, sent with `X-Work-Hours-Timestamp` and `X-Work-Hours-Signature`. Each query key is sent once. `spec/services/tax_work_hours/signer_spec.rb` pins the doc example's signature, computed with Tax's own code.
- **Timeouts and retries.** Connecting times out after 5 seconds and reading after 30. Timeouts, refused connections and HTTP 429/500/502/504 are retried twice, after 0.5 and then 1 second. A 401 (wrong secret or clock skew beyond ±5 minutes), 503 (secret not set on Tax), 422, or an unreadable payload is not retried. The refresh records a plain-language reason that never includes the secret.
- **Atomic replace.** Every month is fetched first. Then, in one transaction under a per-organization advisory lock, every stored row dated inside the refreshed range is deleted and the new rows are inserted. If any month fails, nothing stored changes. Rows outside the range are kept.
- **Stored data.** `work_hour_imports` records each pull: its range, when it ran, who asked, and Tax's pending, denied and open-clock counts. `work_hour_rows` holds the feed rows as sent: Tax user id and email, work date, Tax client id and name, `system_kind`, unassigned, category, task, period, hours, entry ids and approval state.

## Linking (Payroll side only)

- **Tax client → Payroll client.** Fees are keyed by the payroll client (`companies`) that an invoice is explicitly linked to, so each Tax client is linked to a company (`work_hour_client_links`) or marked **Internal / overhead**. Tax's own internal client (`system_kind: "internal"`) counts as overhead automatically. Suggestions compare names after removing punctuation and words like Inc, LLC and Corp. An exact match is marked "same name"; otherwise the best match sharing at least half its words is marked "similar name". Every suggestion must be confirmed.
- **Tax client → invoice customer (no payroll).** Some clients are billed in Invoice Center but have no Payroll client, such as "Roland's Watch Repair (Ponce)". A Tax client can be linked straight to that invoice customer (disposition `recipient`, `invoice_recipient_id`).
  - Fees on that customer's invoices with no payroll client count on that row instead of on "Fees not linked to a client", and the row's hours are costed as usual.
  - Only customers in the report's financial book that have no Payroll client are offered, and saving a link to a customer from another book is refused. A link that points outside the report's book (for example after the book in Setup changes) is treated as not linked.
  - If the customer is later given a Payroll client, the link counts as that client's row. Moving the Tax link to that Payroll client keeps the customer's earlier invoices (the ones with no Payroll client) on that client. Every invoice is counted once.
  - Deleting a customer that a link points to (even an inactive one) archives the customer instead, so saved links keep their history.
  - The dropdown groups the choices as "Payroll clients" and "Invoice customers (no payroll)", plus Internal / overhead. Suggestions look at both lists, Payroll clients first.
  - The database check on dispositions allows exactly one target per link: a company, an invoice customer, or neither for internal.
- **Tax user → employee.** Each Tax user is linked to an employee of the staff payroll client, or marked **Not on payroll**, for an owner paid by draw. Their hours are then shown with no cost. The suggestion is an exact email match, or a unique first-name match with the start of the email.
- Links are saved, editable and reused for every period. **Unlink** keeps the row (marked inactive, with who changed it); linking again reactivates it.
- Changing the staff payroll client sends people linked to the old client's employees back to "needs linking". An employee link must always point at the current staff payroll client.
- If a client or the staff payroll client is moved to another organization, this organization's report stops reading it.
- Anything not linked stays visible: hours for an unlinked Tax client show under **Not tied to a client → Not linked yet**, hours with no client in Tax show as **No client chosen in Tax**, and an unlinked person's hours show with no cost.

## How the numbers are calculated

**Period.** One month, one quarter, or a custom range of whole months (up to 24). Hours count by **work date**, staff pay by **pay date** (or work period, see below), and fees by **service month**.

**Cost basis ("Count pay by").**
- **Pay date** (default): each paycheck counts in full in the month it was paid. Totals equal the Annual Payroll Summary's total payroll cost for the same months.
- **Work period**: each paycheck is spread over the days of its pay period, and the report counts the days that fall in the chosen months. A check paid December 2 for November 16–30 counts in November.
  - The same paychecks are eligible as with pay date (voided runs, reversed paychecks and legacy items stay out, and corrections count). They're chosen because their pay period overlaps the chosen months, however late they were paid: a November paycheck paid in May still counts in November. A pay period without a usable date range falls back to its pay date.
  - Imported paychecks use their own period dates, and an imported adjustment follows its paycheck's period.
  - Amounts are split in whole cents per day. Leftover cents go one each to the last days of the pay period, so the months of a range always add up to the range exactly. Pay, employer taxes and employer contributions are each split this way, and a row's total is their sum.
- With work period, the report shows the difference from the Annual Payroll Summary for the chosen months, and why: pay for work in one range that was paid in another. The two are guaranteed to agree when the range contains both every worked day **and** every pay date of the paychecks involved. They can also agree by coincidence otherwise, when pay moving in and out of the range happens to balance. A November report covers all of November 16–30, but the December 2 pay date is outside it, so it can show a difference.
- The CSV is built with the same basis as the report on screen, even if someone changes the saved setting in between.
- Allocation to clients by approved hours is the same under both.

**Cost per person.** With the default pay-date basis, total cost always equals the Annual Payroll Summary's **Total payroll cost** for the staff payroll client and the same pay dates (with work period, see above). The report doesn't re-derive it; it asks that service (`AnnualPayrollSummary#payroll_cost_by_employee`, using the same sources as `#period_row`). That total includes:
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

Each invoice's fees go to exactly one line, only through explicit links, never by matching names:
1. an invoice linked to a payroll client counts for that client;
2. an invoice with no payroll client counts for its invoice customer's row when a Tax client is linked to that customer (or for the customer's Payroll client, once it has one);
3. an invoice with no payroll client whose customer has since been given a Payroll client counts for that client, when a Tax client is linked to it;
4. anything else is shown as **Fees not linked to a client**.

**Columns.**
- **Margin** = fees − cost.
- **Margin %** = margin ÷ fees.
- **Fees per hour** = fees ÷ hours (counted hours, which include pending hours when that toggle is on). Work that wasn't billed shows $0.00 per hour; it's blank only when there are no counted hours.

## Tax prep

Invoice lines didn't distinguish tax prep before this report, so there is now a classification. In **Setup**, tick the services that count as tax preparation. The list comes from the book's saved services and from product/service names already used on issued fee lines.

A service-fee line counts as tax prep when its product/service name matches a ticked name, ignoring case and extra spaces. The invoice discount is spread over tax prep in proportion, as for all fees (`InvoiceServiceFeeRevenue`'s `tax_prep_service_names:`).

This classification needs no change to issued invoices, which stay immutable, and it applies to past invoices as soon as a name is ticked. Lines with an empty product/service name, as on some older invoices and imported originals, can't be classified and count as other fees.

## Limits

- With the default pay-date basis, pay is matched by pay date and hours by work date. A paycheck that covers late-September work but is paid in October costs October's hours, so single months can look uneven. Quarters smooth this out, or switch **Count pay by** to work period.
- Work-period spreading is by calendar days, not by the hours on the paycheck.
- A Tax client links to exactly one Payroll client. If one Payroll client has several Tax clients, link each of them to it.
- Fees can only be joined through explicit links: the invoice's payroll client, or a Tax client linked to the invoice customer (see the fee rules above). Payroll doesn't guess a client from a customer's name.
- Owners or staff paid outside Payroll have no cost unless their pay runs through the staff payroll client.
- The report uses whatever hours were last pulled. Refresh after Tax approvals change. Months that haven't been pulled are flagged at the top of the report.
- **CSV export** (`/export`) holds the same lines as the screen, plus one row per person. It records which "Count pay by" basis was used and is recorded in Activity History.
