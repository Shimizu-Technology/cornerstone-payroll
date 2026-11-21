import { describe, expect, it } from 'vitest';
import { formatContinuingNumber, parseNumberWidth } from './invoiceNumber';

describe('formatContinuingNumber', () => {
  it('pads to the chosen width and never cuts a longer number', () => {
    expect(formatContinuingNumber(7055, 5)).toBe('07055');
    expect(formatContinuingNumber(7055, null)).toBe('7055');
    expect(formatContinuingNumber(7055, 3)).toBe('7055');
  });

  it('reads a blank or invalid width as no padding', () => {
    expect(parseNumberWidth('')).toBeNull();
    expect(parseNumberWidth(' 5 ')).toBe(5);
    expect(parseNumberWidth('0')).toBeNull();
    expect(parseNumberWidth('13')).toBeNull();
    expect(parseNumberWidth('4.5')).toBeNull();
  });
});
