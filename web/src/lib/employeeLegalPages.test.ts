/** @vitest-environment jsdom */
import { afterEach, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import terms from '../../deploy/employee/legal/employee-terms-2026-12-01-draft.html?raw';
import privacy from '../../deploy/employee/legal/employee-privacy-2026-12-01-draft.html?raw';

const stylesheet = readFileSync('deploy/employee/legal/employee-legal.css', 'utf8');

afterEach(() => {
  document.body.removeAttribute('data-status');
  document.body.replaceChildren();
});

it.each([
  ['terms', 'Employee App Terms of Use', terms],
  ['privacy', 'Employee Privacy Notice', privacy],
])('shows the versioned %s page and displays the notice only for draft status', (_slug, title, html) => {
  const page = new DOMParser().parseFromString(html, 'text/html');
  document.body.setAttribute('data-status', page.body.getAttribute('data-status') ?? '');
  document.body.innerHTML = page.body.innerHTML;
  const style = document.createElement('style');
  style.textContent = stylesheet;
  document.body.append(style);

  expect(document.querySelector('main h1')?.textContent).toBe(title);
  expect(document.querySelector('.version')?.textContent).toContain('Version 2026-12-01-draft');
  expect(document.querySelector('time')?.dateTime).toBe('2026-12-01');
  for (const link of document.querySelectorAll('header a, footer a')) {
    expect(getComputedStyle(link).minHeight).toBe('44px');
  }
  const notice = document.querySelector('.draft-notice')!;
  expect(notice.textContent).toBe('Draft — pending legal review');
  expect(getComputedStyle(notice).display).not.toBe('none');

  document.body.dataset.status = 'approved';
  expect(getComputedStyle(notice).display).toBe('none');
});
