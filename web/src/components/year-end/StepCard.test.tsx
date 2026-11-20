// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { StepCard } from './StepCard';
import type { YearEndStep } from '@/lib/year-end';

const printStep = {
  key: 'print_and_file', number: 8, title: 'Print and file', status: 'available', summary: 'Downloads', issues: [],
  data: { final: true, documents: [] },
} as YearEndStep;

function card(defaultOpen: boolean) {
  return <StepCard step={printStep} isNext={false} defaultOpen={defaultOpen} keepMounted><button type="button">Download PDF</button></StepCard>;
}

describe('StepCard', () => {
  afterEach(cleanup);

  it('opens when defaultOpen turns true, and a later collapse survives re-renders', () => {
    const { rerender } = render(card(false));
    expect(screen.queryByRole('button', { name: 'Download PDF' })).toBeNull();

    rerender(card(true));
    expect(screen.getByRole('button', { name: 'Download PDF' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Hide Print and file' }));
    rerender(card(true));
    expect(screen.queryByRole('button', { name: 'Download PDF' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Show Print and file' }).getAttribute('aria-expanded')).toBe('false');
  });

  it('keeps a keepMounted body in the page, hidden, while collapsed', () => {
    render(card(true));
    fireEvent.click(screen.getByRole('button', { name: 'Hide Print and file' }));

    const body = document.getElementById('year-end-step-print_and_file-body');
    expect(body?.hidden).toBe(true);
    expect(body?.textContent).toContain('Download PDF');
  });
});
