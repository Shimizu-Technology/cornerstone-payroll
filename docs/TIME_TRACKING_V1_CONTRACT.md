# Time Summary v1 contract

**Owner:** Cornerstone Payroll

**Reviewed:** 2026-08-23

**Status:** Normative for Payroll imports; companion applications must implement the same response contract

## Authority boundary

The time source owns punches, work dates, approval state, categories, and traceable entry identifiers. Cornerstone Payroll owns the employer's confirmed legal workweek, the 40-hour weekly threshold, the regular/overtime totals that are paid, wage-rate mapping, and gross-to-net calculation.

A source-provided overtime split is evidence, not the financial result. Payroll recalculates each employee's regular and overtime hours across complete legal workweeks. It uses a source category split only when more than one category falls on the day that crosses the threshold and the category split reconciles with Payroll's day-level result. If that allocation is missing or contradictory, the import stops for correction instead of guessing which earning rate receives overtime.

## Transport

Payroll requests:

```text
GET {base_url}/api/v1/payroll/time_summary?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD
```

The source authenticates either `X-Payroll-Shared-Secret` or the legacy-compatible `X-Shared-Secret`. The response is JSON. Payroll's destination, TLS, DNS pinning, timeout, response-size, and source-identity requirements are defined in the Gate 0 external time destination contract.

## Response shape

`schema_version` is `"1.0"`. During the companion-application rollout, an omitted version is interpreted as v1; any other explicit version is rejected.

```json
{
  "schema_version": "1.0",
  "source": "aire_services",
  "start_date": "2026-05-18",
  "end_date": "2026-05-24",
  "generated_at": "2026-05-25T08:00:00Z",
  "employees": [
    {
      "source_user_id": "42",
      "email": "employee@example.com",
      "display_name": "Employee Name",
      "days": [
        {
          "work_date": "2026-05-18",
          "hours": 8.0,
          "total_hours": 8.0,
          "regular_hours": 8.0,
          "overtime_hours": 0.0,
          "entry_ids": [101],
          "categories": [
            {
              "source_category_id": "7",
              "key": "flight_instruction",
              "name": "Flight Instruction",
              "hours": 8.0,
              "total_hours": 8.0,
              "regular_hours": 8.0,
              "overtime_hours": 0.0,
              "effective_rate_cents": 7500,
              "entry_ids": [101]
            }
          ]
        },
        {
          "work_date": "2026-05-19",
          "hours": 0.0,
          "total_hours": 0.0,
          "regular_hours": 0.0,
          "overtime_hours": 0.0,
          "entry_ids": [],
          "categories": []
        },
        {
          "work_date": "2026-05-20",
          "hours": 0.0,
          "total_hours": 0.0,
          "regular_hours": 0.0,
          "overtime_hours": 0.0,
          "entry_ids": [],
          "categories": []
        },
        {
          "work_date": "2026-05-21",
          "hours": 0.0,
          "total_hours": 0.0,
          "regular_hours": 0.0,
          "overtime_hours": 0.0,
          "entry_ids": [],
          "categories": []
        },
        {
          "work_date": "2026-05-22",
          "hours": 0.0,
          "total_hours": 0.0,
          "regular_hours": 0.0,
          "overtime_hours": 0.0,
          "entry_ids": [],
          "categories": []
        },
        {
          "work_date": "2026-05-23",
          "hours": 0.0,
          "total_hours": 0.0,
          "regular_hours": 0.0,
          "overtime_hours": 0.0,
          "entry_ids": [],
          "categories": []
        },
        {
          "work_date": "2026-05-24",
          "hours": 0.0,
          "total_hours": 0.0,
          "regular_hours": 0.0,
          "overtime_hours": 0.0,
          "entry_ids": [],
          "categories": []
        }
      ],
      "total_hours": 8.0,
      "regular_hours": 8.0,
      "overtime_hours": 0.0,
      "issues": {
        "pending_count": 0,
        "pending_overtime_count": 0,
        "denied_count": 0,
        "denied_overtime_count": 0,
        "open_clock_count": 0
      }
    }
  ],
  "summary": {
    "countable_hours": 8.0,
    "regular_hours": 8.0,
    "overtime_hours": 0.0
  }
}
```

Cornerstone Tax may omit regular/overtime fields and provide category `hours` only. Payroll still recalculates the paid split. AIRE should provide the fuller evidence above, including category splits and rate snapshots.

## Blocking invariants

Payroll rejects the complete export before creating a preview when any invariant fails:

- `source` must match the configured built-in source identity;
- an explicit `schema_version` must be `1.0`;
- export dates, when supplied, must match the requested complete-workweek range;
- `employees` and every `days`/`categories` collection must be arrays of objects;
- `source_user_id` must be present and unique within the export;
- each employee may have only one row per `work_date`, and dates must be inside the requested range;
- every included employee must have one row for every requested calendar date, including explicit zero-hour rows, so a partial workweek cannot silently understate overtime;
- hour values must be finite, non-negative numbers, with no more than 24 hours on one work date;
- `hours` and `total_hours`, when both supplied, must agree;
- regular and overtime values must appear together and must sum to their total;
- every category must have a stable `source_category_id`, `key`, or `name`, and normalized category identities must be unique within a day;
- partial child split evidence is rejected: if any category provides a regular/overtime split, every category on that day must provide one; if employee totals provide a split and any day provides one, every day must provide one;
- category totals must equal their day total;
- employee totals must equal their day totals;
- source employee and summary splits, when supplied, must reconcile with their child evidence; and
- `issues`, when supplied, must be an object; known issue counts must be non-negative whole numbers, hour totals must be finite and non-negative, and open-clock identifiers must be an array; and
- all reconciliation uses a 0.01-hour tolerance.

Pending, denied, pending-overtime, denied-overtime, open-clock, employee-mapping, and wage-rate-mapping warnings continue to block apply. The raw export, checksum, processed preview, legal-workweek snapshot, warnings, mappings, and apply identity remain auditable.

Requested import dates must stay inside the selected pay period. Applying is allowed only from a preview validated under this contract, and the preview's pay-period dates and legal-workweek snapshot must still match. An older or stale preview must be refreshed.

## Known v1 boundary

V1 carries work dates, not punch timestamps. It therefore supports only legal workweeks that begin at midnight. New non-midnight configuration is rejected, and imports or salary allocation against a legacy non-midnight record stop with an explicit error.

A future timestamp-capable contract must define timezone, offset and daylight-saving behavior, interval splitting at the legal boundary, break treatment, corrections, and ordering for multi-category intervals before non-midnight workweeks can be enabled.

## Change rules

- Additive optional fields may be introduced within v1 when old consumers can ignore them.
- A required field, changed meaning, different rounding rule, or timestamp boundary requires a new schema version.
- Payroll must accept a new version before a source emits it in production.
- Contract fixtures and negative reconciliation cases must run in Payroll, AIRE, and Cornerstone Tax CI.
