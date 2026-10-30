import { render, screen } from '@testing-library/react';
import type { ComponentProps } from 'react';
import { MemoryRouter } from 'react-router';
import { describe, expect, it } from 'vitest';
import { PayRunBlockers } from './PayRunBlockers';

const note = "Prior-period void history needs accountant review; this paycheck's Social Security/Medicare is unaffected. Historical tax and filing review remains open.";
const props = {
  payPeriod: {
    payroll_items: [{ tax_rule_snapshot: { annual_fica_context: { history_review_open: true, note } } }],
    compliance_warnings: [note],
  },
} as ComponentProps<typeof PayRunBlockers>;

describe('FICA history disclosure', () => {
  it('keeps the review note visible at approval without labelling it a workweek problem', () => {
    render(<MemoryRouter><PayRunBlockers {...props} part="approval" /></MemoryRouter>);
    expect(screen.getByText('Prior-period payroll review remains open')).toBeInTheDocument();
    expect(screen.getByText(note)).toBeInTheDocument();
    expect(screen.queryByText('Review settings')).not.toBeInTheDocument();
  });

  it('does not duplicate the note or attach unrelated settings actions', () => {
    render(<MemoryRouter><PayRunBlockers {...props} /></MemoryRouter>);
    expect(screen.getAllByText(note)).toHaveLength(1);
    expect(screen.queryByText('Review settings')).not.toBeInTheDocument();
  });
});
