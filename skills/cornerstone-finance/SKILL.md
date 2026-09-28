---
name: cornerstone-finance
description: Read invoices, expenses, and receivable/payable totals in one Cornerstone financial book using the book-scoped finance CLI. Use for invoice status checks and finance summaries, not for payroll or payment changes.
---

# Cornerstone finance

Use `scripts/finance_cli.py` from the Cornerstone repository. A Cornerstone admin creates a read-only key under **Finance Overview → Agent access** for the intended book. The key expires after 90 days and can be revoked there. It cannot create, issue, send, or mark invoices paid.

Set `CORNERSTONE_FINANCE_TOKEN` in the agent's secret environment. Set `CORNERSTONE_FINANCE_API_URL` to the trusted API URL ending in `/api/v1`; use HTTPS outside localhost. Set `CORNERSTONE_FINANCE_ORGANIZATION_ID` and `CORNERSTONE_FINANCE_BOOK_ID` to the IDs shown for the intended book. Do not put the key in prompts, shell arguments, logs, or repository files.

```bash
python3 scripts/finance_cli.py context
python3 scripts/finance_cli.py overview
python3 scripts/finance_cli.py invoices --page 1
python3 scripts/finance_cli.py invoice 123
python3 scripts/finance_cli.py expenses --page 1
python3 scripts/finance_cli.py expense 456
```

Check the `scope` object in every response before using financial data. Listing commands are paginated; follow `meta.total_count` to inspect all records. `payments_received` and `payments_made` are recorded entries, not bank-reconciled cash. Do not infer that an invoice is paid from an email send or that a bill is paid from its entry alone.

If a key is lost, suspected exposed, or no longer needed, revoke it in Agent access and issue a new one. Ask for source payment evidence before changing historical invoice status in the UI.
