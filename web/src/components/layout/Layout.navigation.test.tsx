// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { Link, MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { Layout } from './Layout';

const scope = vi.hoisted(() => ({ organization: 1, company: 1, practicePortal: false }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 1, name: 'Synthetic client', active: true, test_workspace: scope.practicePortal, practice_portal: scope.practicePortal, workspace_can_write: !scope.practicePortal }, activeCompanyId: scope.company, activeOrganizationId: scope.organization }) }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { role: scope.practicePortal ? 'client' : 'admin' } }) }));
vi.mock('./CommandPalette', () => ({ CommandPalette: ({ open }: { open: boolean }) => open ? <div role="dialog" aria-label="Command palette"><input autoFocus aria-label="Command search" /></div> : null }));
vi.mock('./Sidebar', () => ({ Sidebar: ({ onNavigate, onOpenCommandPalette }: { onNavigate?: () => void; onOpenCommandPalette?: () => void }) => <nav><Link to="/employees" onClick={onNavigate}>Employees</Link><button>Client settings</button><button onClick={onOpenCommandPalette}>Command menu</button></nav> }));
beforeEach(() => { scope.organization = 1; scope.company = 1; scope.practicePortal = false; vi.spyOn(HTMLElement.prototype, 'offsetParent', 'get').mockImplementation(function (this: HTMLElement) { return this.parentElement; }); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

function view(): React.ReactElement {
  return <MemoryRouter><Routes><Route element={<Layout />}><Route path="/" element={<button>Background action</button>} /><Route path="/employees" element={<h1>Employees page</h1>} /></Route></Routes></MemoryRouter>;
}

it('moves focus into phone navigation, contains Tab in both directions, inerts the page, and returns focus on Escape', async () => {
  const user = userEvent.setup();
  const { container } = render(view());
  const trigger = screen.getByRole('button', { name: 'Open navigation' });
  await user.click(trigger);
  const dialog = screen.getByRole('dialog', { name: 'Navigation' });
  await waitFor(() => expect(dialog.contains(document.activeElement)).toBe(true));
  expect(container.closest('[inert]')).not.toBeNull();
  const close = within(dialog).getByRole('button', { name: 'Close navigation' });
  close.focus();
  await user.tab();
  expect(dialog.contains(document.activeElement)).toBe(true);
  await user.tab({ shift: true });
  expect(document.activeElement).toBe(close);
  await user.keyboard('{Escape}');
  await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Navigation' })).toBeNull());
  expect(document.activeElement).toBe(trigger);
  expect(container.closest('[inert]')).toBeNull();
});

it('closes phone navigation after selecting a route and on backdrop click', async () => {
  const user = userEvent.setup();
  render(view());
  const trigger = screen.getByRole('button', { name: 'Open navigation' });
  await user.click(trigger);
  await user.click(within(screen.getByRole('dialog', { name: 'Navigation' })).getByRole('link', { name: 'Employees' }));
  await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Navigation' })).toBeNull());
  expect(screen.getByRole('heading', { name: 'Employees page' })).toBeTruthy();
  expect(document.activeElement).toBe(trigger);
  await user.click(trigger);
  const portal = screen.getByRole('dialog', { name: 'Navigation' }).closest('[data-dialog-portal]')!;
  await user.click(portal.querySelector('[data-dialog-backdrop]')!);
  await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Navigation' })).toBeNull());
  expect(document.activeElement).toBe(trigger);
});


it('opens the command menu after the drawer releases its focus and inert background', async () => {
  const user = userEvent.setup();
  render(view());
  await user.click(screen.getByRole('button', { name: 'Open navigation' }));
  const drawer = screen.getByRole('dialog', { name: 'Navigation' });
  await user.click(within(drawer).getByRole('button', { name: 'Command menu' }));
  await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Navigation' })).toBeNull());
  const search = await screen.findByRole('textbox', { name: 'Command search' });
  expect(document.activeElement).toBe(search);
  expect(search.closest('[inert]')).toBeNull();
});

it('retains the global inbox across client switches but remounts it across organizations', () => {
  function InboxDraft(): React.ReactElement {
    const [draft, setDraft] = useState('');
    return <input aria-label="Inbox draft" value={draft} onChange={event => setDraft(event.target.value)} />;
  }
  const scopedView = () => <MemoryRouter initialEntries={['/app/client-inbox']}><Routes><Route element={<Layout />}><Route path="/app/client-inbox" element={<InboxDraft />} /></Route></Routes></MemoryRouter>;
  const result = render(scopedView());
  fireEvent.change(screen.getByLabelText('Inbox draft'), { target: { value: 'Retained filters' } });
  scope.company = 2;
  result.rerender(scopedView());
  expect((screen.getByLabelText('Inbox draft') as HTMLInputElement).value).toBe('Retained filters');
  scope.organization = 2;
  result.rerender(scopedView());
  expect((screen.getByLabelText('Inbox draft') as HTMLInputElement).value).toBe('');
});

it('labels a practice client portal and explains its permitted actions', () => {
  scope.practicePortal = true;
  render(view());
  expect(screen.getByText('Practice copy — no live payroll.')).toBeTruthy();
  expect(screen.getByText(/You can upload files, exchange messages, and review or approve drafts here/)).toBeTruthy();
  expect(screen.queryByText(/You have read-only access/)).toBeNull();
  expect(screen.getByText('Cornerstone Payroll · Client Portal')).toBeTruthy();
});
