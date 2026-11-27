// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { afterEach, expect, it } from 'vitest';
import { TippedOccupationCodeSelect } from './TippedOccupationCodeSelect';

function Picker() {
  const [code, setCode] = useState('');
  return (
    <>
      <TippedOccupationCodeSelect codes={{ '102': 'Wait Staff', '105': 'Chefs and Cooks' }} value={code} onChange={setCode} />
      <button type="button">Next field</button>
    </>
  );
}

afterEach(cleanup);

it('keeps the list open when its scrollbar takes focus', () => {
  render(<Picker />);
  const input = screen.getByRole('combobox');
  act(() => input.focus());
  const list = screen.getByRole('listbox');

  fireEvent.mouseDown(list);
  expect(document.activeElement).toBe(list);
  expect(screen.getByRole('listbox')).toBe(list);

  act(() => screen.getByRole('button', { name: 'Next field' }).focus());
  expect(screen.queryByRole('listbox')).toBeNull();
});

it('keeps the touch target mounted through input blur and selects it on tap', () => {
  render(<Picker />);
  act(() => screen.getByRole('combobox').focus());
  const option = screen.getByRole('option', { name: /Wait Staff/ });

  fireEvent.touchStart(option);
  expect(document.activeElement).toBe(screen.getByRole('listbox'));
  expect(option.isConnected).toBe(true);
  fireEvent.touchEnd(option);
  fireEvent.click(option);

  expect(screen.queryByRole('listbox')).toBeNull();
  expect(screen.getByText('102 · Wait Staff')).toBeTruthy();
});

it('starts a fresh query when typing immediately after a keyboard choice', async () => {
  const user = userEvent.setup();
  render(<Picker />);
  await user.click(screen.getByRole('combobox'));
  await user.keyboard('wait{ArrowDown}{Enter}');
  expect(screen.getByText('102 · Wait Staff')).toBeTruthy();

  await user.keyboard('cook');
  expect(screen.getByRole('combobox')).toHaveProperty('value', 'cook');
  expect(screen.getByRole('option', { name: /Chefs and Cooks/ })).toBeTruthy();
});
