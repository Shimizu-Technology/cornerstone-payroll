// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { SupportAccessLogs } from './SupportAccessLogs';

const api = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock('@/services/api', () => ({ default: api }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 3, activeCompany: { id: 3, name: 'Example Bakery' } }) }));
vi.mock('@/components/layout/Header', () => ({
  Header: ({ title, description }: { title: string; description?: ReactNode }) => <header><h1>{title}</h1><p>{description}</p></header>,
}));

afterEach(() => { cleanup(); vi.resetAllMocks(); });

it('explains what the page is for when nobody has opened the portal', async () => {
  api.get.mockResolvedValue({ events: [] });
  render(<SupportAccessLogs />);

  expect(screen.getByText('When Cornerstone opens your portal to help you, each visit is listed here.')).toBeTruthy();
  expect(screen.queryByText('Example Bakery')).toBeNull();
  expect(await screen.findByText("Cornerstone hasn't opened your portal yet.")).toBeTruthy();
  expect(screen.getByText(/appears here with who opened it and when\. These visits are view-only/)).toBeTruthy();
});

it('lists each visit', async () => {
  api.get.mockResolvedValue({ events: [{ id: '1', description: 'Sample Staff viewed as Sample Manager', viewed_at: '2026-11-20T01:00:00Z' }] });
  render(<SupportAccessLogs />);

  expect(await screen.findByText('Sample Staff viewed as Sample Manager')).toBeTruthy();
  expect(screen.queryByText(/hasn't opened your portal/)).toBeNull();
});
