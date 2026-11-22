// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { useState } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { NumericInput } from './numeric-input';

afterEach(cleanup);

function Controlled({ initial, onValueChange, ...props }: { initial: number; onValueChange: (value: number | null) => void; restoreOnEmpty?: boolean }) {
  const [value, setValue] = useState<number | null>(initial);
  return <NumericInput aria-label="Amount" value={value} onValueChange={(next) => { setValue(next); onValueChange(next); }} {...props} />;
}

it('does not report a change when the field is left untouched', () => {
  const onValueChange = vi.fn();
  render(<Controlled initial={12} onValueChange={onValueChange} />);
  const input = screen.getByRole('textbox', { name: 'Amount' });
  fireEvent.focus(input);
  fireEvent.blur(input);
  expect(onValueChange).not.toHaveBeenCalled();
});

it('restores the value from before editing when a restoreOnEmpty field is cleared digit by digit', () => {
  const onValueChange = vi.fn();
  render(<Controlled initial={2026} onValueChange={onValueChange} restoreOnEmpty />);
  const input = screen.getByRole('textbox', { name: 'Amount' }) as HTMLInputElement;
  fireEvent.focus(input);
  for (const draft of ['202', '20', '2', '']) fireEvent.change(input, { target: { value: draft } });
  // A blank field already reports the restored value, so Enter would save 2026.
  expect(onValueChange).toHaveBeenLastCalledWith(2026);
  fireEvent.blur(input);
  expect(input.value).toBe('2026');
});
