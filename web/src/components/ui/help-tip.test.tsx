// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
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
  });

  it('supports tap-style toggling', async () => {
    const user = userEvent.setup();
    render(<HelpTip label="practice payroll">A safe training copy.</HelpTip>);

    const trigger = screen.getByRole('button', { name: 'About practice payroll' });
    await user.click(trigger);
    expect(screen.getByRole('tooltip')).toBeTruthy();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('tooltip')).toBeNull();
  });
});
