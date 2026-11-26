// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from 'vitest';
import { cloneFormState, initialFormState } from './ChecksPayments';
import type { NonEmployeeCheck } from '@/types';

describe('ChecksPayments form defaults', () => {
  afterEach(() => vi.useRealTimers());

  it("uses Guam's date at Guam New Year, while California is still on Dec 31", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-12-31T14:30:00Z'));

    expect(initialFormState()).toMatchObject({
      payment_date: '2027-01-01', tax_year: '2027', tax_quarter: '1', tax_month: '1',
    });
  });

  it("fills a clone's missing tax period from Guam's date and keeps the fields it has", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-12-31T14:30:00Z'));
    const source = { payable_to: 'Treasurer of Guam', amount: 10, check_type: 'grt', payment_method: 'check', payment_period_type: 'month' } as NonEmployeeCheck;

    expect(cloneFormState({ ...source, tax_year: null, tax_quarter: null, tax_month: null })).toMatchObject({
      payment_date: '2027-01-01', tax_year: '2027', tax_quarter: '1', tax_month: '1',
    });
    expect(cloneFormState({ ...source, tax_year: 2026, tax_quarter: null, tax_month: 11 })).toMatchObject({
      payment_date: '2027-01-01', tax_year: '2026', tax_quarter: '1', tax_month: '11',
    });
  });
});
