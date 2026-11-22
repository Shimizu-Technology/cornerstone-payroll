// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeNotesPanel } from './EmployeeNotesPanel';
import type { EmployeeNote } from '@/services/employee-notes-api';

const notesApiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  create: vi.fn(),
  hide: vi.fn(),
  original: vi.fn(),
}));

vi.mock('@/services/employee-notes-api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/employee-notes-api')>();
  return {
    ...actual,
    employeeNotesApi: {
      list: notesApiMocks.list,
      create: notesApiMocks.create,
      hide: notesApiMocks.hide,
      original: notesApiMocks.original,
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
  body: null,
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

  it('renders notes with author, Guam time, and keeps hidden text unavailable for non-reveal roles', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [visibleNote, hiddenNote] });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} canRevealHidden={false} />);

    expect(await screen.findByText(visibleNote.body!)).toBeTruthy();
    expect(screen.getByText('Roke Staff')).toBeTruthy();
    expect(screen.getByText(/Nov 22, 2026.*ChST/)).toBeTruthy();
    expect(screen.getByText("Don't enter SSNs, bank or card numbers.")).toBeTruthy();

    expect(screen.getByText(/Hidden by Dafne Admin: Wrong employee record/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Show original' })).toBeNull();
  });

  it('fetches and displays the original body on click when canRevealHidden is true', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [hiddenNote] });
    notesApiMocks.original.mockResolvedValue({
      data: { ...hiddenNote, body: 'Entered on the wrong employee profile.' },
    });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} canRevealHidden />);

    const showButton = await screen.findByRole('button', { name: 'Show original' });
    expect(notesApiMocks.original).not.toHaveBeenCalled();

    fireEvent.click(showButton);

    await waitFor(() => {
      expect(notesApiMocks.original).toHaveBeenCalledWith(1, 42, 10);
    });
    expect(await screen.findByText('Entered on the wrong employee profile.')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Collapse' }));
    expect(screen.queryByText('Entered on the wrong employee profile.')).toBeNull();

    // Expanding again reuses the already fetched body without a second request.
    fireEvent.click(screen.getByRole('button', { name: 'Show original' }));
    expect(screen.getByText('Entered on the wrong employee profile.')).toBeTruthy();
    expect(notesApiMocks.original).toHaveBeenCalledTimes(1);
  });

  it('shows an inline error when revealing a hidden note fails', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [hiddenNote] });
    notesApiMocks.original.mockRejectedValue(new Error('Only super admins and organization admins can view hidden staff notes'));

    render(<EmployeeNotesPanel companyId={1} employeeId={42} canRevealHidden />);

    fireEvent.click(await screen.findByRole('button', { name: 'Show original' }));

    expect((await screen.findByRole('alert')).textContent).toContain('Only super admins and organization admins');
  });

  it('renders HTML-like note text safely as plain text without executing or mounting XSS tags', async () => {
    const xssPayload = '<img src=x onerror=alert(1)> <script>window.__xss=1</script>';
    notesApiMocks.list.mockResolvedValue({
      data: [{ ...visibleNote, id: 99, body: xssPayload }],
    });

    const { container } = render(<EmployeeNotesPanel companyId={1} employeeId={42} />);

    expect(await screen.findByText(xssPayload)).toBeTruthy();
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('script')).toBeNull();
  });

  it('adds a new note and prepends it to the list', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [] });
    notesApiMocks.create.mockResolvedValue({ data: visibleNote });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);

    expect(await screen.findByText('No staff notes yet')).toBeTruthy();

    const textarea = screen.getByLabelText('Add a staff note');
    fireEvent.change(textarea, { target: { value: visibleNote.body! } });
    expect(screen.getByText(`${visibleNote.body!.length} / 2,000`)).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    await waitFor(() => {
      expect(notesApiMocks.create).toHaveBeenCalledWith(1, 42, visibleNote.body);
    });
    expect(await screen.findByText(visibleNote.body!)).toBeTruthy();
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

  it('shows an early client-side sensitive-data warning and still surfaces the authoritative server validation error', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [] });
    notesApiMocks.create.mockRejectedValue(
      new Error('Validation failed; body: appears to contain an SSN or 9-digit tax ID.'),
    );

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText('No staff notes yet');

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: 'SSN 123-45-6789' } });
    expect(screen.getByRole('status').textContent).toMatch(/looks like it contains an SSN/i);

    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toMatch(/appears to contain an SSN/i);
  });

  it('requires a reason to hide a note and collapses it once hidden', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [visibleNote] });
    notesApiMocks.hide.mockResolvedValue({
      data: {
        ...visibleNote,
        body: null,
        hidden: true,
        hidden_at: '2026-11-22T03:00:00Z',
        hidden_by_id: 6,
        hidden_by_name: 'Dafne Admin',
        hidden_reason: 'Resolved after verifying signed W-4',
      },
    });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText(visibleNote.body!);

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

  it('shows an early client-side sensitive-data warning on the hide form and surfaces server validation errors', async () => {
    notesApiMocks.list.mockResolvedValue({ data: [visibleNote] });
    notesApiMocks.hide.mockRejectedValue(
      new Error('Validation failed; hidden_reason: appears to contain an SSN or 9-digit tax ID.'),
    );

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText(visibleNote.body!);

    fireEvent.click(screen.getByRole('button', { name: 'Hide' }));
    fireEvent.change(screen.getByLabelText('Reason for hiding'), {
      target: { value: 'Contained SSN 987-65-4321, acct 1234567890' },
    });

    expect(screen.getByRole('status').textContent).toMatch(/This hide reason looks like it contains an SSN/i);

    fireEvent.click(screen.getByRole('button', { name: 'Hide note' }));
    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toMatch(/appears to contain an SSN/i);
  });

  it('shows a retryable inline error state when loading notes fails and shows truncation notice when meta is truncated', async () => {
    notesApiMocks.list
      .mockRejectedValueOnce(new Error('Could not reach notes service.'))
      .mockResolvedValueOnce({
        data: [visibleNote],
        meta: { limit: 200, returned_count: 200, total_count: 245, truncated: true },
      });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);

    expect((await screen.findByRole('alert')).textContent).toContain('Could not reach notes service.');
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    expect(await screen.findByText(visibleNote.body!)).toBeTruthy();
    expect(screen.getByText('Showing the newest 200 of 245 notes.')).toBeTruthy();
  });

  it('does not let a stale initial list response overwrite a note created while loading', async () => {
    let resolveInitialList!: (value: { data: EmployeeNote[] }) => void;
    const initialListPromise = new Promise<{ data: EmployeeNote[] }>((resolve) => {
      resolveInitialList = resolve;
    });
    notesApiMocks.list
      .mockReturnValueOnce(initialListPromise)
      .mockResolvedValueOnce({ data: [visibleNote] });
    notesApiMocks.create.mockResolvedValueOnce({ data: visibleNote });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    expect(screen.getByText('Loading notes…')).toBeTruthy();

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: visibleNote.body! } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    expect(await screen.findByText(visibleNote.body!)).toBeTruthy();

    resolveInitialList({ data: [] });
    await Promise.resolve();

    await waitFor(() => {
      expect(screen.getByText(visibleNote.body!)).toBeTruthy();
      expect(screen.queryByText('No staff notes yet')).toBeNull();
    });
  });

  it('reloads the list after creating a note while the initial list is loading, keeping existing notes', async () => {
    const existingNote: EmployeeNote = { ...visibleNote, id: 9, body: 'Asked AIRE for her I-9 documents.' };
    let resolveInitialList!: (value: { data: EmployeeNote[] }) => void;
    notesApiMocks.list
      .mockReturnValueOnce(new Promise<{ data: EmployeeNote[] }>((resolve) => { resolveInitialList = resolve; }))
      .mockResolvedValueOnce({ data: [visibleNote, existingNote] });
    notesApiMocks.create.mockResolvedValueOnce({ data: visibleNote });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: visibleNote.body! } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    expect(await screen.findByText(visibleNote.body!)).toBeTruthy();
    resolveInitialList({ data: [existingNote] });

    expect(await screen.findByText(existingNote.body!)).toBeTruthy();
    expect(screen.getByText(visibleNote.body!)).toBeTruthy();
    expect(notesApiMocks.list).toHaveBeenCalledTimes(2);
  });

  it('reloads the list after creating a note when the initial list failed', async () => {
    const existingNote: EmployeeNote = { ...visibleNote, id: 9, body: 'Asked AIRE for her I-9 documents.' };
    notesApiMocks.list
      .mockRejectedValueOnce(new Error('Could not reach notes service.'))
      .mockResolvedValueOnce({ data: [visibleNote, existingNote] });
    notesApiMocks.create.mockResolvedValueOnce({ data: visibleNote });

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    expect((await screen.findByRole('alert')).textContent).toContain('Could not reach notes service.');

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: visibleNote.body! } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    expect(await screen.findByText(existingNote.body!)).toBeTruthy();
    expect(screen.getByText(visibleNote.body!)).toBeTruthy();
    expect(notesApiMocks.list).toHaveBeenCalledTimes(2);
  });

  it('does not duplicate a created note that the list already returned', async () => {
    let resolveCreate!: (value: { data: EmployeeNote }) => void;
    notesApiMocks.list.mockResolvedValueOnce({
      data: [visibleNote],
      meta: { returned_count: 1, total_count: 1, limit: 200, truncated: false },
    });
    notesApiMocks.create.mockReturnValueOnce(new Promise<{ data: EmployeeNote }>((resolve) => { resolveCreate = resolve; }));

    render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    expect(await screen.findByText(visibleNote.body!)).toBeTruthy();

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: visibleNote.body! } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));
    resolveCreate({ data: visibleNote });

    await waitFor(() => expect((screen.getByLabelText('Add a staff note') as HTMLTextAreaElement).value).toBe(''));
    expect(screen.getAllByText(visibleNote.body!)).toHaveLength(1);
    expect(notesApiMocks.list).toHaveBeenCalledTimes(1);
  });

  it('resets submitting and hideSubmitting when employeeId changes during pending mutations', async () => {
    let resolveFirstCreate!: (value: { data: EmployeeNote }) => void;
    const firstCreatePromise = new Promise<{ data: EmployeeNote }>((resolve) => {
      resolveFirstCreate = resolve;
    });
    const secondEmployeeNote: EmployeeNote = {
      ...visibleNote,
      id: 22,
      employee_id: 99,
      body: 'Note for employee 99',
    };

    notesApiMocks.list
      .mockResolvedValueOnce({ data: [] })
      .mockResolvedValueOnce({ data: [] });
    notesApiMocks.create
      .mockReturnValueOnce(firstCreatePromise)
      .mockResolvedValueOnce({ data: secondEmployeeNote });

    const { rerender } = render(<EmployeeNotesPanel companyId={1} employeeId={42} />);
    await screen.findByText('No staff notes yet');

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: 'Pending note for 42' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));
    expect(screen.getByRole('button', { name: 'Saving note…' }).hasAttribute('disabled')).toBe(true);

    rerender(<EmployeeNotesPanel companyId={1} employeeId={99} />);
    await screen.findByText('No staff notes yet');
    expect(screen.getByRole('button', { name: 'Add note' }).hasAttribute('disabled')).toBe(false);

    resolveFirstCreate({ data: visibleNote });
    await Promise.resolve();

    fireEvent.change(screen.getByLabelText('Add a staff note'), { target: { value: secondEmployeeNote.body! } });
    fireEvent.click(screen.getByRole('button', { name: 'Add note' }));

    await waitFor(() => {
      expect(notesApiMocks.create).toHaveBeenLastCalledWith(1, 99, secondEmployeeNote.body);
    });
    expect(await screen.findByText(secondEmployeeNote.body!)).toBeTruthy();

    // Now test pending hide across a scope change.
    let resolveFirstHide!: (value: { data: EmployeeNote }) => void;
    const firstHidePromise = new Promise<{ data: EmployeeNote }>((resolve) => {
      resolveFirstHide = resolve;
    });
    const thirdEmployeeNote: EmployeeNote = {
      ...visibleNote,
      id: 33,
      employee_id: 100,
      body: 'Note for employee 100',
    };
    notesApiMocks.list.mockResolvedValueOnce({ data: [thirdEmployeeNote] });
    notesApiMocks.hide
      .mockReturnValueOnce(firstHidePromise)
      .mockResolvedValueOnce({
        data: {
          ...thirdEmployeeNote,
          body: null,
          hidden: true,
          hidden_at: '2026-11-22T04:00:00Z',
          hidden_by_id: 6,
          hidden_by_name: 'Dafne Admin',
          hidden_reason: 'Superseded for employee 100',
        },
      });

    fireEvent.click(screen.getByRole('button', { name: 'Hide' }));
    fireEvent.change(screen.getByLabelText('Reason for hiding'), { target: { value: 'Pending hide for 99' } });
    fireEvent.click(screen.getByRole('button', { name: 'Hide note' }));
    expect(screen.getByRole('button', { name: 'Hiding…' }).hasAttribute('disabled')).toBe(true);

    rerender(<EmployeeNotesPanel companyId={1} employeeId={100} />);
    expect(await screen.findByText(thirdEmployeeNote.body!)).toBeTruthy();

    resolveFirstHide({ data: { ...secondEmployeeNote, body: null, hidden: true, hidden_reason: 'Pending hide for 99' } });
    await Promise.resolve();

    fireEvent.click(screen.getByRole('button', { name: 'Hide' }));
    fireEvent.change(screen.getByLabelText('Reason for hiding'), { target: { value: 'Superseded for employee 100' } });
    const hideButton = screen.getByRole('button', { name: 'Hide note' });
    expect(hideButton.hasAttribute('disabled')).toBe(false);
    fireEvent.click(hideButton);

    await waitFor(() => {
      expect(notesApiMocks.hide).toHaveBeenLastCalledWith(1, 100, 33, 'Superseded for employee 100');
    });
    expect(await screen.findByText(/Hidden by Dafne Admin: Superseded for employee 100/)).toBeTruthy();
  });
});
