import { expect, it } from 'vitest';
import { contactEmailErrorMessage } from './contact-email-errors';

it('explains each refused email reason in plain words', () => {
  const body = (code: string) => ({ error: 'Validation failed', contact_validation: { email_error_code: code } });
  expect(contactEmailErrorMessage(body('placeholder_email'))).toBe("Not a real email. Use the employee's own address.");
  expect(contactEmailErrorMessage(body('recipient_not_allowed'))).toBe("Email from this client's account can't go to this address. Use a different address.");
  expect(contactEmailErrorMessage(body('invalid_email'))).toMatch(/Check it for typos/);
});

it('leaves other errors to the server message', () => {
  expect(contactEmailErrorMessage({ contact_validation: { same_person_confirmation_required: true } })).toBeNull();
  expect(contactEmailErrorMessage({ contact_validation: { email_error_code: 'something_new' } })).toBeNull();
  expect(contactEmailErrorMessage(null)).toBeNull();
});
