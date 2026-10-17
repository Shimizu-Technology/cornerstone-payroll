// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { FeedbackProvider, useFeedback } from '@/components/ui/action-feedback';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import { Layout } from './Layout';

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  activeCompany: { id: 1, name: 'Synthetic client', active: true },
  activeCompanyId: 1, activeOrganizationId: 1, activeOrganizationName: 'Synthetic organization',
}) }));
vi.mock('./Sidebar', () => ({ Sidebar: () => <nav><a href="/employees">Employees</a></nav> }));
vi.mock('./CommandPalette', () => ({ CommandPalette: () => null }));

afterEach(cleanup);

function FailedAction() {
  const { notify } = useFeedback();
  return <button onClick={() => notify({ tone: 'error', message: 'Synthetic action failed' })}>Fail action</button>;
}

function view(nestedDialogs = false) {
  return <MemoryRouter><FeedbackProvider>
    <Routes><Route element={<Layout />}><Route path="/" element={<FailedAction />} /></Route></Routes>
    {nestedDialogs && <>
      <Dialog open onOpenChange={() => undefined}><DialogContent><DialogTitle>Parent dialog</DialogTitle></DialogContent></Dialog>
      <Dialog open onOpenChange={() => undefined}><DialogContent><DialogTitle>Top dialog</DialogTitle></DialogContent></Dialog>
    </>}
  </FeedbackProvider></MemoryRouter>;
}

it('returns notification-dismiss focus to the real open mobile navigation and permits continuing by keyboard', async () => {
  const user = userEvent.setup();
  render(view());
  await user.click(screen.getByRole('button', { name: 'Fail action' }));
  await user.click(screen.getByRole('button', { name: 'Open navigation' }));
  const navigation = screen.getByRole('dialog', { name: 'Navigation' });
  await user.click(screen.getByRole('button', { name: 'Dismiss notification: Synthetic action failed' }));
  expect(screen.queryByRole('alert')).toBeNull();
  expect(document.activeElement).toBe(navigation);
  await user.tab();
  expect(navigation.contains(document.activeElement)).toBe(true);
  expect(document.activeElement).not.toBe(navigation);
});

it('restores focus to the top managed dialog instead of mobile navigation or an inert parent dialog', async () => {
  const user = userEvent.setup();
  const { rerender } = render(view());
  await user.click(screen.getByRole('button', { name: 'Fail action' }));
  await user.click(screen.getByRole('button', { name: 'Open navigation' }));
  const navigation = screen.getByRole('dialog', { name: 'Navigation' });
  rerender(view(true));
  const topDialog = screen.getByRole('dialog', { name: 'Top dialog' });
  await waitFor(() => expect(topDialog.contains(document.activeElement)).toBe(true));
  await user.click(screen.getByRole('button', { name: 'Dismiss notification: Synthetic action failed' }));
  expect(screen.queryByRole('alert')).toBeNull();
  expect(document.activeElement).toBe(topDialog);
  expect(navigation.contains(document.activeElement)).toBe(false);
});
