// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PrintAndFileStep } from './PrintAndFileStep';
import { ApiError } from '@/services/api';
import type { ActiveYearEndStep, YearEndChecklist, YearEndDocument } from '@/lib/year-end';

const mocks = vi.hoisted(() => ({ downloadDocument: vi.fn() }));
vi.mock('@/services/api', () => ({
  yearEndApi: { downloadDocument: mocks.downloadDocument },
  ApiError: class ApiError extends Error {
    status: number;
    data: unknown;
    constructor(message: string, status = 500, _details?: unknown, data?: unknown) { super(message); this.status = status; this.data = data; }
  },
}));

const checklist = {
  company: { id: 7, name: 'Tumon Bakery', active: true, test_workspace: false },
  tax_year: 2026, status: 'needs_action', issue_count: 1, next_step: 'mark_ready', files_w2: true, files_1099: false,
  permissions: { can_record_decision: true, can_acknowledge: true, can_mark_ready: true }, steps: [],
} satisfies YearEndChecklist;

function document(key: string, overrides: Partial<YearEndDocument> = {}): YearEndDocument {
  const drt = key === 'w2_drt_copy_1';
  return {
    key,
    title: drt ? 'Copy 1 for Guam DRT' : 'Employee copies (B and C)',
    description: drt ? 'Your record; not mailed when you e-file.' : 'Print and give to each employee by Feb 1, 2027.',
    detail: drt ? '4 employees, two to a page.' : '4 employees, one sheet each, by last name.',
    format: 'pdf', contains_full_ssn: drt, draft: true, available: true, unavailable_reason: null,
    download: { path: drt ? '/admin/reports/w2_gu_copy_1_drt' : '/admin/reports/w2_gu_employee_copies', params: { year: 2026 } },
    ...overrides,
  };
}

function step(final: boolean, documents = [document('w2_employee_copies', { draft: !final }), document('w2_drt_copy_1', { draft: !final })]): ActiveYearEndStep<'print_and_file'> {
  return { key: 'print_and_file', number: 8, title: 'Print and file', status: 'available', summary: '', issues: [], data: { final, documents } };
}

function row(title: string): HTMLElement {
  return screen.getByRole('listitem', { name: title });
}

describe('PrintAndFileStep', () => {
  const createObjectURL = vi.fn(() => 'blob:w2');
  const revokeObjectURL = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    Object.assign(URL, { createObjectURL, revokeObjectURL });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
  });
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('lists each document with its one-line explanation, as drafts before the W-2s are marked ready', () => {
    render(<PrintAndFileStep checklist={checklist} step={step(false)} />);

    const employee = row('Employee copies (B and C)');
    expect(within(employee).getByText('Print and give to each employee by Feb 1, 2027.')).toBeTruthy();
    expect(within(employee).getByText('Draft')).toBeTruthy();
    expect(within(employee).queryByText(/Full SSNs/)).toBeNull();
    expect(within(employee).getByRole('button', { name: 'Download draft' })).toBeTruthy();

    const drt = row('Copy 1 for Guam DRT');
    expect(within(drt).getByText('Your record; not mailed when you e-file.')).toBeTruthy();
    expect(within(drt).getByText(/Full SSNs\. Keep the file and the printout somewhere secure\./)).toBeTruthy();
  });

  it('requires confirmation for each draft filing document and sends its scoped path and mode', async () => {
    const confirmation = "Test file only — do not upload as your filing.";
    const efile = document('w2_efile', { title: 'W-2 e-file (SSA and GuamTax)', format: 'txt', contains_full_ssn: true,
      draft_confirmation: confirmation, download: { path: '/admin/reports/w2_gu_efw2', params: { year: 2026, mode: 'draft' } } });
    const totals = document('w3ss_totals', { title: 'W-3SS totals (for your records)', draft_confirmation: confirmation,
      download: { path: '/admin/reports/w3ss_pdf', params: { year: 2026, mode: 'draft' } } });
    mocks.downloadDocument.mockResolvedValue({ blob: new Blob(['file']), filename: 'draft.txt' });
    render(<PrintAndFileStep checklist={checklist} step={step(false, [document('w2_employee_copies'), document('w2_drt_copy_1'), efile, totals])} />);
    expect(screen.getAllByRole('listitem')).toHaveLength(4);
    const filing = row(efile.title);
    const button = within(filing).getByRole('button', { name: 'Download draft' });
    expect(button.hasAttribute('disabled')).toBe(true);
    fireEvent.click(button);
    expect(mocks.downloadDocument).not.toHaveBeenCalled();
    fireEvent.click(within(filing).getByRole('checkbox'));
    fireEvent.click(button);
    await waitFor(() => expect(mocks.downloadDocument).toHaveBeenCalledWith(efile.download, 7));
    expect(within(row(totals.title)).getByRole('button', { name: 'Download draft' }).hasAttribute('disabled')).toBe(true);
  });

  it('downloads final e-files without a draft confirmation and reports server rejections', async () => {
    const efile = document('w2_efile', { title: 'W-2 e-file (SSA and GuamTax)', format: 'txt', contains_full_ssn: true,
      draft: false, download: { path: '/admin/reports/w2_gu_efw2', params: { year: 2026, mode: 'final' } } });
    mocks.downloadDocument.mockRejectedValueOnce(new Error('Inputs changed; mark ready again'));
    render(<PrintAndFileStep checklist={checklist} step={step(true, [efile])} />);
    expect(screen.queryByRole('checkbox')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Download e-file' }));
    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Inputs changed'));
    expect(mocks.downloadDocument).toHaveBeenCalledWith(efile.download, 7);
  });

  it('explains capability-disabled e-files while allowing records totals', () => {
    const reason = 'Needs client-management access (contains full SSNs).';
    render(<PrintAndFileStep checklist={checklist} step={step(true, [
      document('w2_efile', { title: 'W-2 e-file (SSA and GuamTax)', format: 'txt', draft: false, available: false, unavailable_reason: reason }),
      document('w3ss_totals', { title: 'W-3SS totals (for your records)', draft: false }),
    ])} />);
    expect(screen.getByText(reason)).toBeTruthy();
    expect(within(row('W-2 e-file (SSA and GuamTax)')).getByRole('button').hasAttribute('disabled')).toBe(true);
    expect(within(row('W-3SS totals (for your records)')).getByRole('button').hasAttribute('disabled')).toBe(false);
  });

  it('offers final PDFs once the W-2s are marked ready', () => {
    render(<PrintAndFileStep checklist={checklist} step={step(true)} />);

    expect(screen.queryByText('Draft')).toBeNull();
    expect(screen.getAllByRole('button', { name: 'Download PDF' })).toHaveLength(2);
  });

  it('downloads through the endpoint the checklist names, for this client, showing progress', async () => {
    let finish: (value: { blob: Blob; filename: string }) => void = () => {};
    mocks.downloadDocument.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    render(<PrintAndFileStep checklist={checklist} step={step(true)} />);

    fireEvent.click(within(row('Copy 1 for Guam DRT')).getByRole('button', { name: 'Download PDF' }));

    expect(mocks.downloadDocument).toHaveBeenCalledWith({ path: '/admin/reports/w2_gu_copy_1_drt', params: { year: 2026 } }, 7);
    const button = within(row('Copy 1 for Guam DRT')).getByRole('button', { name: /Preparing PDF/ });
    expect(button.getAttribute('aria-busy')).toBe('true');

    finish({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), filename: 'W-2GU_2026_Tumon_Bakery_Copy1_DRT.pdf' });
    await waitFor(() => expect(createObjectURL).toHaveBeenCalledTimes(1));
    expect(HTMLAnchorElement.prototype.click).toHaveBeenCalledTimes(1);
    // Revoked later, not right after the click, so mobile Safari can read it.
    expect(revokeObjectURL).not.toHaveBeenCalled();
    expect(within(row('Copy 1 for Guam DRT')).getByRole('button', { name: 'Download PDF' }).hasAttribute('disabled')).toBe(false);
  });

  it('shows a clear error and retries', async () => {
    mocks.downloadDocument
      .mockRejectedValueOnce(new Error('Cornerstone does not file 2026 W-2s for this client.'))
      .mockResolvedValueOnce({ blob: new Blob(['%PDF']), filename: 'copies.pdf' });
    render(<PrintAndFileStep checklist={checklist} step={step(false)} />);

    fireEvent.click(within(row('Employee copies (B and C)')).getByRole('button', { name: 'Download draft' }));

    const alert = await within(row('Employee copies (B and C)')).findByRole('alert');
    expect(alert.textContent).toContain('Cornerstone does not file 2026 W-2s for this client.');
    fireEvent.click(within(alert).getByRole('button', { name: 'Try again' }));

    await waitFor(() => expect(createObjectURL).toHaveBeenCalledTimes(1));
    expect(mocks.downloadDocument).toHaveBeenCalledTimes(2);
    expect(within(row('Employee copies (B and C)')).queryByRole('alert')).toBeNull();
  });

  it('asks for a fresh download when the W-2 data changed while the file was made', async () => {
    const changed = "This client's W-2 data changed while the file was being made. Download again.";
    mocks.downloadDocument
      .mockRejectedValueOnce(new ApiError(`${changed} Reload the record and review the latest values before trying again.`, 409, undefined, { error: changed }))
      .mockResolvedValueOnce({ blob: new Blob(['%PDF']), filename: 'copies.pdf' });
    render(<PrintAndFileStep checklist={checklist} step={step(true)} />);

    fireEvent.click(within(row('Copy 1 for Guam DRT')).getByRole('button', { name: 'Download PDF' }));

    const alert = await within(row('Copy 1 for Guam DRT')).findByRole('alert');
    // Only the server's instruction, not the generic reload advice.
    expect(within(alert).getByText(changed).textContent).toBe(changed);
    expect(createObjectURL).not.toHaveBeenCalled();
    fireEvent.click(within(alert).getByRole('button', { name: 'Try again' }));
    await waitFor(() => expect(createObjectURL).toHaveBeenCalledTimes(1));
  });

  it('keeps each line of a list of fields to shorten', async () => {
    const message = "These W-2GU copies can't be made until these are fixed:\n• Maria Cruz: the address is too long to fit Box f — shorten it on the employee's profile.\n• Jose Aguon: the last name is too long to fit Box e — shorten it on the employee's profile.";
    mocks.downloadDocument.mockRejectedValueOnce(new Error(message));
    render(<PrintAndFileStep checklist={checklist} step={step(false)} />);

    fireEvent.click(within(row('Employee copies (B and C)')).getByRole('button', { name: 'Download draft' }));

    const text = within(await within(row('Employee copies (B and C)')).findByRole('alert')).getByText(/Maria Cruz/);
    expect(text.textContent).toBe(message);
    expect(text.className).toContain('whitespace-pre-line');
  });

  it('withholds Copy 1 in a practice copy, saying why, while employee copies stay available as drafts', () => {
    const practice = { ...checklist, company: { ...checklist.company, test_workspace: true } };
    const reason = 'Not available in a practice copy — it contains full SSNs.';
    render(<PrintAndFileStep checklist={practice} step={step(false, [
      document('w2_employee_copies'),
      document('w2_drt_copy_1', { available: false, unavailable_reason: reason }),
    ])} />);

    const drt = row('Copy 1 for Guam DRT');
    expect(within(drt).getByText(reason)).toBeTruthy();
    expect(within(drt).getByRole('button', { name: 'Download draft' }).hasAttribute('disabled')).toBe(true);
    expect(within(row('Employee copies (B and C)')).getByRole('button', { name: 'Download draft' }).hasAttribute('disabled')).toBe(false);
  });

  it('explains a document that cannot be downloaded yet', () => {
    const reason = 'No employees have 2026 W-2 wages.';
    render(<PrintAndFileStep checklist={checklist} step={step(false, [document('w2_employee_copies', { available: false, unavailable_reason: reason })])} />);

    expect(screen.getByText(reason)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Download draft' }).hasAttribute('disabled')).toBe(true);
    expect(screen.queryByText('Draft')).toBeNull();
  });
});
