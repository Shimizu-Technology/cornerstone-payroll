import { describe, expect, it } from 'vitest';
import { detectSensitiveNoteContent } from './employee-note-validation';

describe('detectSensitiveNoteContent', () => {
  it.each([
    ['dashed SSN', 'Employee SSN is 123-45-6789.', 'ssn'],
    ['space-separated SSN', 'Verified 123 45 6789 on form', 'ssn'],
    ['dot-separated SSN', 'Listed as 123.45.6789 on intake', 'ssn'],
    ['glued SSN prefix + 9 digits', 'SSN123456789', 'ssn'],
    ['SSN label + bare 9 digits', 'SSN: 123456789', 'ssn'],
    ['SSN no. + bare 9 digits', 'SSN no. 987654321', 'ssn'],
    ['SSN + newline + bare 9 digits', 'SSN:\n987654321', 'ssn'],
    ['Tax ID label + bare 9 digits', 'Tax ID 123456789 on W-4', 'ssn'],
    ['bare 9 digits followed by SSN label', '123456789 (SSN)', 'ssn'],
    ['10-digit account near acct', 'Direct deposit acct 1234567890', 'bank_or_card'],
    ['Acct no. + 10-digit account', 'Acct no. 1234567890', 'bank_or_card'],
    ['Account #: + 10-digit account', 'Account #: 1234567890', 'bank_or_card'],
    ['DD acct ending + 10-digit account', 'DD acct ending 1234567890', 'bank_or_card'],
    ['10-digit 671 number directly after account keyword', 'Acct no. 6715551234', 'bank_or_card'],
    ['12-digit account near account', 'Direct deposit account 123456789012', 'bank_or_card'],
    ['17-digit account near DD', 'DD #12345678901234567', 'bank_or_card'],
    ['11-digit account near bank', 'Bank 12345678901', 'bank_or_card'],
    ['9-digit routing near routing', 'Routing 021000021 for payroll', 'bank_or_card'],
    ['routing no. + 9-digit routing', 'routing no. 121000358', 'bank_or_card'],
    ['10-digit number near routing', 'routing # 1234567890', 'bank_or_card'],
    ['card 4-4-4-4 hyphenated', 'Card 4111-1111-1111-1111 on file', 'bank_or_card'],
    ['card 4-4-4-4 spaced', 'Card 4111 1111 1111 1111 on file', 'bank_or_card'],
    ['card 4-6-5 hyphenated (Amex)', 'Amex 3782-822463-10005', 'bank_or_card'],
    ['card 4-6-5 spaced (Amex)', 'Amex 3782 822463 10005', 'bank_or_card'],
    ['card 4-6-4 spaced (Diners)', 'Diners card 3056 930902 5904', 'bank_or_card'],
    ['hyphenated SSN label', 'SSN-123-45-6789', 'ssn'],
    ['account label after a phone-shaped number', '6715551234 is the account number', 'bank_or_card'],
    ['no-break space in Social Security label', 'Social\u00A0security 987654321', 'ssn'],
    ['card 4-4-4-4-3 hyphenated (19 digits)', '4111-1111-1111-1111-123', 'bank_or_card'],
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
    ['standalone bare 9-digit reference', 'Reference 660970313 confirmed with client.'],
    ['hyphenated Guam phone', 'Call 671-555-1234 about missing hours.'],
    ['parenthesized Guam phone', 'Phone (671) 555-1234 confirmed.'],
    ['bare 10-digit Guam phone', 'Reached employee at 6715551234.'],
    ['bare Guam phone before direct deposit wording', 'Called Maria at 6715551234 re: direct deposit change'],
    ['bare Guam phone after bank name', 'Bank of Guam called from 6714721234'],
    ['consecutive 4-digit years', 'W-2s for 2024 2025 2026 still missing'],
    ['consecutive 5-digit ZIP codes', 'ZIPs 96913 96910 96929'],
    ['4-4-4 reference code', 'Ref 2026 1122 0001'],
    ['ISO dates and adjacent date range', 'Pay period 2026-11-22 2026-11-29 reviewed on 11/22/2026.'],
    ['money amounts', 'Bonus $1,234,567.89 adjusted by $45.50 after review.'],
    ['check number', 'Reissued check #1042 after stop-payment.'],
    ['mixed separator 3-2-4', 'Code 123-45 6789 is not an SSN format.'],
    ['semicolon clause boundary', 'Updated SSN; reference 660970313.'],
  ] as const)('allows %s', (_label, text) => {
    expect(detectSensitiveNoteContent(text)).toBeNull();
  });
});
