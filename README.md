# Cornerstone Payroll

Guam-specific payroll processing for Cornerstone Tax Services.

## Why This Exists

No major payroll software (Gusto, ADP, Check.com) supports Guam. QuickBooks requires mainland US addresses and needs manual check cleanup. This module solves both problems with native Guam tax support.

## Status

**Phase 1: Internal Payroll MVP** (In Planning)
- 4 employees, biweekly, hourly + salary
- Guam territorial income tax (mirrors federal brackets)
- FICA (Social Security + Medicare)
- Pay stub and check PDF generation

See [PRD.md](PRD.md) for full product requirements.

## Architecture Decision

This will be built as a **module within the existing Cornerstone Tax app** (`cornerstone-tax` repo), not as a standalone application. Rationale:
- Shared auth (Clerk), shared employee/client data
- One deployment, one database
- Can extract later if it becomes its own SaaS product

This repo holds planning documents (PRD, research). Code lives in `Shimizu-Technology/cornerstone-tax`.

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
- [Cornerstone Tax repo](https://github.com/Shimizu-Technology/cornerstone-tax) — Where the code will live
