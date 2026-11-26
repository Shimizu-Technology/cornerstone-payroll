// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { ChangeComparison } from './ChangeComparison';

afterEach(cleanup);

it('lists an address change in reading order, whatever order the keys arrive in', () => {
  // The database returns short keys first, which put ZIP ahead of the street.
  const after = { zip: '96913', city: 'Tamuning', state: 'GU', address_line1: '12 Finchwater Lane', address_line2: 'Unit 4' };
  const before = { zip: '96910', city: 'Hagatna', state: 'GU', address_line1: '3 Saltreed Road', address_line2: '' };

  render(<ChangeComparison before={before} after={after} requested current />);

  expect(screen.getAllByRole('rowheader').map((cell) => cell.textContent)).toEqual([
    'Street address', 'Apartment or unit', 'City', 'State', 'ZIP code',
  ]);
});

it('keeps fields it has no set place for after the known ones, in their original order', () => {
  render(<ChangeComparison after={{ w4_filing_status: 'single', zip: '96913', phone: '6715550100', notes: 'x' }} />);

  expect(screen.getAllByRole('rowheader').map((cell) => cell.textContent)).toEqual([
    'Phone', 'ZIP code', 'W-4 filing status', 'Notes',
  ]);
});
