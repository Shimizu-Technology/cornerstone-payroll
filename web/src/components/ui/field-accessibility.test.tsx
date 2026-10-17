// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { Input } from './input';
import { Select } from './select';

afterEach(cleanup);

it('gives repeated controls distinct stable names and associated error messages', () => {
  const view = render(<><Input label="Rate" error="Enter the first rate" /><Input label="Rate" helperText="Second rate" />
    <Select label="Frequency" error="Choose a frequency" options={[{ value: 'weekly', label: 'Weekly' }]} /></>);
  const rates = screen.getAllByLabelText('Rate');
  expect(rates[0].id).not.toBe(rates[1].id);
  const firstId = rates[0].id;
  for (const control of [...rates, screen.getByLabelText('Frequency')]) {
    const description = control.getAttribute('aria-describedby');
    expect(description).toBeTruthy();
    expect(document.getElementById(description!)).toBeTruthy();
  }
  expect(rates[0].getAttribute('aria-invalid')).toBe('true');
  expect(document.getElementById(rates[0].getAttribute('aria-describedby')!)?.textContent).toBe('Enter the first rate');
  view.rerender(<><Input label="Rate" error="Updated error" /><Input label="Rate" helperText="Second rate" />
    <Select label="Frequency" error="Choose a frequency" options={[{ value: 'weekly', label: 'Weekly' }]} /></>);
  expect(screen.getAllByLabelText('Rate')[0].id).toBe(firstId);
});
