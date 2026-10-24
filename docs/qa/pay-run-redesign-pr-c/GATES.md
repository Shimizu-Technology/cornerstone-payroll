# Gates

Final hours-only application source: `72e5cc30`, including staging-v2 `ce12d1da`. Evidence-only changes leave web tree `502d2b4b593d9231ff497e4cc44f9d37f5b71e3c` unchanged.

| Fresh gate | Result |
| --- | --- |
| npm run gate | TypeScript, zero-warning lint, 131 files / 1,248 tests, production build passed |
| test:e2e:release | 45 passed; 0 failed, skipped or flaky |
| Hours presentation | 6 headless checks at 1280×800 / 390×844; no horizontal overflow |

The final lead request narrowed this follow-up to the full web gate and release lane. The accepted previous round passed npm ci, npm audit (0 vulnerabilities), public 131, release 45, refresh 10 and pay-items 24, all with zero failures, skips or flaky results. Those prior-round public/refresh/pay-items receipts are historical evidence, not claimed as rerun on the final hours change. Its 32 axe scans, 18 viewport checks, 12 read-only Reports checks, 12 saved-outcome/dialog receipts and Impeccable 4.6.0 scan remain in the review-round-1 report.

[Last hours fix and fresh stress captures](REVIEW-2.md) · [Accepted eight review fixes](REVIEW-1.md). Raw final-round evidence is in `pr-c/review-2/` under the local evidence root in METHODS.md. Gates were run on 72e5cc30; later commits contain evidence only. API tree equals ce12d1da, with no backend changes, migrations or dependency changes. Backend specs were not rerun under the lead’s web-only C gate. CI on the pushed head remains the lead’s merge gate.
