// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { QuickbooksStubUpload } from './QuickbooksStubUpload';

const requests = vi.hoisted(() => ({ preview: vi.fn(), viewPage: vi.fn(), confirm: vi.fn() }));
vi.mock('@/services/api', () => ({ quickbooksStubUploadsApi: requests, ApiError: Error }));
vi.mock('@/components/documents/PdfPreview', () => ({
  PdfDocumentView: ({ onPageRendered }: { onPageRendered: () => void }) => (
    <button onClick={onPageRendered}>Finish rendering the page</button>
  ),
}));

const details = { employee_name: 'Jesse Example', pay_date: '2026-01-20', net_pay: '900', check_number: null };

beforeEach(() => {
  vi.clearAllMocks();
  requests.preview.mockResolvedValue({ data: [
    { ...details, page: 1, review_token: 'matched', status: 'matched' },
    { ...details, page: 2, review_token: 'image', status: 'image_review' },
    { ...details, page: 3, review_token: 'number', status: 'possible_ssn' },
  ] });
  requests.viewPage.mockResolvedValue({ blob: new Blob(['pdf'], { type: 'application/pdf' }) });
  requests.confirm.mockResolvedValue({ data: [] });
});
afterEach(cleanup);

function chooseFile() {
  const file = new File(['pdf'], 'source.pdf', { type: 'application/pdf' });
  render(<QuickbooksStubUpload companyId={2} warnings={[]} enabled />);
  fireEvent.change(screen.getByLabelText('QuickBooks stub PDF'), { target: { files: [file] } });
  return file;
}

async function preview() {
  const file = chooseFile();
  fireEvent.click(screen.getByRole('button', { name: 'Preview matches' }));
  await screen.findByRole('checkbox', { name: 'Select page 2' });
  return file;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((onResolve, onReject) => {
    resolve = onResolve;
    reject = onReject;
  });
  return { promise, resolve, reject };
}

function checkbox(name: string) {
  return screen.getByRole<HTMLInputElement>('checkbox', { name });
}

describe('QuickBooks stub upload', () => {
  it('announces each pending operation and clears the message after success or failure', async () => {
    const previewResult = deferred<{ data: object[] }>();
    const pageResult = deferred<{ blob: Blob }>();
    const postResult = deferred<{ data: object[] }>();
    requests.preview.mockReturnValueOnce(previewResult.promise);
    requests.viewPage.mockReturnValueOnce(pageResult.promise);
    requests.confirm.mockReturnValueOnce(postResult.promise);
    chooseFile();

    const status = screen.getByRole('status');
    const previewButton = screen.getByRole<HTMLButtonElement>('button', { name: 'Preview matches' });
    fireEvent.click(previewButton);
    expect(status.textContent).toBe('Checking the file…');
    expect(previewButton.disabled).toBe(true);
    previewResult.resolve({ data: [
      { ...details, page: 1, review_token: 'matched', status: 'matched' },
      { ...details, page: 2, review_token: 'image', status: 'image_review' },
    ] });
    const viewButton = await screen.findByRole('button', { name: 'View page 2' });
    expect(status.textContent).toBe('');

    fireEvent.click(viewButton);
    expect(status.textContent).toBe('Opening page…');
    pageResult.reject(new Error('Page unavailable'));
    await screen.findByText('Page unavailable');
    expect(status.textContent).toBe('');

    fireEvent.click(checkbox('Select page 1'));
    fireEvent.click(screen.getByRole('button', { name: 'Post selected stubs (1)' }));
    expect(status.textContent).toBe('Posting…');
    postResult.resolve({ data: [{}] });
    await screen.findByText('1 original stub posted.');
    expect(status.textContent).toBe('');
  });

  it('selects only ordinary matches in bulk', async () => {
    const file = await preview();
    fireEvent.click(screen.getByRole('button', { name: 'Select all matched' }));
    expect(checkbox('Select page 1').checked).toBe(true);
    for (const page of [2, 3]) {
      const selection = checkbox('Select page ' + page);
      expect(selection.checked).toBe(false);
      expect(selection.disabled).toBe(true);
    }
    fireEvent.click(screen.getByRole('button', { name: 'Post selected stubs (1)' }));
    expect(requests.confirm).toHaveBeenCalledWith(2, file, ['matched'], [], []);
  });

  it('requires a rendered page and a separate attestation, and deselects if that attestation is removed', async () => {
    const file = await preview();
    const image = checkbox('Select page 2');
    const imageAttestation = screen.getAllByRole<HTMLInputElement>('checkbox', { name: 'I checked this page' })[0];
    expect(imageAttestation.disabled).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'View page 2' }));
    await screen.findByRole('dialog');
    expect(requests.viewPage).toHaveBeenCalledWith(2, file, 'image');
    fireEvent.click(screen.getByRole('button', { name: 'Finish rendering the page' }));
    fireEvent.click(screen.getByRole('button', { name: 'Back to matches' }));
    expect(imageAttestation.disabled).toBe(false);
    expect(image.disabled).toBe(true);
    fireEvent.click(imageAttestation);
    expect(image.disabled).toBe(false);
    fireEvent.click(image);
    fireEvent.click(imageAttestation);
    expect(image.checked).toBe(false);
    expect(image.disabled).toBe(true);
    fireEvent.click(imageAttestation);
    fireEvent.click(image);
    fireEvent.click(screen.getByRole('button', { name: 'Post selected stubs (1)' }));
    await waitFor(() => expect(requests.confirm).toHaveBeenCalledWith(2, file, [], ['image'], []));
  });
});
