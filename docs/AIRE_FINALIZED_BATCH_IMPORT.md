# AIRE finalized payroll batch import

**Status:** Implemented on the finalized-batch import branch. Deployment and production operator verification remain separate release gates.

## Purpose

Cornerstone imports AIRE payroll hours from one immutable, finalized batch whose start and end dates exactly match the selected Cornerstone pay period. It does not pull a changing view of time entries.

This preserves three accounting rules:

- hours included at AIRE's cutoff never change inside that batch;
- pending, denied, and open entries remain tracked in AIRE but are not paid from that batch; and
- a late approval or later edit arrives as a carryover or correction in a future finalized batch.

## Import boundary

AIRE sources use payroll batch contract `2.0`. Other time-tracking sources continue to use the existing Time Summary v1 adapter.

For AIRE, Cornerstone:

1. lists finalized batches for the pay-period dates;
2. requires exactly one batch with the exact dates;
3. retrieves the batch detail;
4. verifies its source, contract version, dates, cutoff/finalization timestamps, reconciled totals, and SHA-256 checksum;
5. confirms the AIRE workweek matches Cornerstone's confirmed midnight workweek;
6. maps each source employee and earning dimension, including the source effective rate;
7. shows current, carryover, correction, and unpaid exclusion evidence before apply; and
8. records the external batch ID, checksum, contract version, cutoff, raw payload, processed payload, and applying operator.

The external batch ID is unique per time-tracking source. Repeating the same ID and checksum is a no-op. Reusing an ID with different contents, or presenting the same ID for another pay period, is rejected.

## Pay treatment

Cornerstone preserves AIRE's effective rate on each earning dimension. This is necessary for later rate corrections: reversing an old-rate line and adding a new-rate line must remain separate even if the employee's current default rate has changed.

Finalized AIRE rows cannot be skipped during apply. Only exclusions declared by the finalized AIRE batch remain unpaid.

Negative correction lines require an explicit acknowledgement and operator note. If an import would make regular hours, overtime hours, or source-rate gross pay negative for an employee, the operator must use Cornerstone's correction workflow rather than an ordinary pay run.

## Operator workflow

1. Confirm the matching pay period exists in Cornerstone and has the intended legal workweek.
2. Open the draft pay period and choose **Import Time Tracking**.
3. Retrieve the finalized AIRE batch.
4. Review the batch ID, cutoff, contract, checksum, employee matches, earning-rate mappings, carryovers/corrections, and exclusions.
5. Resolve any unmapped employee or earning dimension.
6. Apply the finalized batch, then calculate payroll normally.

An empty finalized batch is valid and may be applied so Cornerstone retains evidence that the period was reviewed and contained no payable hours.

## Failure and recovery

- **No matching batch:** finalize the exact period in AIRE; do not widen the Cornerstone dates.
- **More than one matching batch:** stop and investigate. AIRE is expected to enforce one immutable batch per period.
- **Checksum, total, date, or workweek mismatch:** do not import. Correct the producing or consuming contract implementation and retrieve again.
- **Unmapped employee or earning:** update the mapping in the preview; do not discard a finalized row.
- **Negative net correction:** use Cornerstone's correction workflow.
- **Already applied:** do not create a second import. The existing import provenance is the authoritative record.

## Release evidence

The branch includes automated coverage for canonical checksums, payload reconciliation, list/detail retrieval, employee and rate mapping, apply-time revalidation, idempotency, empty batches, exclusions, negative corrections, and request serialization.

Local full-stack verification used isolated AIRE and Cornerstone databases and servers. A finalized AIRE batch containing a four-hour carryover at $32 per hour and one open-clock exclusion was retrieved, integrity-verified, applied once, and rejected as a duplicate on the second retrieval. The resulting Cornerstone payroll row retained the source batch ID, checksum, contract `2.0`, cutoff, earning label, rate, and hours.

