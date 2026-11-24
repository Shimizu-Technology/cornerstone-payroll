// Focus moves to the new screen's heading only after the person changes
// screens, so the first load doesn't jump focus.
let focusNextHeading = false;

export function focusHeadingOnNextScreen(): void {
  focusNextHeading = true;
}

export function takeHeadingFocusRequest(): boolean {
  const requested = focusNextHeading;
  focusNextHeading = false;
  return requested;
}
