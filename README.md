# Cornerstone Payroll

Guam-specific payroll processing for Cornerstone Tax Services.

## Why This Exists

Cornerstone's payroll work combined spreadsheets, source exports, manual review, and QuickBooks. QuickBooks created Guam address and payroll-workflow friction, while calculations, checks, compliance preparation, client communication, and evidence lived in different places. This application turns that work into a controlled Guam payroll lifecycle.

Vendor coverage changes and must be verified directly before it is used in sales material. The product's durable advantage is Cornerstone's Guam payroll and accounting-firm workflow, not an absolute claim that no other vendor serves Guam.

## Status

**Internal payroll and firm-operations application under controlled production-readiness hardening**
- Live Guam payroll workflows: calculation, approval/commit, check printing, pay stubs, tax summaries, W-2GU/Federal Form 941/1099 preparation support, and MoSa import automation
- Unified recurring/pay-period payroll adjustments with taxable, non-taxable, pre-tax, and post-tax treatment
- Check reissue, void, print, standalone FIT/GRT/child-support payments, and audit history workflows
- Invoice Maker and General Transmittals for Cornerstone firm operations
- Role-based access control, company switching, and audit logging

See [PRD.md](PRD.md) for full product requirements.

## Architecture Decision

This is a **standalone app** in the `cornerstone-payroll` repo with:
- Rails 8 API backend (`api/`)
- React 19 + Vite frontend (`web/`)

See [PRD.md](PRD.md) and [BUILD_PLAN.md](BUILD_PLAN.md) for details.

## Guam Tax Quick Reference

| Tax | Employee Rate | Employer Rate | Wage Base |
|-----|--------------|---------------|-----------|
| Guam Territorial Income Tax | Federal brackets | N/A | No cap |
| Social Security | 6.2% | 6.2% | $176,100 (2025); $184,500 (2026) |
| Medicare | 1.45% (+0.9% over $200K) | 1.45% | No cap |

- Guam uses Section 31 of the Organic Act: federal tax code with "Guam" substituted for "United States"
- Guam income-tax withholding and W-2GU filings go to Guam DRT. Federal employment-tax Form 941 goes to the IRS.
- W-2GU is the Guam wage statement. Form 941-SS was discontinued after 2023; Guam employers now use the standard federal Form 941 with the territory-specific instructions.

## Plane Board

**Project:** Cornerstone Payroll (CPR)
**URL:** https://plane.shimizu-technology.com

## Links

- [PRD](PRD.md) — Product Requirements Document
- [Build Plan](BUILD_PLAN.md) — Tactical plan
- [Future Improvements](FUTURE_IMPROVEMENTS.md)
- [Documentation Map](docs/README.md) — Current authority and historical-document rules
- [Product Strategy and Platform Boundaries](docs/PRODUCT_STRATEGY_AND_PLATFORM_BOUNDARIES_2026-08-23.md)
- [Gate 0 Trust and Release Plan](docs/GATE_0_TRUST_AND_RELEASE_PLAN_2026-08-23.md)
- [Time Summary v1 Contract](docs/TIME_TRACKING_V1_CONTRACT.md)
- [Payroll, QuickBooks, and Compliance Master Plan](docs/PAYROLL_QUICKBOOKS_COMPLIANCE_MASTER_PLAN_2026-07-11.md)
- [Pay Schedules, Salary Timekeeping, and Client Cloning Design](docs/PAY_SCHEDULE_SALARY_TIMEKEEPING_AND_CLIENT_CLONE_DESIGN_2026-08-03.md)
- [Pay Schedule, Timekeeping, and MoSa History Implementation Plan](docs/PAY_SCHEDULE_TIMEKEEPING_AND_MOSA_HISTORY_IMPLEMENTATION_PLAN_2026-08-03.md)
