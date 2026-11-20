# Monthly practice billing

In Invoice Center, open **Senders & logos** to edit a billing profile. Existing profiles retain prefix/year numbering. For a continuing sequence, choose **Plain continuing sequence** and enter the next number (7055 for Dafne's initial setup). Drafts receive internal identifiers; the official number is allocated under a sender lock when issued. The unique sender/number index remains authoritative. Allocation can leave gaps after failures; it is not a gapless ledger.

Add saved services to that sender. A service has a name, description template and kind. `{month}` expands to the selected service month's full month/year. For example, Accounting Consulting with `Accounting Services – {month}`. Add Reimbursement with a pass-through kind for taxes paid on a client's behalf.

Save each customer's monthly fee in **Default rate**, payment terms (Net 15, Net 30 or Due on receipt), and optional payroll-client link. In a new Center draft, choose the customer and saved service. The client link defaults from the customer; service dates initially cover the invoice month and can be edited explicitly. Review the service month before saving. Both the linked client and service period remain visible on invoice detail.

Reimbursements are part of the invoice total, payments, outstanding balance and aging. `line_kind` is preserved on lines and issued snapshots, and marked on the PDF. `service_fee_amount` and the **Billed service fees** summary exclude reimbursements and allocate invoice discounts proportionally across fee and reimbursement lines. This is issued billed value, including uncollectible invoices; it is not cash receipts, a credit-adjusted revenue ledger or a historical month-end report. Client/month profit reporting must define credit attribution and multi-month allocation separately. Unlinked invoices are unallocated; do not infer a payroll client from a recipient's name.

For continuing profiles, monthly recurrence creates review drafts for the calendar month, updates the description's month, applies the customer's current fee and terms, and assigns an official number only at issue. Existing yearly profiles retain their scheduled due-day and rate behavior. Reimbursement amounts copied from the source need review each month.

To send from Gmail, issue, **Download original**, email that PDF yourself, then **Mark as sent (by my own email)**. Recording delivery does not send email. The separate Send now/Schedule email controls use the existing invoice transport; no production email configuration is changed here.

Issued PDFs remain exact preserved evidence. Existing issued documents are not rewritten to adopt new rounding. Legacy drafts recalculate before issue; new lines round half-up to cents and totals sum those rounded amounts. Quantity and rate support at most two decimal places. USD is the only supported currency.
