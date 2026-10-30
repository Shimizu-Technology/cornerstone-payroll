// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import type { ComponentProps } from 'react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it } from 'vitest';
import { FicaHistoryReviewNotice, PayRunBlockers } from './PayRunBlockers';

const note = "Prior-period void history needs accountant review; this paycheck's Social Security/Medicare is unaffected. Historical tax and filing review remains open.";
const props = {
  payPeriod: {
    annual_fica_review_note: note,
    compliance_warnings: [note],
  },
} as ComponentProps<typeof PayRunBlockers>;

afterEach(cleanup);

describe('FICA history disclosure', () => {
  it('keeps the review note visible at approval without labelling it a workweek problem', () => {
    render(<MemoryRouter><FicaHistoryReviewNotice note={note} /><PayRunBlockers {...props} part="approval" /></MemoryRouter>);
    expect(screen.getByText('Prior-period payroll review remains open')).toBeTruthy();
    expect(screen.getByText(note)).toBeTruthy();
    expect(screen.queryByText('Review settings')).toBeNull();
  });

  it('does not duplicate the note or attach unrelated settings actions', () => {
    render(<MemoryRouter><FicaHistoryReviewNotice note={note} /><PayRunBlockers {...props} /></MemoryRouter>);
    expect(screen.getAllByText(note)).toHaveLength(1);
    expect(screen.queryByText('Review settings')).toBeNull();
  });
});
