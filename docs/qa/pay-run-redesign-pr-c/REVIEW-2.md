# Hours breakdown follow-up

Application commit `72e5cc30` fixes the last lead finding after approval of the previous eight fixes. Desktop and phone use the same hours readout. Salary and zero-hour contractor rows omit the reg/OT subline. Other rows show it only when the two formatted components sum to the displayed total. Multi-rate or other mismatched raw hours therefore cannot contradict the total. Footer totals still use `registerTotals`; gross, deductions and net remain saved values.

Six regression cases cover matching hourly hours, mismatched hours, salary with and without displayed hours, and flat-fee contractors with recorded or zero raw hours. Each asserts desktop and phone presentation and an unchanged footer. The reproduction failed all six new cases before the fix (three existing tests passed); the targeted file now passes all nine. Raw red/green logs are retained here.

The lead requested the full web gate and release lane for this small follow-up. Public, refresh and pay-items receipts from the accepted previous round remain historical evidence; they are not represented as rerun on this change. No API changes or backend specs belong to this round.

The full web gate passed TypeScript, zero-warning lint, **131 files / 1,248 tests**, and the production build on application commit `72e5cc30`. The release lane passed **45 tests**, with zero failures, skips or flaky results. Six headless browser checks passed at 1280×800 and 390×844: flat-fee shows 0.00 with no contradictory split, salary shows its displayed hours without the split, and hourly shows 18.00 with 16.00 reg + 2.00 OT. All checks asserted no page or main-content horizontal overflow. The synthetic response overrides changed presentation fields only; no saved payroll amounts were changed.

[Desktop worst flags](worst-flags-1280.png) · [Phone worst flags](worst-flags-390.png) · [Six browser receipts](hours-qa.json). Previous contact sheets and measurements remain the accepted review-round-1 evidence; these two stress captures are refreshed for this hours-only follow-up.

Raw logs, red/green reproduction, complete web gate, release JSON report and cleanup receipts: `output/payroll-aire-review-2026-10-24/impl/payroll-redesign/pr-c/review-2/`.

The first browser-script attempt encountered an extra blank line in rendered innerText; the assertion now normalizes repeated line breaks. That failed attempt is retained as ui-first-whitespace-assertion.log. The final six checks passed. All owned servers, Chromium processes and three private databases were cleaned; the nine assigned ports are free and lifecycle reports no active owned resources. Borrowed/protected resources were unchanged.
