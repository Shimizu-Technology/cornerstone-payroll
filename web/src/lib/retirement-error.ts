import { ApiError } from '@/services/api';
import { errorFieldLabel } from '@/lib/api-error-message';

export function retirementErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError) {
    const details = Object.entries(error.fieldErrors).flatMap(([field, messages]) =>
      messages.map((message) => `${errorFieldLabel(field)}: ${message}`))
      .filter((message) => !error.message.includes(message));
    return [error.message, ...details].join('; ');
  }
  return error instanceof Error ? error.message : fallback;
}
