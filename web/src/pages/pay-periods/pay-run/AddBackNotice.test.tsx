// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { AddBackNotice } from './AddBackNotice';

afterEach(cleanup);
it('lists restored amounts, then each amount staff still enter and where', () => {
  render(<AddBackNotice result={{ employee_id: 7, employee_name: 'Avery Monroe', restored: [{ kind: 'loan', label: 'Loan', amount: '159.1' }, { kind: 'tips', label: 'Tips', amount: '20.0' }],
    not_restored: [{ kind: 'component', label: 'Uniform repayment', amount: '20.0', reason: "Imported components must use this payroll's pay date. Add it in Edit payroll." }] }} />);
  expect(screen.getByText("Avery Monroe is back. Restored from the import: Loan $159.10, Tips $20.00. Hours aren't brought back. Enter hours, then calculate.")).toBeTruthy();
  expect(screen.getByText('Not brought back:')).toBeTruthy();
  expect(screen.getByRole('listitem').textContent).toBe("Uniform repayment $20.00: Imported components must use this payroll's pay date. Add it in Edit payroll.");
});
it('keeps the plain hours reminder when the import had nothing for them', () => {
  render(<AddBackNotice result={{ employee_id: 7, employee_name: 'Casey Manual', restored: [], not_restored: [] }} />);
  expect(screen.getByText("Casey Manual is back. Hours aren't brought back. Enter hours or import again.")).toBeTruthy();
  // Announcing is the job of the region that stays mounted where staff acted.
  expect(screen.queryByRole('status')).toBeNull();
  expect(screen.queryByRole('list')).toBeNull();
});

it('says hours are entered once they are saved', () => {
  render(<AddBackNotice hoursEntered result={{ employee_id: 7, employee_name: 'Avery Monroe', restored: [{ kind: 'loan', label: 'Loan', amount: '159.1' }], not_restored: [] }} />);
  expect(screen.getByText('Avery Monroe is back. Restored from the import: Loan $159.10. Hours are entered.')).toBeTruthy();
});

it('says no hours once staff answer No hours this period and something is still left to enter', () => {
  render(<AddBackNotice noHours result={{ employee_id: 7, employee_name: 'Wendy Daniel', restored: [{ kind: 'tips', label: 'Tips', amount: '70.33' }],
    not_restored: [{ kind: 'bonus', label: 'Bonus', amount: '25.0', enter_by_hand: true, reason: 'The import was replaced by newer files. Enter it in the Hours worksheet.' }] }} />);
  expect(screen.getByText('Wendy Daniel is back. Restored from the import: Tips $70.33. No hours this period.')).toBeTruthy();
});
