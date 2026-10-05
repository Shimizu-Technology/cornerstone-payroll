# Connecting another time application

Cornerstone calculates payroll and records payments. Each time application owns
its employee identities, recorded work, approvals and frozen payroll batches.
One active source belongs to one company. AIRE retains its fixed approved policy;
other producers use the company's confirmed schedule and workweek.

## Setup

Create a source using **Custom compatible source**, its backend URL and independent
shared secret. Configure the approved HTTPS sign-in website origin when the source
supports account linking. Test the connection to verify and pin its installation.
Map employees using permanent source UUIDs. Existing payroll requires approved,
installation-bound historical coverage before calendar publication.

The connection test reads `/api/v1/payroll/time_summary`. Its response
includes a `source` identifier and this integration descriptor:

```json
{
  "source": "example_time",
  "integration": {
    "source_type": "example_time",
    "source_instance_id": "e07a6797-b51b-41c9-960f-99375c83eec3",
    "protocol": "shimizu_time_payroll",
    "protocol_version": "1.0",
    "capabilities": [
      "time_summary_v1", "finalized_batch_v2", "payroll_calendar_v2",
      "exact_line_receipts_v2", "employee_directory", "payroll_cockpit",
      "account_linking", "manual_allocations", "payment_attestations"
    ],
    "policy_constraints": {
      "time_zones": ["Pacific/Guam"],
      "workweek_starts": ["monday"],
      "cutoff_rules": ["before_pay_date"],
      "frequencies": ["weekly"]
    }
  }
}
```

Capabilities describe implemented operations, not permissions for an operator.
Both Cornerstone's assigned-company role and the producer's linked-account or
delegation permissions apply. Summary-only sources retain summary imports and
cannot use calendars, frozen batches, receipts or operator commands.

## Wire contract

The shared client defines the endpoint paths and request fields in
`api/app/services/time_tracking/client.rb`. Full producers implement those paths;
the source setup does not accept arbitrary per-operation destinations. Requests
carry independent connection credentials and `X-Payroll-Source-Instance-Id`.
Reject an installation mismatch before reading or modifying business records.
Custom producers use `X-Payroll-Actor-Id` or `X-Payroll-Delegation-Token`. AIRE's
adapter retains its deployed actor and delegation headers.

Calendar schema 2.0 contains exact work dates, scheduled payday, timezone, cutoff
rule/days, previous regular scheduled payday when applicable, and weekly-only
40-hour overtime policy. This release supports midnight workweek boundaries.
The producer must advertise supported timezone, weekday, frequency and cutoff
rule combinations. A missing or incompatible policy blocks publication. Salary,
rates, tax calculations and actual check amounts remain Cornerstone records.

Frozen batch schema 2.0 retains exact source UUIDs, payable line identities,
original work dates/weeks, current/carryover/correction dimensions, exclusions
and SHA-256 canonical checksum. A non-AIRE identifier does not relax validation.
Manual allocations and payment receipts carry exact regular/OT source coverage.
They must not be interpreted as actual paycheck classification when historical
check inputs differ.

Send finalized events to `/api/v1/integrations/time_payroll/events`, with the
connection secret and event UUID as `Idempotency-Key`. Cornerstone authenticates
the published period's connection and verifies its latest delivered revision,
producer identifier and batch checksum. Identical replays are idempotent;
changed-body replays are rejected. Event receipt is not batch verification or
payment issuance.

Neutral operator aliases are `/admin/pay_periods/:id/time_tracking_calendar`,
`/admin/pay_periods/:id/time_tracking_cockpit` and
`/admin/time_tracking_sources/:id/account_link` under `/api/v1`.
Existing AIRE routes, records and queued jobs remain compatible. The personal
connection page is `/app/time-account-connection`; the old page is an alias.

The additive employee evidence capability `employee_period_evidence_v1` uses
`GET /api/v1/payroll/cockpit/employees/:id/periods` and `/periods/:work_period_id`.
Requests require the mapped `source_user_uuid`; date filters are original work
dates, with signed cursor pagination and totals covering the complete filter.
Response contract 1.0 must identify the same employee UUID and installation.
Actual paycheck components come from saved Cornerstone evidence, not inferred
source allocations.

## Verification before enabling payroll

Use a disposable company and independent producer installation. Verify calendar
publication, immutable batch import, manual allocation, payment issuance and
exact receipts in both applications. Test duplicate/reordered callbacks,
timeout-after-success, void/replacement, partial coverage, capability loss and
two companies with overlapping numeric IDs. Keep saved historical payroll
available when a source becomes unavailable or disabled. A connection test alone
does not certify these flows or approve historical financial changes.

Every successful custom protocol response includes the integration descriptor.
The consumer rejects a changed installation, producer, protocol, capabilities or
policy constraints before accepting delivery. An operator must test the
connection to adopt changed advertised support. Deployed AIRE endpoints that
return bare acknowledgements remain compatible through the existing pinned
request header and authenticated secret. AIRE responses that include descriptors
are validated.

The AIRE adapter provides validated relative links to employee work periods.
Custom producers have no employee navigation link until a verified navigation
contract is available. The consumer does not infer routes from an origin.

Required historical reconciliation must be approved before a new draft can
preview or apply finalized time. The locked apply boundary rechecks capabilities
and history completion so an older preview cannot bypass admission. Committed
historical review and reconciliation remain available for the approval work;
legacy summary admission keeps its existing behavior. Restoring capabilities on
an already established complete connection does not restart onboarding.
