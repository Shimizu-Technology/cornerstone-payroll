---
name: cornerstone-finance
description: Read one Cornerstone financial book and create or edit invoice drafts using a book-scoped finance CLI. Use for invoice status checks, draft preparation, and finance summaries, not for payroll or payment changes.
---

# Cornerstone finance

Use `scripts/finance_cli.py` from the Cornerstone repository. A Cornerstone admin creates a key under **Finance Overview → Agent access** for the intended book. The default is read only; the admin can explicitly allow draft creation and editing. Keys expire after 90 days and can be revoked there. They cannot issue, send, or mark invoices paid.

Set `CORNERSTONE_FINANCE_TOKEN` in the agent's secret environment. Set `CORNERSTONE_FINANCE_API_URL` to the trusted API URL ending in `/api/v1`; use HTTPS outside localhost. Set `CORNERSTONE_FINANCE_ORGANIZATION_ID` and `CORNERSTONE_FINANCE_BOOK_ID` to the IDs shown for the intended book. Do not put the key in prompts, shell arguments, logs, or repository files.

```bash
python3 scripts/finance_cli.py context
python3 scripts/finance_cli.py recipients
python3 scripts/finance_cli.py billing-profiles
python3 scripts/finance_cli.py overview
python3 scripts/finance_cli.py invoices --page 1
python3 scripts/finance_cli.py invoice 123
python3 scripts/finance_cli.py expenses --page 1
python3 scripts/finance_cli.py expense 456
```

For a draft write, first read the book's recipients and billing profiles. Use their IDs in a JSON file with `invoice_recipient_id`, `invoice_billing_profile_id`, `invoice_date`, `due_date`, and `line_items` (`description`, `quantity`, `rate`). Discounts use `discount_type` (`none`, `percent`, or `amount`) and `discount_value`. All writes need a fresh idempotency key; reuse the same key and file when retrying an uncertain result. A changed request needs a new key.

```bash
python3 scripts/finance_cli.py new-key
python3 scripts/finance_cli.py draft-create invoice.json --idempotency-key <saved-key>
python3 scripts/finance_cli.py invoice 123
python3 scripts/finance_cli.py draft-update 123 changes.json --version 0 --idempotency-key <new-saved-key>
```

Use the `lock_version` returned by the latest invoice read when editing. A stale version returns a conflict; reread and review the current draft before editing again. The draft JSON for an update contains the fields to change. If it includes `line_items`, that array replaces the draft's full line-item set; include existing `id` values for items to keep. Review the result in the app before issuing or sending it.

Check the `scope` object in every response before using financial data. Listing commands are paginated; follow `meta.total_count` to inspect all records. `payments_received` and `payments_made` are recorded entries, not bank-reconciled cash. Do not infer that an invoice is paid from an email send or that a bill is paid from its entry alone.

If a key is lost, suspected exposed, or no longer needed, revoke it in Agent access and issue a new one. Ask for source payment evidence before changing historical invoice status in the UI.
