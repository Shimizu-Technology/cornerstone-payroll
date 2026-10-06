import { ApiError } from '@/services/api';

export function retirementErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError) {
    const details = Object.entries(error.fieldErrors).flatMap(([field, messages]) =>
      messages.map((message) => `${field.replaceAll('_', ' ')}: ${message}`));
    return details.length ? details.join('; ') : error.message;
  }
  return error instanceof Error ? error.message : fallback;
}
