// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { GeneralTransmittal } from '@/services/api';
import { GeneralTransmittals } from './GeneralTransmittals';

const api = vi.hoisted(() => ({
  list: vi.fn(), get: vi.fn(), fromPayPeriod: vi.fn(), update: vi.fn(), create: vi.fn(),
  previewPdf: vi.fn(), generatePdf: vi.fn(), refreshFromPayPeriod: vi.fn(),
  artifactPdf: vi.fn(), delete: vi.fn(), checks: vi.fn(), periods: vi.fn(),
  createUrl: vi.fn(), revokeUrl: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  generalTransmittalsApi: api,
  nonEmployeeChecksApi: { list: api.checks },
  payPeriodsApi: { list: api.periods },
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1, name: 'Synthetic client' } }),
}));

const packet: GeneralTransmittal = {
  id: 17, company_id: 1, source_kind: 'standalone', title: 'Synthetic delivery packet',
  transmittal_date: '2026-10-16', preparer_name: 'QA preparer', recipient_name: 'QA recipient',
  notes: ['Retained packet note'], status: 'generated', item_count: 1, total_amount: 150,
  artifact_count: 1, generated_at: '2026-10-16T00:00:00Z',
  created_at: '2026-10-16T00:00:00Z', updated_at: '2026-10-16T00:00:00Z',
  items: [{ id: 71, item_type: 'manual', title: 'Retained delivery row', payable_to: 'QA recipient',
    amount: 150, details: ['Synthetic source detail'], position: 0, included: true }],
  artifacts: [{ id: 31, version_number: 1, filename: 'synthetic-transmittal-v1.pdf',
    content_type: 'application/pdf', byte_size: 120, sha256: 'a'.repeat(64),
    template_version: '1', created_at: '2026-10-16T00:00:00Z' }],
};

// API transport is mocked; these bytes only exercise Blob URL ownership. Tests
// neither render a PDF viewer nor certify the saved artifact's PDF contents.
let pdf: Blob;

async function openSavedPacket(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole('button', { name: /Synthetic delivery packet/ }));
  return screen.findByRole('button', { name: 'View' });
}

function expectNoArtifactMutation() {
  for (const method of [api.create, api.update, api.generatePdf, api.refreshFromPayPeriod, api.delete]) {
    expect(method).not.toHaveBeenCalled();
  }
}

beforeEach(() => {
  vi.resetAllMocks();
  pdf = new Blob(['Synthetic artifact transport bytes'], { type: 'application/pdf' });
  api.list.mockResolvedValue({ general_transmittals: [packet] });
  api.get.mockResolvedValue({ general_transmittal: packet });
  api.checks.mockResolvedValue({ non_employee_checks: [] });
  api.periods.mockResolvedValue({ pay_periods: [] });
  api.artifactPdf.mockResolvedValue({ blob: pdf, filename: 'synthetic-transmittal-v1.pdf' });
  api.previewPdf.mockResolvedValue({ blob: pdf, filename: 'synthetic-preview.pdf' });
  api.createUrl.mockReturnValueOnce('blob:synthetic-preview-1').mockReturnValueOnce('blob:synthetic-preview-2');
  class PreviewURL extends URL {
    static createObjectURL = api.createUrl;
    static revokeObjectURL = api.revokeUrl;
  }
  vi.stubGlobal('URL', PreviewURL);
  // JSDOM does not compute layout. Let the real shared Dialog discover its
  // focusable controls without claiming viewport geometry or iframe internals.
  vi.spyOn(HTMLElement.prototype, 'offsetParent', 'get').mockImplementation(function (this: HTMLElement) {
    return this.parentElement;
  });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('GeneralTransmittals PDF preview dialog', () => {
  it('opens a saved artifact in a named modal, contains backward Tab and restores View after closing', async () => {
    const user = userEvent.setup();
    const view = render(<GeneralTransmittals />);
    const opener = await openSavedPacket(user);
    await user.click(opener);

    const dialog = await screen.findByRole('dialog', { name: 'Transmittal preview' });
    const close = within(dialog).getByRole('button', { name: 'Close' });
    const frame = within(dialog).getByTitle('Transmittal PDF preview');
    await waitFor(() => expect(document.activeElement).toBe(close));
    expect(dialog.getAttribute('aria-modal')).toBe('true');
    expect(view.container.hasAttribute('inert')).toBe(true);
    expect(frame.getAttribute('src')).toBe('blob:synthetic-preview-1');
    expect(api.artifactPdf).toHaveBeenCalledExactlyOnceWith(17, 31);
    // Compare the exact Blob by identity without traversing JSDOM internals.
    expect(api.createUrl).toHaveBeenCalledTimes(1);
    expect(api.createUrl.mock.calls[0]?.length).toBe(1);
    expect(api.createUrl.mock.calls[0]?.[0] === pdf).toBe(true);
    expect(api.revokeUrl).not.toHaveBeenCalled();

    // Exercise the parent document's real dialog handler; embedded PDF viewer
    // keyboard behavior remains outside this component test's environment.
    const backwardTab = new KeyboardEvent('keydown', { key: 'Tab', code: 'Tab', shiftKey: true, bubbles: true, cancelable: true });
    fireEvent(close, backwardTab);
    expect(backwardTab.defaultPrevented).toBe(true);
    expect(document.activeElement === frame).toBe(true);
    fireEvent.click(close);
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(document.activeElement).toBe(opener);
    expect(view.container.hasAttribute('inert')).toBe(false);
    expect(api.revokeUrl).toHaveBeenCalledExactlyOnceWith('blob:synthetic-preview-1');
    expectNoArtifactMutation();
  });

  it('dismisses with Escape or keyboard Close, keeps the packet, and releases each preview only once', async () => {
    const user = userEvent.setup();
    const view = render(<GeneralTransmittals />);
    const opener = await openSavedPacket(user);
    await user.click(opener);
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' })));
    await user.keyboard('{Escape}');
    await waitFor(() => expect(document.activeElement).toBe(opener));
    await waitFor(() => expect(screen.queryByTitle('Transmittal PDF preview')).toBeNull());
    expect((screen.getByRole('textbox', { name: 'Title' }) as HTMLInputElement).value).toBe(packet.title);

    await user.keyboard('{Enter}');
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' })));
    expect(screen.getByTitle('Transmittal PDF preview').getAttribute('src')).toBe('blob:synthetic-preview-2');
    await user.keyboard('{Enter}');
    await waitFor(() => expect(document.activeElement).toBe(opener));
    view.unmount();
    expect(api.revokeUrl.mock.calls).toEqual([['blob:synthetic-preview-1'], ['blob:synthetic-preview-2']]);
    expect(api.artifactPdf.mock.calls).toEqual([[17, 31], [17, 31]]);
    expectNoArtifactMutation();
  });

  it('returns to the current-preview opener after its asynchronous save temporarily disables and blurs it', async () => {
    const user = userEvent.setup();
    let finishSave!: (value: { general_transmittal: GeneralTransmittal }) => void;
    api.update.mockReturnValue(new Promise<{ general_transmittal: GeneralTransmittal }>((resolve) => { finishSave = resolve; }));
    render(<GeneralTransmittals />);
    await openSavedPacket(user);
    const opener = screen.getByRole('button', { name: 'Preview' }) as HTMLButtonElement;
    await user.click(opener);
    expect(opener.disabled).toBe(true);
    // Browsers may blur a disabled button while the existing save is pending.
    opener.blur();
    await act(async () => { finishSave({ general_transmittal: packet }); });
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' })));
    expect(api.previewPdf).toHaveBeenCalledExactlyOnceWith(17);
    expect(api.artifactPdf).not.toHaveBeenCalled();

    await user.keyboard('{Escape}');
    await waitFor(() => expect(document.activeElement).toBe(opener));
    expect(opener.disabled).toBe(false);
    expect(api.update).toHaveBeenCalledTimes(1);
    expect(api.generatePdf).not.toHaveBeenCalled();
    expect(api.revokeUrl).toHaveBeenCalledExactlyOnceWith('blob:synthetic-preview-1');
  });
});
