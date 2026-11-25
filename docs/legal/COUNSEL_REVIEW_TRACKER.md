# Counsel review tracker

Items that need a lawyer's review or approval before **real employees** use the feature they belong to. Work on these items is not held for counsel: the code is built, reviewed, merged and deployed **switched off**, using clearly marked draft wording. Counsel's approved text replaces the draft before a company is switched on for real employees (gate G1 in `docs/MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md` §3).

The demo company uses the same draft wording, so it can be tested end to end before counsel replies.

| # | Item | Where it lives | Status | Blocks |
|---|---|---|---|---|
| 1 | Employee App Terms of Use and Privacy Notice | Employee sign-up clickwrap checkbox and Help links (M4-8b). Version is a build setting today; it moves to the server when final text arrives. | Draft wording; awaiting counsel | Real-employee go-live |
| 2 | Electronic pay statement consent (Guam UETA) | M4-6 consent records and screens | Draft wording; awaiting counsel | Electronic-only pay statements (paper continues in the pilot) |
| 3 | Electronic W-2GU consent disclosure (26 CFR 31.6051-1(j)) | M4-6 consent records and screens; M4-5 W-2GU copies | Draft wording; awaiting counsel | Electronic-only W-2GU (paper continues in the pilot) |
| 4 | W-2GU "tax document available" notice email | M4-5 notice email | Wording follows the regulation; counsel to confirm | Real-employee W-2GU posting |
| 5 | Safeguards Rule review, including whether two-step sign-in must cover employees viewing their own records | M4-1 / two-step sign-in rollout | Awaiting counsel | Real-employee go-live |
| 6 | IRC § 7216 review | Employee app and Cornerstone's use of tax-return data | Awaiting counsel | Real-employee go-live |
| 7 | Breach notification obligations | Incident response section of the WISP addendum | Awaiting counsel | Real-employee go-live |
| 8 | Client Service Agreement and Data Processing Addendum (Cornerstone ↔ Shimizu Technology) | Contract, outside the code | Awaiting counsel | Real-employee go-live (or a counsel-cleared pilot carve-out) |
| 9 | DRT answer on electronic W-2GU copies and truncated SSNs | Agency inquiry (sent by Cornerstone) | Draft letter ready | Electronic-only W-2GU |
| 10 | Pilot carve-out for the first real user, if used instead of full review | Signed by the client's owners and the first user | Not started | First real user only |

## How an item is closed

1. Counsel's approved text or answer is recorded (privately; the review packet and cover email are drafted separately and are not in this public repository).
2. The draft wording in the app is replaced in a normal pull request, reviewed and deployed.
3. This table's status becomes **Approved** with the date and the pull request.

## Related

- Build plan: `docs/MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md` (§3 gates, §4 M4-6, M4-8, §8a)
- Demo company plan: `docs/DEMO_COMPANY_PLAN_2026-11-25.md`
