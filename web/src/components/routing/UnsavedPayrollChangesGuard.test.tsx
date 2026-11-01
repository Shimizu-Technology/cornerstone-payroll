// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { useState } from 'react';
import { createMemoryRouter, Link, RouterProvider } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { UnsavedPayrollChangesGuard } from './UnsavedPayrollChangesGuard';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });
function Worksheet() {
  const [value, setValue] = useState('');
  return <><UnsavedPayrollChangesGuard dirty={value !== ''} /><input aria-label="Hours" value={value} onChange={event => setValue(event.target.value)} /><Link to="/employees">Employees</Link><button onClick={() => setValue('')}>Save</button></>;
}
function setup() {
  const router = createMemoryRouter([{ path: '/work', element: <Worksheet /> }, { path: '/employees', element: <p>Employees page</p> }], { initialEntries: ['/employees', '/work'], initialIndex: 1 });
  render(<RouterProvider router={router} />);
  return router;
}
it('blocks browser Back with dirty hours and permits it after saving', async () => {
  const router = setup();
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '10' } });
  await router.navigate(-1);
  expect(confirm).toHaveBeenCalledOnce();
  expect((screen.getByLabelText('Hours') as HTMLInputElement).value).toBe('10');
  fireEvent.click(screen.getByText('Save'));
  await router.navigate(-1);
  await screen.findByText('Employees page');
  expect(confirm).toHaveBeenCalledOnce();
});
it('warns on reload only while dirty and removes the handler after leaving', async () => {
  setup();
  expect(window.dispatchEvent(new Event('beforeunload', { cancelable: true }))).toBe(true);
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '10' } });
  expect(window.dispatchEvent(new Event('beforeunload', { cancelable: true }))).toBe(false);
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  fireEvent.click(screen.getByText('Employees'));
  await screen.findByText('Employees page');
  expect(window.dispatchEvent(new Event('beforeunload', { cancelable: true }))).toBe(true);
});
