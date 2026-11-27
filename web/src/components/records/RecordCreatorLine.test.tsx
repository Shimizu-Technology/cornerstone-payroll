// @vitest-environment jsdom
import { render, screen, cleanup } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { RecordCreatorLine } from './RecordCreatorLine';
afterEach(cleanup);
it('shows known creator, role and creation date', () => {
  render(<RecordCreatorLine creator={{ name: 'Morgan', role: 'manager', created_at: '2026-11-15T00:00:00Z' }} />);
  expect(screen.getByText(/Created by Morgan \(manager\)/).textContent).toContain('2026');
});
it('explains missing historical attribution', () => {
  render(<RecordCreatorLine creator={null} />);
  expect(screen.getByText('Creator not recorded')).toBeTruthy();
});
