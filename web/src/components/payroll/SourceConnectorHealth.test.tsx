// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { SourceConnectorHealth, SourceConnectorReview } from './SourceConnectorHealth';
import type { ConnectorHealth } from '@/lib/connector-health';
const mocks = vi.hoisted(() => ({ read: vi.fn() }));
vi.mock('@/services/api', () => ({ timeTrackingSourceHealthApi: { read: mocks.read } }));
const delivery = { recorded_count: 3, pending_count: 2, failed_count: 1, last_success_at: '2026-10-06T00:00:00Z', failure_record_updated_at: null, oldest_pending_at: '2026-10-05T00:00:00Z', oldest_pending_age_seconds: 86400, pay_period_ids: [21] };
const health: ConnectorHealth = { source_id: 4, company_id: 7, active: true, as_of: '2026-10-06T01:00:00Z', last_source_activity_at: null, evidence_scope: 'local_records', receipts: { batch: delivery, entry: delivery }, calendar: { supported: false, recorded_period_count: 0, unacknowledged_revision_count: 0, failed_revision_count: 0, last_success_at: null, oldest_pending_at: null, oldest_pending_age_seconds: null, pay_period_ids: [] }, latest_import_mapping_review: { status: 'not_recorded', missing_count: null }, reconciliation: { pending_classification_count: 0, manual_pending_commit_count: 0, manual_sync_failed_count: 0, pay_period_ids: [] }, source_settlement_holds: { status: 'not_fetched', count: null }, source_roster_missing_mappings: { status: 'not_fetched', count: null } };
function view(query = '?return_to=%2Fcompanies%2F7%2Fpay-runs%2F21%2Fwork') {
  return render(<MemoryRouter initialEntries={[`/app/time-account-connection${query}`]}><SourceConnectorHealth sourceId={4} companyId={7} /></MemoryRouter>);
}
afterEach(cleanup);
beforeEach(() => { vi.clearAllMocks(); mocks.read.mockResolvedValue(health); });
describe('Protected source delivery review', () => {
  it('fetches only on expansion and preserves source and return context on exact repair links', async () => {
    view(); expect(mocks.read).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Review connection deliveries' }));
    expect(await screen.findByText('Batch receipts')).toBeTruthy();
    expect(mocks.read).toHaveBeenCalledWith(4, 7, expect.any(AbortSignal));
    expect(screen.getAllByText('2 pending · 1 failed deliveries').length).toBe(2);
    expect(screen.getAllByRole('link', { name: 'Review pay run #21' })[0].getAttribute('href')).toContain('/companies/7/pay-runs/21/work?return_to=');
    expect(screen.getAllByRole('link', { name: 'Review pay run #21' })[0].getAttribute('href')).toContain('connection_health%3Dopen');
    expect(screen.getAllByRole('link', { name: 'Review pay run #21' })[0].getAttribute('href')).toContain('health_source_id%3D4');
    expect(screen.getByText(/Current source settlement holds/).textContent).toContain('not fetched');
  });
  it('keeps unavailable health separate from an empty successful queue and permits retry', async () => {
    mocks.read.mockRejectedValueOnce(new Error('Connection review unavailable.'));
    view('?connection_health=open');
    expect(await screen.findByRole('alert')).toBeTruthy();
    expect(screen.queryByText('No receipt deliveries recorded.')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Retry connection review' }));
    expect(await screen.findByText('Entry receipts')).toBeTruthy();
  });
  it('refuses evidence returned for a different company or source', async () => {
    mocks.read.mockResolvedValue({ ...health, company_id: 8 });
    view('?connection_health=open');
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('changed'));
    expect(screen.queryByText('Batch receipts')).toBeNull();
  });
  it('discards a late response after source selection changes', async () => {
    let resolve!: (data: ConnectorHealth) => void;
    mocks.read.mockReturnValueOnce(new Promise<ConnectorHealth>(done => { resolve = done; }));
    const first = view('?connection_health=open');
    await waitFor(() => expect(mocks.read).toHaveBeenCalled());
    first.rerender(<MemoryRouter><SourceConnectorHealth sourceId={5} companyId={7} /></MemoryRouter>);
    await waitFor(() => expect(mocks.read).toHaveBeenCalledWith(5, 7, expect.any(AbortSignal)));
    resolve(health);
    await waitFor(() => expect(screen.queryByText('Batch receipts')).toBeNull());
  });
});

describe('Stored connection selection', () => {
  it('reviews a disabled company-owned producer without requiring account linking', async () => {
    mocks.read.mockResolvedValue({ ...health, active: false });
    render(<MemoryRouter initialEntries={['/app/time-account-connection?health_source_id=4&connection_health=open']}><SourceConnectorReview companyId={7} sources={[{ id: 4, company_id: 7, name: 'Generic stored producer', active: false }]} /></MemoryRouter>);
    expect(await screen.findByText('Connection disabled. Retained delivery records remain available.')).toBeTruthy();
    expect(screen.getByRole('option', { name: 'Generic stored producer (disabled)' })).toBeTruthy();
    expect(mocks.read).toHaveBeenCalledWith(4, 7, expect.any(AbortSignal));
    expect(screen.getAllByRole('link', { name: 'Review pay run #21' })[0].getAttribute('href')).toContain('health_source_id%3D4');
  });
  it('refuses a stored source from another company and permits an explicit safe selection', async () => {
    render(<MemoryRouter initialEntries={['/app/time-account-connection?health_source_id=5&connection_health=open']}><SourceConnectorReview companyId={7} sources={[{ id: 4, company_id: 7, name: 'Company source', active: true }, { id: 5, company_id: 8, name: 'Foreign source', active: false }]} /></MemoryRouter>);
    expect(screen.getByRole('alert').textContent).toContain('unavailable for this company');
    expect(mocks.read).not.toHaveBeenCalled();
    expect(screen.queryByRole('option', { name: /Foreign source/ })).toBeNull();
    fireEvent.change(screen.getByLabelText('Stored time tracking connection'), { target: { value: '4' } });
    expect(await screen.findByText('Batch receipts')).toBeTruthy();
  });
});
