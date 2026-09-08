# Historical payroll import providers

## Purpose

Cornerstone keeps imported payroll as an immutable source ledger. It does not turn old checks into editable native pay periods, rerun tax calculations, issue payments, or infer facts that the source did not provide.

The provider layer makes that migration workflow reusable without implying that an unreviewed export is supported. QuickBooks Online Payroll is the only registered provider today. A provider appears in the Data Migration workspace only after its parser, limits, verification versions, and downstream capabilities are explicitly registered.

## Runtime contract

Every adapter publishes:

- a stable `key`, display `label`, and importer version;
- accepted file extensions and bundle-size limits;
- a parser that returns the normalized worker, period, paycheck, reconciliation, warning, and source-file contract used by the immutable ledger;
- the recorded importer versions it can reproduce during cutover verification;
- explicit support flags for source retention, cutover verification, clean-client employee preparation, and historical YTD activation;
- source limitations that operators must understand before staging data.

`HistoricalPayrollImports::Registry` is the allowlist. Unknown provider keys fail before parsing, storage, or database writes. Historical cutover verification resolves the adapter from the batch's recorded `source_system`; a removed or unknown adapter therefore fails closed before retained files are restored.

Source retention and cutover verification are mandatory safety capabilities for every registered provider. Clean-client employee preparation and historical YTD activation are optional and are blocked by the API and hidden in the interface until the adapter explicitly enables them.

The admin index returns the same provider contract used by the server. The Data Migration upload control uses it for the source selector, accepted file types, file count, description, and importer version. Clients may omit `source_system` for backward compatibility; that request resolves to `quickbooks_online`.

## Adding another provider

A new provider is not complete when it can read a spreadsheet. Before registering it:

1. Collect representative, read-only export bundles from more than one client using the relevant product and version.
2. Define required reports, stable identities, sign conventions, void/reversal behavior, opening-summary limitations, and maximum safe counts and sizes.
3. Normalize source data into the existing immutable ledger contract without recalculating historical payroll.
4. Reconcile independent source reports and preserve blocking errors separately from reviewable warnings.
5. Retain every original source file with its manifest position, size, SHA-256 digest, report classification, and verified restore path.
6. Add exact importer-version compatibility. Never claim that a current parser can reproduce an older batch until fixture-based verification proves it.
7. Enable only downstream capabilities that have provider-specific evidence. Employee preparation and YTD activation must remain false until their mappings and reconciliation rules are reviewed.
8. Add service, request, export, and browser tests covering tenant isolation, idempotency, unsupported versions, duplicate bundles, malformed files, source restoration, and read-only presentation.
9. Add a database migration that replaces the `historical_import_batches_source` check with an allowlist containing the new key. The database constraint and application registry are independent safety gates.
10. Run a client-specific preview and reconcile counts and money totals to the source before applying or locking anything.
11. Keep the provider out of the registry until all of the above is complete.

## Files

- `api/app/services/historical_payroll_imports/adapter.rb` defines the shared contract.
- `api/app/services/historical_payroll_imports/registry.rb` is the supported-provider allowlist.
- `api/app/services/historical_payroll_imports/import_service.rb` is the provider-aware entry point.
- `api/app/services/historical_payroll_imports/quickbooks_online_adapter.rb` wraps the existing reviewed QuickBooks parser and compatibility rules.
- `api/app/services/quickbooks_history/import_service.rb` remains the normalized ledger persistence implementation for the current adapter.

Provider-specific parsing and reconciliation may live in its own namespace. Shared orchestration must depend on the adapter contract, not on provider constants.

## Safety invariants

- Imported source rows and their evidence remain immutable.
- Provider selection is explicit and stored on every batch.
- Idempotency includes company, provider, bundle digest, and importer version.
- An unregistered provider or unsupported recorded version fails closed.
- Preview errors do not become accepted history.
- Only locked history appears as normal imported payroll.
- Source snapshots and later append-only adjustments remain separately identifiable.
- No adapter may create live checks, liabilities, filings, payments, or accounting postings as a side effect of historical import.
