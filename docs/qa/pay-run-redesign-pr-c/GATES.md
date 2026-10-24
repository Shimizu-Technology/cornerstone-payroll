# Gates

Application source e4640d1d, including staging-v2 ce12d1da. Final evidence-only commits leave the web tree unchanged: `224508b797b9f2bb340af34563f80a1737b3c58d`.

| Gate | Result |
| --- | --- |
| npm ci | Passed |
| npm audit --audit-level=moderate | Passed; 0 vulnerabilities |
| npm run gate | TypeScript, zero-warning lint, 130 files / 1,230 tests, production build passed |
| test:e2e:public | 131 passed; 0 failed, skipped or flaky |
| test:e2e:release | 45 passed; 0 failed, skipped or flaky |
| test:e2e:refresh | 10 passed; 0 failed, skipped or flaky |
| test:e2e:pay-items | 24 passed; 0 failed, skipped or flaky |
| Axe | 30 scans; zero #377 required-family violations; existing advisories classified in README |
| Impeccable 4.6.0 | No findings |
| Viewport acceptance | 18 passed |
| Read-only Reports | 12 passed |
| Interaction/navigation | 4 passed |
| Saved lifecycle + dialog/motion | 12 passed receipts |

Backend specs were not rerun under the lead’s explicit C web-only gate. API tree equals ce12d1da; no API changes belong to C. All four browser lanes used fresh owned database/server launches after integrating #385. The public lane was refreshed after the final Details accessible-name correction; all gates cover the final application source. CI on the pushed head remains a separate merge gate.

Raw stdout, JSON browser reports and earlier red attempts remain at the local evidence root documented in METHODS.md. CodeRabbit is requested once; independent lead review and merge remain pending.
