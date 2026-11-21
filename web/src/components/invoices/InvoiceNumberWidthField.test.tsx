// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { afterEach, describe, expect, it } from 'vitest';
import { InvoiceNumberWidthField } from './InvoiceNumberWidthField';

function Harness({ initial }: { initial: string }) {
  const [value, setValue] = useState(initial);
  return <InvoiceNumberWidthField value={value} nextNumber={7055} onChange={setValue} />;
}

describe('InvoiceNumberWidthField', () => {
  afterEach(cleanup);

  it('shows the next number for a valid width and an inline error for an invalid one', async () => {
    render(<Harness initial="5" />);
    expect(screen.getByText('Next invoice: 07055')).toBeTruthy();

    const input = screen.getByLabelText('Digits in invoice number');
    await userEvent.clear(input);
    await userEvent.type(input, '13');
    expect(screen.getByRole('alert').textContent).toMatch(/whole number from 1 to 12/);
    expect(input.getAttribute('aria-invalid')).toBe('true');
    expect(screen.queryByText(/Next invoice:/)).toBeNull();

    await userEvent.clear(input);
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.getByText('Next invoice: 7055')).toBeTruthy();
  });
});
