// Plain words for why the API refused an employee email. The API sends the
// reason as contact_validation.email_error_code; login conflicts keep the
// server's own message.
const reasonMessages: Record<string, string> = {
  invalid_email: "This isn't a complete email address. Check it for typos.",
  placeholder_email: "Not a real email. Use the employee's own address.",
  recipient_not_allowed: "Email from this client's account can't go to this address. Use a different address.",
};

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

/** The plain message for a refused email in an API error body, or null. */
export function contactEmailErrorMessage(data: unknown): string | null {
  const code = record(record(data).contact_validation).email_error_code;
  return typeof code === 'string' ? reasonMessages[code] ?? null : null;
}
