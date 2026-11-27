// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { EmployeeTippedOccupations } from './EmployeeTippedOccupations';

const { company, history, end } = vi.hoisted(() => ({
  company: { workspace_can_write: true, workspace_write_permissions: { manage_client_configuration: true } },
  history: {
    data: [{ id: 4, occupation_code: '101', effective_from: '2026-01-01', effective_to: null }],
    codes: { '101': 'Bartenders' },
  },
  end: vi.fn(),
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: company }) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useOptionalSelectedCompanyCapability: () => true }));
vi.mock('@/services/api', () => ({ tippedOccupationsApi: { history: async () => history, end } }));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  company.workspace_write_permissions.manage_client_configuration = true;
});

it('ends the selected code while keeping it visible in the history', async () => {
  end.mockResolvedValue({ ...history, data: [{ ...history.data[0], effective_to: '2026-08-31' }] });
  render(<EmployeeTippedOccupations employeeId={3} companyId={7} readOnly={false} />);
  fireEvent.click(await screen.findByRole('button', { name: 'End' }));
  fireEvent.change(screen.getByLabelText('Effective end date'), { target: { value: '2026-08-31' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save end date' }));

  await waitFor(() => expect(end).toHaveBeenCalledWith(3, 4, 7, '2026-08-31'));
  expect(await screen.findByText('2026-01-01 to 2026-08-31')).toBeTruthy();
});

it('keeps history visible while hiding writes when the company disallows configuration changes', async () => {
  company.workspace_write_permissions.manage_client_configuration = false;
  render(<EmployeeTippedOccupations employeeId={3} companyId={7} readOnly={false} />);
  expect(await screen.findByText('101 · Bartenders')).toBeTruthy();
  expect(screen.queryByRole('button')).toBeNull();
});
