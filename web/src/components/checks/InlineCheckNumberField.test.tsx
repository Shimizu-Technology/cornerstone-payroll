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

  it('prioritizes errors and then unsaved state over the generic assignment message', () => {
    const { rerender } = render(<InlineCheckNumberField value="9303" dirty error="Already used" onChange={vi.fn()} ariaLabel="Check number" />);
    expect(screen.getAllByText('Already used')).toHaveLength(2);
    expect(screen.queryByText('Check number assigned.')).toBeNull();

    rerender(<InlineCheckNumberField value="9304" dirty onChange={vi.fn()} ariaLabel="Check number" />);
    expect(screen.getByText('This check number has unsaved changes.')).toBeTruthy();
    expect(screen.queryByText('Check number assigned.')).toBeNull();
  });
});
