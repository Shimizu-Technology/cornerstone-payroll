# Cornerstone Payroll

Guam-specific payroll processing for Cornerstone Tax Services.

## Why This Exists

No major payroll software (Gusto, ADP, Check.com) supports Guam. QuickBooks requires mainland US addresses and needs manual check cleanup. This module solves both problems with native Guam tax support.

## Status

**Phase 1: Internal Payroll MVP** (Active build)
- Payroll engine and tax calculations in place
- Role-based access control and audit logging added
- Admin UI for user management, tax config, and audit logs

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
| Social Security | 6.2% | 6.2% | $168,600 (2025) |
| Medicare | 1.45% (+0.9% over $200K) | 1.45% | No cap |

- Guam uses Section 31 of the Organic Act: federal tax code with "Guam" substituted for "United States"
- File with Guam Dept of Revenue & Taxation, NOT the IRS
- W-2GU instead of W-2, 941-GU instead of 941

## Plane Board

**Project:** Cornerstone Payroll (CPR)
**URL:** https://plane.shimizu-technology.com

## Links

- [PRD](PRD.md) — Product Requirements Document
- [Build Plan](BUILD_PLAN.md) — Tactical plan
- [Future Improvements](FUTURE_IMPROVEMENTS.md)
