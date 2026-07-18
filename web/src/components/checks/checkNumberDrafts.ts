export function checkNumberValidationError(value: string, allowBlank = false) {
  const normalized = value.trim();
  if (!normalized && !allowBlank) return 'Enter a check number.';
  if (normalized && !/^\d+$/.test(normalized)) return 'Use numbers only.';
  if (normalized && Number(normalized) < 1) return 'Must be greater than 0.';
  if (normalized && Number(normalized) > 9_999_999) return 'Must be 9,999,999 or less.';
  return null;
}
