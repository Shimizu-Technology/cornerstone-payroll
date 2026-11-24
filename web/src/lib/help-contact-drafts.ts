import type { HelpContact } from '@/services/employee-app-settings-api';

// Editable Help contact rows, and the same checks the server makes.

export interface HelpContactDraft {
  key: string;
  name: string;
  role: string;
  phone: string;
  email: string;
  text_ok: boolean;
}

let draftSequence = 0;

export function toDraft(contact?: HelpContact): HelpContactDraft {
  draftSequence += 1;
  return {
    key: `contact-${draftSequence}`,
    name: contact?.name ?? '',
    role: contact?.role ?? '',
    phone: contact?.phone ?? '',
    email: contact?.email ?? '',
    text_ok: contact?.text_ok ?? false,
  };
}

export function fromDraft(draft: HelpContactDraft): HelpContact {
  const phone = draft.phone.trim() || null;
  return {
    name: draft.name.trim(),
    role: draft.role.trim() || null,
    phone,
    email: draft.email.trim() || null,
    text_ok: phone ? draft.text_ok : false,
  };
}

const EMAIL_PATTERN = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

/** Problems to fix before saving, by field. Mirrors the server's checks. */
export function draftProblems(draft: HelpContactDraft): Partial<Record<'name' | 'phone' | 'email' | 'reach', string>> {
  const problems: Partial<Record<'name' | 'phone' | 'email' | 'reach', string>> = {};
  if (!draft.name.trim()) problems.name = 'Add a name.';
  const phone = draft.phone.trim();
  if (phone) {
    const digits = phone.replace(/\D/g, '');
    if (!/^\+?[\d\s().-]+$/.test(phone) || digits.length < 7 || digits.length > 15) problems.phone = 'Check the phone number. Use 7 to 15 digits.';
  }
  const email = draft.email.trim();
  if (email && !EMAIL_PATTERN.test(email)) problems.email = "That email address doesn't look right.";
  if (!phone && !email) problems.reach = 'Add a phone number or an email so employees can reach this person.';
  return problems;
}
