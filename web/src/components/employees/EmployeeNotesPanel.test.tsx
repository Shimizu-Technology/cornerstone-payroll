// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeNotesPanel } from './EmployeeNotesPanel';
import type { EmployeeNote } from '@/services/employee-notes-api';

const notesApiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  create: vi.fn(),
  hide: vi.fn(),
}));

vi.mock('@/services/employee-notes-api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/employee-notes-api')>();
  return {
    ...actual,
    employeeNotesApi: {
      list: notesApiMocks.list,
      create: notesApiMocks.create,
      hide: notesApiMocks.hide,
    },
  };
});

const visibleNote: EmployeeNote = {
  id: 11,
  company_id: 1,
  employee_id: 42,
  body: 'Roke said her start date was Nov 15; the W-4 says Nov 16.',
  created_by_id: 5,
  created_by_name: 'Roke Staff',
  created_at: '2026-11-22T02:15:00Z',
  hidden: false,
  hidden_at: null,
  hidden_by_id: null,
  hidden_by_name: null,
  hidden_reason: null,
};

const hiddenNote: EmployeeNote = {
  id: 10,
  company_id: 1,
  employee_id: 42,
  body: 'Entered on the wrong employee profile.',
  created_by_id: 5,
  created_by_name: 'Roke Staff',
  created_at: '2026-11-21T01:00:00Z',
  hidden: true,
  hidden_at: '2026-11-21T01:30:00Z',
  hidden_by_id: 6,
  hidden_by_name: 'Dafne Admin',
  hidden_reason: 'Wrong employee record',
};

describe('EmployeeNotesPanel', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders notes with author, Guam time, and collapsed hidden state', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [visibleNote, hiddenNote] });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);

    expect(await screen.findByText(visibleNote.body)).toBeTruthy();
    expect(screen.getByText('Roke Staff')).toBeTruthy();
    expect(screen.getByText(/Nov 22, 2026.*ChST/)).toBeTruthy();
    expect(screen.getByText("Don't enter SSNs, bank or card numbers.")).toBeTruthy();

    expect(screen.getByText(/Hidden by Dafne Admin: Wrong employee record/)).toBeTruthy();
    expect(screen.queryByText(hiddenNote.body)).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Show original' }));
    expect(screen.getByText(hiddenNote.body)).toBeTruthy();
  });

  it('adds a new note and prepends it to the list', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [] });
    notesApiMocks.create.mockResolvedValue({ data: visibleNote });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);

    expect(await screen.findByText('No staff notes yet')).toBeTruthy();

    const textarea = screen.getByLabelText('Add a staff note');
    fireEvent.change(textarea, { target: { value: visibleNote.body } });
    expect(screen.getByText(`${visibleNote.body.length} / 2,000`)).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    await waitFor(() => {
      expect(notesApiMocks.create).toHaveBeenCalledWith(1, 42, visibleNote.body);
    });
    expect(await screen.findByText(visibleNote.body)).toBeTruthy();
    expect((textarea as HTMLTextAreaElement).value).toBe('');
  });

  it('blocks submitting an empty or whitespace-only note without calling the API', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [] });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText('No staff notes yet');

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: '   ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Enter a note before saving.');
    expect(notesApiMocks.create).not.toHaveBeenCalled();
  });

  it('shows the server validation error when creating a note fails', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [] });
    notesApiMocks.create.mockRejectedValue(
      new Error('Validation failed; body: appears to contain an SSN or 9-digit tax ID.'),
    );

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText('No staff notes yet');

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: 'SSN 123-45-6789' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toMatch(/appears to contain an SSN/i);
  });

  it('requires a reason to hide a note and collapses it once hidden', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [visibleNote] });
    notesApiMocks.hide.mockResolvedValue({
      data: {
        ...visibleNote,
        hidden: true,
        hidden_at: '2026-11-22T03:00:00Z',
        hidden_by_id: 6,
        hidden_by_name: 'Dafne Admin',
        hidden_reason: 'Resolved after verifying signed W-4',
      },
    });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText(visibleNote.body);

    fireEvent.click(screen.getByRole('button', { name: 'Hide' }));
    fireEvent.click(screen.getByRole('button', { name: 'Hide note' }));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Enter a reason before hiding this note.');
    expect(notesApiMocks.hide).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText('Reason for hiding'), {
      target: { value: 'Resolved after verifying signed W-4' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Hide note' }));

    await waitFor(() => {
      expect(notesApiMocks.hide).toHaveBeenCalledWith(1, 42, 11, 'Resolved after verifying signed W-4');
    });
    expect(await screen.findByText(/Hidden by Dafne Admin: Resolved after verifying signed W-4/)).toBeTruthy();
  });

  it('shows a retryable error state when loading notes fails', async () => {
    notesApiMocks.list
      .mockRejectedValueOnce(new Error('Could not reach notes service.'))
      .mockResolvedValueOnce({ data: [visibleNote] });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);

    expect((await screen.findByRole('alert')).textContent).toContain('Could not reach notes service.');
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    expect(await screen.findByText(visibleNote.body)).toBeTruthy();
  });
});
