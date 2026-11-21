// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { CONTROL_HEIGHT, controlClassName, FIELD_LABEL } from './field-styles';
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
