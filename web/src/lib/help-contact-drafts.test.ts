import { describe, expect, it } from 'vitest';
import { formatPhone, possessive } from './employee-app-text';
import { draftProblems, fromDraft, toDraft } from './help-contact-drafts';

describe('Help contact drafts', () => {
  it('needs a name and a way to reach the person', () => {
    expect(draftProblems(toDraft())).toEqual({
      name: 'Add a name.', reach: 'Add a phone number or an email so employees can reach this person.',
    });
    expect(draftProblems({ ...toDraft(), name: 'Avery', email: 'avery@example.test' })).toEqual({});
    expect(draftProblems({ ...toDraft(), name: 'Avery', phone: '(671) 555-0111' })).toEqual({});
  });

  it('checks the phone and email', () => {
    const problems = draftProblems({ ...toDraft(), name: 'Avery', phone: 'call me', email: 'avery@' });
    expect(problems.phone).toContain('7 to 15 digits');
    expect(problems.email).toContain("doesn't look right");
    expect(draftProblems({ ...toDraft(), name: 'Avery', phone: '555' }).phone).toBeDefined();
  });

  it('drops "text OK" without a phone and trims what it sends', () => {
    expect(fromDraft({ ...toDraft(), name: ' Avery ', role: ' ', email: 'avery@example.test', text_ok: true })).toEqual({
      name: 'Avery', role: null, phone: null, email: 'avery@example.test', text_ok: false,
    });
    expect(fromDraft({ ...toDraft(), name: 'Avery', phone: '671-555-0111', text_ok: true }).text_ok).toBe(true);
  });

  it('gives every row its own key', () => {
    expect(toDraft().key).not.toBe(toDraft().key);
  });
});

describe('employee app text', () => {
  it('makes possessives that read naturally', () => {
    expect(possessive("MoSa's")).toBe("MoSa's");
    expect(possessive('Two Brothers')).toBe("Two Brothers'");
    expect(possessive('Pelican Row Bakery')).toBe("Pelican Row Bakery's");
  });

  it('formats Guam and US numbers and leaves others alone', () => {
    expect(formatPhone('6715550100')).toBe('(671) 555-0100');
    expect(formatPhone('+1 671 555 0100')).toBe('(671) 555-0100');
    expect(formatPhone('5550100')).toBe('555-0100');
    expect(formatPhone('+81 3 1234 5678')).toBe('+81 3 1234 5678');
  });
});
