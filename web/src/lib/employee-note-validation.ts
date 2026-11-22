export interface SensitiveNoteMatch {
  kind: 'ssn' | 'bank_or_card';
  message: string;
}

// Mirrors api/app/models/employee_note.rb as an early client-side warning.
// The backend remains authoritative and enforces the same rules on create.
const SSN_SEPARATED_PATTERN = /(?<![\d-])\d{3}([- .])\d{2}\1\d{4}(?![\d-])/;
const SSN_CONTEXT_BEFORE_PATTERN =
  /\b(?:ssn|social\s+security|ss#|itin|tin|tax\s*id)(?=\d|[^a-zA-Z])[^0-9\n.;]{0,20}?(?<!\d)\d{9}(?!\d)/i;
const SSN_CONTEXT_AFTER_PATTERN =
  /(?<!\d)\d{9}(?!\d)[^0-9\n.;]{0,12}?\b(?:ssn|social\s+security|ss#|itin|tin|tax\s*id)(?![a-zA-Z])/i;

const BANK_ACCOUNT_BEFORE_PATTERN =
  /\b(?:acct\.?|account|routing|aba|dd|direct\s+deposit|bank|checking|savings)(?=\d|[^a-zA-Z])[^0-9\n.;]{0,25}?(?<!\d)\d{10,17}(?!\d)/i;
const BANK_ACCOUNT_AFTER_PATTERN =
  /(?<!\d)\d{10,17}(?!\d)[^0-9\n.;]{0,15}?\b(?:acct\.?|account|routing|aba|dd|direct\s+deposit|bank|checking|savings)(?![a-zA-Z])/i;
const ROUTING_BEFORE_PATTERN =
  /\b(?:routing|aba)(?=\d|[^a-zA-Z])[^0-9\n.;]{0,20}?(?<!\d)\d{9}(?!\d)/i;
const ROUTING_AFTER_PATTERN =
  /(?<!\d)\d{9}(?!\d)[^0-9\n.;]{0,12}?\b(?:routing|aba)(?![a-zA-Z])/i;

const CARD_BARE_PATTERN = /(?<![\d-])\d{13,19}(?![\d-])/;
const CARD_GROUPED_PATTERN =
  /(?<![\d-])\d{4,6}([- ])\d{4,6}\1\d{4,6}(?:\1\d{4}\1\d{1,3}|\1\d{1,4})?(?![\d-])/g;

function containsSsn(text: string): boolean {
  return (
    SSN_SEPARATED_PATTERN.test(text)
    || SSN_CONTEXT_BEFORE_PATTERN.test(text)
    || SSN_CONTEXT_AFTER_PATTERN.test(text)
  );
}

function containsBankAccount(text: string): boolean {
  return (
    BANK_ACCOUNT_BEFORE_PATTERN.test(text)
    || BANK_ACCOUNT_AFTER_PATTERN.test(text)
    || ROUTING_BEFORE_PATTERN.test(text)
    || ROUTING_AFTER_PATTERN.test(text)
  );
}

function containsCardNumber(text: string): boolean {
  if (CARD_BARE_PATTERN.test(text)) return true;

  for (const match of text.matchAll(CARD_GROUPED_PATTERN)) {
    const digits = match[0].replace(/[- ]/g, '');
    if (digits.length >= 12 && digits.length <= 19) {
      return true;
    }
  }
  return false;
}

export function detectSensitiveNoteContent(text: string): SensitiveNoteMatch | null {
  if (!text.trim()) return null;

  if (containsSsn(text)) {
    return {
      kind: 'ssn',
      message:
        'This draft looks like it contains an SSN or 9-digit tax ID. Remove SSNs, bank account numbers, or card numbers before saving.',
    };
  }

  if (containsBankAccount(text) || containsCardNumber(text)) {
    return {
      kind: 'bank_or_card',
      message:
        'This draft looks like it contains a bank account or card number. Remove SSNs, bank account numbers, or card numbers before saving.',
    };
  }

  return null;
}
