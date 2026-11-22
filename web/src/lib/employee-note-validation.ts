export interface SensitiveNoteMatch {
  kind: 'ssn' | 'bank_or_card';
  message: string;
}

// Mirrors api/app/models/employee_note.rb as an early client-side warning.
// The backend remains authoritative and enforces the same rules on note bodies
// (on create) and hide reasons.
const SSN_SEPARATED_PATTERN = /(?<![\d-])\d{3}([- .])\d{2}\1\d{4}(?![\d-])/;
const SSN_CONTEXT_BEFORE_PATTERN =
  /\b(?:ssn|social\s+security|ss#|itin|tin|tax\s*id)(?=\d|[^a-zA-Z])[^0-9\r\n;]{0,20}?(?:\r?\n[^0-9\r\n;]{0,10}?)?(?<!\d)\d{9}(?!\d)/i;
const SSN_CONTEXT_AFTER_PATTERN =
  /(?<!\d)\d{9}(?!\d)[^0-9\r\n;]{0,12}?(?:\r?\n[^0-9\r\n;]{0,8}?)?\b(?:ssn|social\s+security|ss#|itin|tin|tax\s*id)(?![a-zA-Z])/i;

const GUAM_PHONE_PATTERN = /^671\d{7}$/;
const BANK_ACCOUNT_BEFORE_PATTERN =
  /\b(?:acct\.?|account|routing|aba|dd|direct\s+deposit|bank|checking|savings)(?=\d|[^a-zA-Z])[^0-9\r\n;]{0,25}?(?:\r?\n[^0-9\r\n;]{0,10}?)?(?<!\d)(\d{10,17})(?!\d)/gi;
const BANK_ACCOUNT_AFTER_PATTERN =
  /(?<!\d)(\d{10,17})(?!\d)[^0-9\r\n;]{0,15}?(?:\r?\n[^0-9\r\n;]{0,8}?)?\b(?:acct\.?|account|routing|aba|dd|direct\s+deposit|bank|checking|savings)(?![a-zA-Z])/gi;
const DIRECT_ACCOUNT_BEFORE_PATTERN =
  /\b(?:acct\.?|account|routing|aba|checking|savings)(?:(?=\d)|(?:[ \t]*(?:no\.?|num\.?|number|ending(?:[ \t]+in)?))?[ \t:#-]{0,5}(?:\r?\n[ \t:#-]{0,5})?)(?<!\d)\d{10,17}(?!\d)/i;
const DIRECT_ACCOUNT_AFTER_PATTERN =
  /(?<!\d)\d{10,17}(?!\d)[ \t]{0,3}(?:(?:is|was)[ \t]+(?:the|my|her|his|their|our)[ \t]+)?(?:acct\.?|account|routing|aba|checking|savings)(?![a-zA-Z])/i;
const ROUTING_BEFORE_PATTERN =
  /\b(?:routing|aba)(?=\d|[^a-zA-Z])[^0-9\r\n;]{0,20}?(?:\r?\n[^0-9\r\n;]{0,10}?)?(?<!\d)\d{9}(?!\d)/i;
const ROUTING_AFTER_PATTERN =
  /(?<!\d)\d{9}(?!\d)[^0-9\r\n;]{0,12}?(?:\r?\n[^0-9\r\n;]{0,8}?)?\b(?:routing|aba)(?![a-zA-Z])/i;

const CARD_BARE_PATTERN = /(?<![\d-])\d{13,19}(?![\d-])/;
const CARD_GROUPED_PATTERN =
  /(?<![\d-])(?:\d{4}([- ])\d{4}\1\d{4}\1\d{4}(?:\1\d{3})?|\d{4}([- ])\d{6}\2\d{4,5})(?![\d-])/;

function containsSsn(text: string): boolean {
  return (
    SSN_SEPARATED_PATTERN.test(text)
    || SSN_CONTEXT_BEFORE_PATTERN.test(text)
    || SSN_CONTEXT_AFTER_PATTERN.test(text)
  );
}

function matchesNonGuamPhoneBankAccount(text: string, pattern: RegExp): boolean {
  for (const match of text.matchAll(pattern)) {
    const digits = match[1];
    if (digits && !GUAM_PHONE_PATTERN.test(digits)) {
      return true;
    }
  }
  return false;
}

function containsBankAccount(text: string): boolean {
  return (
    DIRECT_ACCOUNT_BEFORE_PATTERN.test(text)
    || DIRECT_ACCOUNT_AFTER_PATTERN.test(text)
    || ROUTING_BEFORE_PATTERN.test(text)
    || ROUTING_AFTER_PATTERN.test(text)
    || matchesNonGuamPhoneBankAccount(text, BANK_ACCOUNT_BEFORE_PATTERN)
    || matchesNonGuamPhoneBankAccount(text, BANK_ACCOUNT_AFTER_PATTERN)
  );
}

function containsCardNumber(text: string): boolean {
  return CARD_BARE_PATTERN.test(text) || CARD_GROUPED_PATTERN.test(text);
}

export function detectSensitiveNoteContent(
  rawText: string,
  subject = 'This draft',
): SensitiveNoteMatch | null {
  if (!rawText.trim()) return null;
  // Match the backend, which normalizes no-break and narrow spaces.
  const text = rawText.replace(/[\u00A0\u2007\u202F]/g, ' ');

  if (containsSsn(text)) {
    return {
      kind: 'ssn',
      message:
        `${subject} looks like it contains an SSN or 9-digit tax ID. Remove SSNs, bank account numbers, or card numbers before saving.`,
    };
  }

  if (containsBankAccount(text) || containsCardNumber(text)) {
    return {
      kind: 'bank_or_card',
      message:
        `${subject} looks like it contains a bank account or card number. Remove SSNs, bank account numbers, or card numbers before saving.`,
    };
  }

  return null;
}
