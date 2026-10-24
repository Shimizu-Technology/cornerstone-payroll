# Gates

Current application/test source: `973f61f2` (UI logic b374803a), including staging-v2 `ce12d1da`. Later evidence-only changes leave web tree `20174b224bdf18800ac73f814eefa607e6ff5754` unchanged.

| Fresh gate | Result |
| --- | --- |
| npm run gate | TypeScript, zero-warning lint, 131 files / 1,259 tests, production build passed |
| test:e2e:release | 45 passed; 0 failed, skipped or flaky |
| test:e2e:refresh | 10 passed; 0 failed, skipped or flaky; includes tab navigation after calculation at both widths |
| Hours presentation | 12 headless checks at 1280×800 / 390×844; no horizontal overflow |

The lead requested these three gates for the five latest comments. Public 131 and pay-items 24 passed in the accepted earlier round and are historical receipts, not represented as rerun on this change. The prior npm ci/audit (0 vulnerabilities), 32 axe scans, 18 viewport checks, 12 read-only Reports checks, 12 saved-outcome/dialog receipts and Impeccable 4.6.0 evidence remain in review round 1.

[Current fixes and evidence](REVIEW-3.md) · [Hours consistency follow-up](REVIEW-2.md) · [Eight accepted initial fixes](REVIEW-1.md). The first web attempt hit an unchanged ChecksPanel timer assertion under host load; its isolated 30 tests and the complete web gate passed on retry without timeout changes. Only the green receipts in pr-c/review-3/final-gate count toward current acceptance. API source equals ce12d1da; no API, migrations or dependencies changed, and backend specs were not rerun. CI on the pushed head remains the lead’s merge gate.
