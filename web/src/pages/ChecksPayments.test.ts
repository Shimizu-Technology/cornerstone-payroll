// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from 'vitest';
import { initialFormState } from './ChecksPayments';

describe('ChecksPayments form defaults', () => {
  afterEach(() => vi.useRealTimers());

  it("uses Guam's date at Guam New Year, while California is still on Dec 31", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-12-31T14:30:00Z'));

    expect(initialFormState()).toMatchObject({
      payment_date: '2027-01-01', tax_year: '2027', tax_quarter: '1', tax_month: '1',
    });
  });
});
