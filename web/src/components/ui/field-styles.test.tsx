// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { Button } from './button';
import { CONTROL_HEIGHT, controlClassName, FIELD_LABEL, ICON_CONTROL_SIZE } from './field-styles';
import { Input } from './input';
import { NumericInput } from './numeric-input';
import { Select } from './select';

afterEach(cleanup);

const classes = (element: Element) => element.className.split(/\s+/);

describe('controlClassName', () => {
  it('gives every single-line control the shared height and full width by default', () => {
    expect(controlClassName().split(' ')).toEqual(expect.arrayContaining([...CONTROL_HEIGHT.split(' '), 'w-full', 'border-neutral-300']));
  });

  it('lets an explicit height or base width replace the default instead of competing with it', () => {
    const compact = controlClassName('h-9 w-auto').split(' ');
    expect(compact).toEqual(expect.arrayContaining(['h-9', 'w-auto']));
    expect(compact).not.toContain('h-11');
    expect(compact).not.toContain('w-full');
  });

  it('keeps full width on phones when only a breakpoint width is given', () => {
    expect(controlClassName('sm:w-auto').split(' ')).toEqual(expect.arrayContaining(['w-full', 'sm:w-auto']));
  });

  it('uses the error border when invalid', () => {
    const invalid = controlClassName(undefined, { invalid: true }).split(' ');
    expect(invalid).toContain('border-danger-300');
    expect(invalid).not.toContain('border-neutral-300');
  });

  it('keeps the error colours while an invalid field has focus', () => {
    const invalid = controlClassName(undefined, { invalid: true }).split(' ');
    expect(invalid).toEqual(expect.arrayContaining(['focus-visible:border-danger-500', 'focus-visible:ring-danger-200']));
    expect(invalid.filter((name) => name.startsWith('focus-visible:') && name.includes('primary'))).toEqual([]);
    expect(controlClassName().split(' ')).toEqual(expect.arrayContaining(['focus-visible:border-primary-400', 'focus-visible:ring-primary-200']));
  });

  it('keeps the 44px touch height at every width and uses 40px from sm only off touch', () => {
    const names = controlClassName().split(' ');
    // A phone held sideways is wider than `sm`, so the coarse-pointer rule must restore 44px.
    expect(names).toEqual(expect.arrayContaining(['h-11', 'sm:h-10', 'sm:pointer-coarse:h-11']));
    expect(names).toEqual(expect.arrayContaining(['text-base', 'sm:text-sm', 'sm:pointer-coarse:text-base']));
    expect(ICON_CONTROL_SIZE.split(' ')).toEqual(expect.arrayContaining(['h-11', 'w-11', 'sm:h-10', 'sm:w-10', 'sm:pointer-coarse:h-11', 'sm:pointer-coarse:w-11']));
  });
});

it('renders Input, Select and NumericInput with the same height and label style', () => {
  render(<>
    <Input label="Name" />
    <Select label="Type" options={[{ value: 'a', label: 'A' }]} />
    <NumericInput aria-label="Amount" value={1} onValueChange={() => {}} />
  </>);
  const controls = [screen.getByLabelText('Name'), screen.getByLabelText('Type'), screen.getByLabelText('Amount')];
  for (const control of controls) expect(classes(control)).toEqual(expect.arrayContaining(CONTROL_HEIGHT.split(' ')));
  for (const text of ['Name', 'Type']) expect(screen.getByText(text).className).toBe(FIELD_LABEL);
});

it('gives the medium button the same touch rule as the controls beside it', () => {
  render(<><Button>Save</Button><Button size="lg">Continue</Button></>);
  for (const name of ['Save', 'Continue']) {
    const button = classes(screen.getByRole('button', { name }));
    expect(button.some((c) => /^min-h-1[12]$/.test(c))).toBe(true);
  }
  expect(classes(screen.getByRole('button', { name: 'Save' }))).toEqual(expect.arrayContaining(['min-h-11', 'sm:min-h-10', 'sm:pointer-coarse:min-h-11']));
});
