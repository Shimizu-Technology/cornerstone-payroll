# Gates

Application source 36b291d1, including staging-v2 ce12d1da. Final evidence-only commits leave the web tree unchanged: `addd1426db57cf2c29ff16349cac5414ea62d6ad`.

| Gate | Result |
| --- | --- |
| npm ci | Passed |
| npm audit --audit-level=moderate | Passed; 0 vulnerabilities |
| npm run gate | TypeScript, zero-warning lint, 131 files / 1,242 tests, production build passed |
| test:e2e:public | 131 passed; 0 failed, skipped or flaky |
| test:e2e:release | 45 passed; 0 failed, skipped or flaky |
| test:e2e:refresh | 10 passed; 0 failed, skipped or flaky |
| test:e2e:pay-items | 24 passed; 0 failed, skipped or flaky |
| Axe | 32 scans; zero #377 required-family violations; existing advisories classified in README |
| Impeccable 4.6.0 | No findings |
| Viewport acceptance | 18 passed |
| Read-only Reports | 12 passed |
| Interaction/navigation | 4 passed |
| Saved lifecycle + dialog/motion | 12 passed receipts |

Backend specs were not rerun under the lead’s explicit C web-only gate. API tree equals ce12d1da; no API changes belong to C. All four browser lanes used fresh owned database/server launches after integrating #385. The public lane was refreshed after the final Details accessible-name correction; all gates cover the final application source. CI on the pushed head remains a separate merge gate.

Raw stdout, JSON browser reports and earlier red attempts remain at the local evidence root documented in METHODS.md. CodeRabbit returned four valid findings, addressed in review round 1 with thread replies after push. Lead re-review and merge remain pending.

Review-round gate evidence is in pr-c/review-1/: verified-gate/gate-receipts.jsonl records the successful full gate; e2e-*.log contains the four green browser JSON reports. Earlier failed attempts are preserved and explained in REVIEW-1.md. No test timeouts were increased. The final public run started after all source/test fixes.
