// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { RecordHistoryPanel } from './RecordHistoryPanel';
vi.mock('./RecordActivityTimeline', () => ({ RecordActivityTimeline: () => <div>Loaded timeline</div> }));
afterEach(cleanup);
it('loads record history only after opening the panel', () => {
  render(<RecordHistoryPanel companyId={1} recordId={2} recordType="companies" />);
  expect(screen.queryByText('Loaded timeline')).toBeNull();
  const details = screen.getByText('History').parentElement as HTMLDetailsElement;
  details.open = true;
  fireEvent(details, new Event('toggle'));
  expect(screen.getByText('Loaded timeline')).toBeTruthy();
});
