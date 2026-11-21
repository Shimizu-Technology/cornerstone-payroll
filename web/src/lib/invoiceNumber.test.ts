import { describe, expect, it } from 'vitest';
import { formatContinuingNumber, NUMBER_WIDTH_ERROR, numberWidthForSave, readNumberWidth } from './invoiceNumber';

describe('formatContinuingNumber', () => {
  it('pads to the chosen width and never cuts a longer number', () => {
    expect(formatContinuingNumber(7055, 5)).toBe('07055');
    expect(formatContinuingNumber(7055, null)).toBe('7055');
    expect(formatContinuingNumber(7055, 3)).toBe('7055');
  });
});

describe('readNumberWidth', () => {
  it('treats blank as no padding and invalid input as an error, not as blank', () => {
    expect(readNumberWidth('')).toEqual({ value: null, error: null });
    expect(readNumberWidth(' 5 ')).toEqual({ value: 5, error: null });
    for (const bad of ['0', '13', '2.5', '-3', 'five']) expect(readNumberWidth(bad)).toEqual({ value: null, error: NUMBER_WIDTH_ERROR });
  });
});

describe('numberWidthForSave', () => {
  it('blocks saving an invalid width on a continuing sequence', () => {
    expect(numberWidthForSave('continuing', '13')).toEqual({ ok: false, error: NUMBER_WIDTH_ERROR });
    expect(numberWidthForSave('continuing', '')).toEqual({ ok: true, value: null });
    expect(numberWidthForSave('continuing', '5')).toEqual({ ok: true, value: 5 });
  });

  it('keeps the saved width when the box is hidden on a yearly profile', () => {
    expect(numberWidthForSave('yearly', '13')).toEqual({ ok: true, value: undefined });
  });
});
