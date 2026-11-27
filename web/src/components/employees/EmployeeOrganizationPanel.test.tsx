// @vitest-environment jsdom

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import { EmployeeOrganizationPanel } from './EmployeeOrganizationPanel';

const { patch, get } = vi.hoisted(() => ({ patch: vi.fn(), get: vi.fn() }));
vi.mock('@/services/api', () => ({ apiClient: { get, patch } }));

it('keeps a bulk selection across pages and applies the chosen role in the client workspace', async () => {
  get.mockResolvedValue({ roles: [{ id: 8, name: 'Server', active: true }], departments: [], codes: {} });
  patch.mockResolvedValue({ count: 2 });
  const onSaved = vi.fn();
  const first = { id: 1, first_name: 'Sample', last_name: 'One' } as Employee;
  const second = { id: 2, first_name: 'Sample', last_name: 'Two' } as Employee;
  const props = { companyId: 7, isClient: true, onSaved };
  const { rerender } = render(<EmployeeOrganizationPanel {...props} employees={[first]} />);

  fireEvent.click(screen.getByRole('button', { name: 'Roles and departments' }));
  fireEvent.click(await screen.findByLabelText('Select this page'));
  rerender(<EmployeeOrganizationPanel {...props} employees={[second]} />);
  fireEvent.click(screen.getByLabelText('Select this page'));
  expect(screen.getByText('1 selected from other pages or filters.')).toBeTruthy();

  fireEvent.change(screen.getByLabelText('Role'), { target: { value: '8' } });
  fireEvent.click(screen.getByRole('button', { name: 'Apply to 2 selected' }));
  await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
  expect(patch).toHaveBeenCalledWith('/client/employee_organization', {
    employee_ids: [1, 2], company_job_role_id: 8,
  }, { companyId: 7 });
});
