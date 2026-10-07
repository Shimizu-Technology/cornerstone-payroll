const fieldNames: Record<string, string> = {
  effective_on: 'First pay date',
  plan_source_reference: 'Plan document or administrator reference',
  prior_year_fica_wages: 'Prior-year Social Security wages',
  prior_year_wage_source: 'Employer wage evidence reference',
  historical_retirement_review: 'Historical contribution review',
  source_reference: 'Evidence reference',
  reason: 'Review note',
  lock_version: 'Record version',
};

export function errorFieldLabel(field: string): string {
  return fieldNames[field] || field.replaceAll('_', ' ');
}

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown> : {};
}

function messages(value: unknown): string[] {
  if (typeof value === 'string') return value.trim() ? [value.trim()] : [];
  if (Array.isArray(value)) return value.flatMap(messages);
  if (value === null || typeof value !== 'object') return [];
  const entry = record(value);
  return messages(entry.error ?? entry.message);
}

/** Preserve the server's explanation and validation details in every API path. */
export function apiErrorMessage(data: unknown, status: number): string {
  const payload = record(data);
  const primary = messages(payload.error);
  const errors = Array.isArray(payload.errors) ? messages(payload.errors) : [];
  const fields = { ...record(payload.errors), ...record(payload.details) };
  const details = Object.entries(fields).flatMap(([field, value]) => {
    if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) return [];
    return value.map((message) => field === 'base' ? message : `${errorFieldLabel(field)}: ${message}`);
  });
  const explanations = [...new Set([...primary, ...errors, ...details])];
  const fallback: Record<number, string> = {
    400: 'The request could not be accepted. Check the entered values and try again.',
    401: 'Your session could not be authenticated. Sign in again, then retry.',
    403: 'You do not have permission for this action. Ask an administrator to check your access.',
    404: 'This record could not be found. Refresh the list and open it again.',
    409: 'This record has changed. Reload it and review the latest values before trying again.',
    413: 'This file is too large. Choose a smaller file and upload it again.',
    422: 'Some values could not be accepted. Check the form and try again.',
    429: 'Too many requests were sent. Wait a moment and try again.',
  };
  if (!explanations.length) return fallback[status] || (status >= 500
    ? 'The server could not complete this request. Check whether your changes were saved before retrying. If it keeps failing, contact support with the page and action.'
    : `The request could not be completed (HTTP ${status}). Refresh the page and try again.`);
  const message = explanations.join('; ');
  // These outcomes have a definite recovery step regardless of the endpoint.
  const recovery: Record<number, string> = {
    401: 'Sign in again, then retry.',
    403: 'Ask an administrator to check your access.',
    409: 'Reload the record and review the latest values before trying again.',
    429: 'Wait a moment before trying again.',
  };
  return recovery[status] && !message.toLowerCase().includes(recovery[status].toLowerCase())
    ? `${message} ${recovery[status]}` : message;
}
