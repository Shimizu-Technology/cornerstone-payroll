// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';

import { HelpTip } from './help-tip';

afterEach(() => cleanup());

describe('HelpTip', () => {
  it('reveals supplemental guidance by focus and closes with Escape', async () => {
    const user = userEvent.setup();
    render(<HelpTip label="locked baseline">Earlier payrolls are view-only.</HelpTip>);

    const trigger = screen.getByRole('button', { name: 'About locked baseline' });
    expect(screen.queryByRole('tooltip')).toBeNull();

    await user.tab();
    expect(document.activeElement).toBe(trigger);
    expect(screen.getByRole('tooltip').textContent).toContain('view-only');

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('tooltip')).toBeNull();
    expect(document.activeElement).toBe(trigger);
  });

  it('supports tap-style toggling', async () => {
    const user = userEvent.setup();
    render(<HelpTip label="practice payroll">A safe training copy.</HelpTip>);

    const trigger = screen.getByRole('button', { name: 'About practice payroll' });
    await user.click(trigger);
    expect(screen.getByRole('tooltip')).toBeTruthy();

    await user.click(trigger);
    expect(screen.queryByRole('tooltip')).toBeNull();
  });

  it('closes a pinned tooltip on an outside pointer press', async () => {
    const user = userEvent.setup();
    render(<HelpTip label="practice payroll">A safe training copy.</HelpTip>);

    await user.click(screen.getByRole('button', { name: 'About practice payroll' }));
    expect(screen.getByRole('tooltip')).toBeTruthy();

    fireEvent.pointerDown(document.body);
    expect(screen.queryByRole('tooltip')).toBeNull();
  });

  it('closes a hover-opened tooltip with Escape', async () => {
    const user = userEvent.setup();
    render(<HelpTip label="parallel payroll">A comparison-only payroll.</HelpTip>);

    const trigger = screen.getByRole('button', { name: 'About parallel payroll' });
    await user.hover(trigger);
    expect(screen.getByRole('tooltip')).toBeTruthy();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('tooltip')).toBeNull();
  });
});
