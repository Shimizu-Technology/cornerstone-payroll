import { expect, it } from 'vitest';
import { errorRecovery } from './error-recovery';
it('does not append the obsolete contribution paragraph to the named Roth setup instructions', () => {
  expect(errorRecovery('Chad D Cruz: Open Employees → Chad D Cruz → Pay setup → Set up retirement and confirm the plan permits designated Roth employee contributions. Add the verified plan document or administrator reference, then calculate payroll again.')).toBeNull();
});

it('adds no generic boilerplate when the message already names the field', () => {
  expect(errorRecovery('Email is required')).toBeNull();
  expect(errorRecovery("Email can't be blank")).toBeNull();
  expect(errorRecovery('Email has already been taken')).toBeNull();
  expect(errorRecovery('The server rejected this file')).toMatch(/contact support/);
});
