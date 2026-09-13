// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { InlineCheckNumberField } from './InlineCheckNumberField';

describe('InlineCheckNumberField', () => {
  afterEach(cleanup);

  it('does not announce a required-value warning after a number is assigned', () => {
    render(<InlineCheckNumberField value="9303" onChange={vi.fn()} ariaLabel="Check number" />);

    expect(screen.getByText('Check number assigned.')).toBeTruthy();
    expect(screen.queryByText('A check number is required.')).toBeNull();
  });

  it('announces when a required number is still missing', () => {
    render(<InlineCheckNumberField value="" onChange={vi.fn()} ariaLabel="Check number" />);

    expect(screen.getByText('A check number is required.')).toBeTruthy();
  });
});
