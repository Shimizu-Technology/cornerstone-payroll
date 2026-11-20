// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { PdfTextWarning } from './PdfTextWarning';

describe('PdfTextWarning', () => {
  afterEach(cleanup);

  it('names each field and the characters that would print as boxes', () => {
    render(<PdfTextWarning issues={[{ field: 'Customer name', characters: ['東', '京', '😀'] }, { field: 'Line 1 description', characters: ['U+0009'] }]} />);

    expect(screen.getByRole('alert').textContent).toContain("can't be issued");
    expect(screen.getByText('Customer name:').parentElement?.textContent).toContain('東 京 😀');
    expect(screen.getByText('Line 1 description:').parentElement?.textContent).toContain('U+0009');
  });

  it('renders nothing when every character prints', () => {
    const { container } = render(<PdfTextWarning issues={[]} />);
    expect(container.innerHTML).toBe('');
  });
});
