/** @vitest-environment node */
import { describe, expect, it } from 'vitest';
import { formatPhone } from './display-phone';

describe('formatPhone', () => {
  it.each([
    ['+16715550162', '(671) 555-0162'],
    ['+1 671 555-0162', '(671) 555-0162'],
    ['(671) 555-0162', '(671) 555-0162'],
    ['6715550162', '(671) 555-0162'],
    ['555-0162', '(671) 555-0162'],
    ['12025550162', '(202) 555-0162'],
    ['202.555.0162', '(202) 555-0162'],
  ])('formats %s as %s', (value, expected) => {
    expect(formatPhone(value)).toBe(expected);
  });

  it.each(['+1 416 555-0162', '+1 242 555-0162', '+63 917 555 0162', '+65 6555 0162', '  +81 3 5555 0162  ', '+1 671 555', '671-555-0162 ext. 4'])(
    'preserves the input %j',
    (value) => expect(formatPhone(value)).toBe(value),
  );

  it.each([null, undefined, ''])('returns an empty value for %j', (value) => {
    expect(formatPhone(value)).toBe('');
  });
});
