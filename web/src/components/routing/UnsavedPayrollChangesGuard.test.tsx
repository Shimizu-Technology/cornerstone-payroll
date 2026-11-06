// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { useState } from 'react';
import { createMemoryRouter, Link, RouterProvider } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { confirmPayrollScopeChange } from '@/lib/payroll-scope-change';
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

it('asks again after an accepted tab change when the worksheet stays mounted', async () => {
  const router = createMemoryRouter([{ path: '*', element: <Worksheet /> }], { initialEntries: ['/work'] });
  render(<RouterProvider router={router} />);
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '10' } });
  await router.navigate('/reports');
  fireEvent.click(screen.getByText('Save'));
  await router.navigate('/work');
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '19' } });
  confirm.mockReturnValue(false);
  fireEvent.click(screen.getByText('Employees'));
  expect(confirm).toHaveBeenCalledTimes(2);
  expect(router.state.location.pathname).toBe('/work');
  expect((screen.getByLabelText('Hours') as HTMLInputElement).value).toBe('19');
});

it('reuses consent for scope synchronization only until the operation finishes', async () => {
  setup();
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '17' } });
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
  expect(confirmPayrollScopeChange()).toBe(true);
  expect(confirmPayrollScopeChange()).toBe(true);
  expect(confirm).toHaveBeenCalledOnce();
  await new Promise(resolve => window.setTimeout(resolve, 0));
  confirm.mockReturnValue(false);
  expect(confirmPayrollScopeChange()).toBe(false);
  expect(confirm).toHaveBeenCalledTimes(2);
  expect((screen.getByLabelText('Hours') as HTMLInputElement).value).toBe('17');
});

it('asks with a page-specific message when one is provided', async () => {
  function History() {
    return <><UnsavedPayrollChangesGuard dirty message="Your history edits aren’t saved yet. Leave anyway?" /><Link to="/employees">Employees</Link></>;
  }
  const router = createMemoryRouter([{ path: '/history', element: <History /> }, { path: '/employees', element: <p>Employees page</p> }], { initialEntries: ['/history'] });
  render(<RouterProvider router={router} />);
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  fireEvent.click(screen.getByText('Employees'));
  expect(confirm).toHaveBeenCalledWith('Your history edits aren’t saved yet. Leave anyway?');
  expect(router.state.location.pathname).toBe('/history');
});
