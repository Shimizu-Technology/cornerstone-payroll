// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Button } from './button';
import { BusyStatus } from './busy-status';

afterEach(cleanup);

it('keeps both label footprints, exposes only the current label, and blocks repeated clicks while busy', () => {
  const click = vi.fn();
  const view = render(<Button loading={false} loadingLabel="Recalculating…" onClick={click}>Recalculate</Button>);
  const button = screen.getByRole('button', { name: 'Recalculate' });
  expect(button.querySelector('[aria-hidden="true"]')?.textContent).toBe('Recalculating…');
  fireEvent.click(button);
  view.rerender(<Button loading loadingLabel="Recalculating…" onClick={click}>Recalculate</Button>);
  expect(screen.getByRole('button', { name: 'Recalculating…' })).toBe(button);
  expect(button).toHaveProperty('disabled', true);
  expect(button.getAttribute('aria-busy')).toBe('true');
  expect(button.querySelector('svg')?.classList.contains('motion-reduce:animate-none')).toBe(true);
  expect(button.querySelector('[aria-hidden="true"]')?.textContent).toBe('Recalculate');
  fireEvent.click(button);
  expect(click).toHaveBeenCalledOnce();
  view.rerender(<Button loading={false} loadingLabel="Recalculating…" onClick={click}>Recalculate</Button>);
  expect(screen.getByRole('button', { name: 'Recalculate' })).toHaveProperty('disabled', false);
});

it('mounts an empty polite live region before work starts and keeps its sizing copy out of announcements', () => {
  const view = render(<BusyStatus busy={false}>Calculating payroll for 52 employees…</BusyStatus>);
  const status = screen.getByRole('status');
  expect(status.getAttribute('aria-live')).toBe('polite');
  expect(status.getAttribute('aria-atomic')).toBe('true');
  expect(status.firstElementChild?.getAttribute('aria-hidden')).toBe('true');
  expect(status.lastElementChild?.textContent).toBe('');
  view.rerender(<BusyStatus busy>Calculating payroll for 52 employees…</BusyStatus>);
  expect(screen.getByRole('status')).toBe(status);
  expect(status.lastElementChild?.textContent).toBe('Calculating payroll for 52 employees…');
});
