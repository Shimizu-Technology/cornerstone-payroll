# AIRE payroll entry lifecycle rollout

This rollout links each immutable AIRE time-entry adjustment to the Cornerstone payroll item that processed it. It does not change compensation rates or recalculate a committed payroll.

## Release order

1. Deploy AIRE first. Run its migrations, then confirm the payroll batch endpoints still accept the existing version 2 contract and that newly finalized batches include `source_user_uuid`.
2. Deploy Cornerstone. Run its migrations before the web release. Confirm existing employee mappings do not contain duplicate Cornerstone employees for the same company and source.
3. Test the configured AIRE source from Cornerstone. Retrieve a finalized batch without applying it and confirm every employee mapping is correct.
4. Reconcile the historical committed pay period. Use **Link AIRE Record**, map every AIRE person, enter an audit note, and continue only if Cornerstone reports an exact regular/overtime-hours match for every employee.
5. Confirm AIRE shows the linked entries as **Payroll committed**. Printing a check should change them to **Payment prepared**. Use **Mark Delivered** only after the employee receives the check; AIRE should then show **Paid**.

## Identity backfill

Existing mappings continue to work by AIRE's legacy numeric user ID. The next verified import or historical reconciliation stores the employee's AIRE UUID on the saved mapping. After that, the UUID is preferred even if an internal numeric ID, email, or name changes.

Do not bulk-match by name or email. If a mapping is missing or conflicts with another employee, stop and resolve it in the review screen.

## Historical reconciliation safeguards

Historical reconciliation is allowed only for committed pay periods and finalized AIRE batches with verified checksums. It requires:

- one Cornerstone employee for every payable AIRE employee;
- no duplicate employee mappings;
- an existing payroll item in the committed period;
- exact regular and overtime totals for each employee; and
- an audit note of at least 10 characters.

The action creates identity mappings, immutable source-entry allocations, and lifecycle acknowledgements. It does not edit hours, rates, taxes, deductions, net pay, check numbers, or year-to-date totals.

## Verification

- AIRE report totals remain unchanged and each entry shows its payroll lifecycle.
- Cornerstone payroll rows marked **AIRE linked** show the number and total hours of linked source entries.
- Replaying an acknowledgement is idempotent.
- A reused event ID with different data is rejected.
- A printed but undelivered check is never labeled paid.
- A voided check changes linked entries to **Payment voided**; a replacement returns to **Payment prepared**, then **Paid** after delivery.

## Recovery

Acknowledgements use an outbox and retry automatically. If AIRE is temporarily unavailable, payroll remains valid in Cornerstone and the undelivered acknowledgement keeps its error for investigation. Do not edit finalized AIRE batches or delete allocation records. Repair connectivity, then redispatch the pending acknowledgement.

If historical reconciliation rejects an employee, correct the mapping or investigate the hour difference before retrying. Do not force-link mismatched totals.
