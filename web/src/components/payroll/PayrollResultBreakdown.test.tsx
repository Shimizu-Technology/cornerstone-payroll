import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { PayrollResultBreakdown, PaycheckRetirementContext, PaycheckWithholdingContext } from './PayrollResultBreakdown';
import type { PayrollItem } from '../../types';

describe('saved paycheck explanation', () => {
  it('shows recurring and one-time bonuses, classified taxes, and employer amounts separately', () => {
    const html = renderToStaticMarkup(<PayrollResultBreakdown disclosure={{
      earnings: [{ label: 'Bonus', amount: 250, source: 'one_time' }, { label: 'Doctor bonus', amount: 100, source: 'employee_default' }],
      other_pay: [{ label: 'Mileage', amount: 100 }],
      taxes: [{ label: 'Medicare (base)', amount: 14.5 }, { label: 'Additional Medicare', amount: 4.5 }, { label: 'Additional W-4 withholding', amount: 25 }],
      deductions: [{ label: 'Loan', amount: 50, treatment: 'post_tax' }],
      employer_contributions: [{ label: 'Employer retirement', amount: 40 }],
      reconciliation: { gross_pay: 1350, other_pay: 100, employee_taxes: 44, other_deductions: 50, net_pay: 1356 },
    }} />);
    for (const label of ['One-time bonus', 'Recurring setup', 'Additional W-4 withholding', 'Employer contributions', 'After-tax deduction', '$1,356.00']) expect(html).toContain(label);
  });

  it('explains the retirement cap and election retained on the paycheck', () => {
    const item: PayrollItem = {
      id: 1,
      employee_id: 2,
      employment_type: 'hourly',
      pay_rate: 25,
      retirement_rule_snapshot: {
        election: { plan_name: 'MoSa 401(k)' },
        annual_limit: { tax_year: 2026, elective_deferral_limit: '24500.0', source_url: 'https://www.irs.gov/retirement-plans' },
        eligible_compensation: '3000.0',
        ytd_employee_deferral_before: '24400.0',
        employee_age_at_year_end: 61,
        roth_catch_up_required: false,
        requested: { traditional: '500.0', roth: '250.0' },
        applied: { traditional: '66.67', roth: '33.33' },
        employer_match: { traditional: '75.0', roth: '0.0', prior_ytd: '900.0' },
        explanations: ['Employee contributions were reduced by the annual plan limit.'],
      },
    };
    const html = renderToStaticMarkup(<PaycheckRetirementContext item={item} />);
    expect(html).toContain('MoSa 401(k)');
    expect(html).toContain('$24,500.00');
    expect(html).toContain('reduced by the annual plan limit');
    expect(html).toContain('View the saved IRS source');
    expect(html).toContain('Employer match YTD before');
    expect(html).toContain('$900.00');
  });
  it('explains the saved annual credit and flags a manual override without using current employee setup', () => {
    const item: PayrollItem = { id: 1, employee_id: 1, employment_type: 'hourly', pay_rate: 25, additional_withholding: 0, withholding_tax_override: 0, tax_rule_snapshot: { w4: { filing_status_entered: 'single', step3_dependent_credit: 2000, election_id: 445, effective_on: '2026-09-07', form_version: 2025, step2_multiple_jobs: false } } };
    const html = renderToStaticMarkup(<PaycheckWithholdingContext item={item} />);
    expect(html).toContain('$2,000.00');
    expect(html).toContain('annual credit');
    expect(html).toContain('Election #445');
    expect(html).toContain('manual federal withholding override of $0.00');
  });
  it('does not substitute current setup when a historical snapshot is unavailable', () => {
    expect(renderToStaticMarkup(<PaycheckWithholdingContext item={{} as PayrollItem} />)).toContain('No W-4 snapshot was retained');
  });
});
