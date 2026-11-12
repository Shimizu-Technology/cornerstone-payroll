// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { RequestFileDialog } from './RequestFileDialog';
import * as services from '@/services/api';
import { adminPayrollSubmissionsApi } from '@/services/payrollSubmissions';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

it('cannot be dismissed while the request is being created, so a resend keeps its retry key', async () => {
  vi.spyOn(adminPayrollSubmissionsApi, 'employees').mockResolvedValue([]);
  vi.spyOn(adminPayrollSubmissionsApi, 'list').mockResolvedValue({ data: [], meta: { derives_from_schedule: false } });
  let fail!: (error: Error) => void;
  const create = vi.spyOn(services.adminPortalFileRequestsApi, 'create')
    .mockImplementationOnce(() => new Promise((_, reject) => { fail = reject; }))
    .mockResolvedValueOnce({ data: {} as services.PortalFileRequest, thread: { id: 4 } as services.ClientPortalThread });
  const onOpenChange = vi.fn();
  render(<RequestFileDialog open onOpenChange={onOpenChange} threadId={4} onCreated={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('File needed'), { target: { value: 'Timesheet' } });
  fireEvent.click(screen.getByRole('button', { name: 'Send request' }));
  await waitFor(() => expect(create).toHaveBeenCalledOnce());
  expect((screen.getByRole('button', { name: 'Cancel' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.keyDown(document.activeElement || document.body, { key: 'Escape' });
  expect(onOpenChange).not.toHaveBeenCalled();
  fail(new Error('Response lost'));
  expect(await screen.findByText(/Response lost/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Send request' }));
  await waitFor(() => expect(create).toHaveBeenCalledTimes(2));
  expect(create.mock.calls[1][0].idempotency_key).toBe(create.mock.calls[0][0].idempotency_key);
});
