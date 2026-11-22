import { describe, expect, it } from 'vitest';
import { detectSensitiveNoteContent } from './employee-note-validation';

describe('detectSensitiveNoteContent', () => {
  it.each([
    ['dashed SSN', 'Employee SSN is 123-45-6789.', 'ssn'],
    ['space-separated SSN', 'Verified 123 45 6789 on form', 'ssn'],
    ['dot-separated SSN', 'Listed as 123.45.6789 on intake', 'ssn'],
    ['glued SSN prefix + 9 digits', 'SSN123456789', 'ssn'],
    ['SSN label + bare 9 digits', 'SSN: 123456789', 'ssn'],
    ['Tax ID label + bare 9 digits', 'Tax ID 123456789 on W-4', 'ssn'],
    ['bare 9 digits followed by SSN label', '123456789 (SSN)', 'ssn'],
    ['10-digit account near acct', 'Direct deposit acct 1234567890', 'bank_or_card'],
    ['12-digit account near account', 'Direct deposit account 123456789012', 'bank_or_card'],
    ['17-digit account near DD', 'DD #12345678901234567', 'bank_or_card'],
    ['11-digit account near bank', 'Bank 12345678901', 'bank_or_card'],
    ['9-digit routing near routing', 'Routing 021000021 for payroll', 'bank_or_card'],
    ['card 4-4-4-4 hyphenated', 'Card 4111-1111-1111-1111 on file', 'bank_or_card'],
    ['card 4-4-4-4 spaced', 'Card 4111 1111 1111 1111 on file', 'bank_or_card'],
    ['card 4-6-5 hyphenated', 'Amex 3782-822463-10005', 'bank_or_card'],
    ['card 4-6-5 spaced', 'Amex 3782 822463 10005', 'bank_or_card'],
    ['card 4-4-4 hyphenated', 'Partial 4111-1111-1111', 'bank_or_card'],
    ['card 4-4-4 spaced', 'Partial 4111 1111 1111', 'bank_or_card'],
    ['card 4-4-4-1', '4111-1111-1111-1', 'bank_or_card'],
    ['card 4-4-4-4-3', '4111-1111-1111-1111-123', 'bank_or_card'],
    ['bare 13-digit card', '4111111111111', 'bank_or_card'],
    ['bare 16-digit card', '4111111111111111', 'bank_or_card'],
    ['bare 19-digit card', '4111111111111111111', 'bank_or_card'],
  ] as const)('flags %s', (_label, text, expectedKind) => {
    const result = detectSensitiveNoteContent(text);
    expect(result?.kind).toBe(expectedKind);
  });

  it.each([
    ['Guam ZIP+4', 'Mailing address Tamuning, GU 96913-2716.'],
    ['generic ZIP+4', 'Updated ZIP to 12345-6789 per employee.'],
    ['dashed EIN', 'Employer EIN 66-0970313 confirmed on W-2.'],
    ['bare EIN without dash', 'Company EIN 660970313 verified on notice.'],
    ['hyphenated Guam phone', 'Call 671-555-1234 about missing hours.'],
    ['parenthesized Guam phone', 'Phone (671) 555-1234 confirmed.'],
    ['bare 10-digit Guam phone', 'Reached employee at 6715551234.'],
    ['ISO dates and date range', 'Pay period 2026-11-22 2026-11-29 reviewed on 11/22/2026.'],
    ['money amounts', 'Bonus $1,234,567.89 adjusted by $45.50 after review.'],
    ['check number', 'Reissued check #1042 after stop-payment.'],
    ['mixed separator 3-2-4', 'Code 123-45 6789 is not an SSN format.'],
  ] as const)('allows %s', (_label, text) => {
    expect(detectSensitiveNoteContent(text)).toBeNull();
  });
});
