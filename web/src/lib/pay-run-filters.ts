export function parsePayRunYear(value: string | null): number | undefined {
  if (!value || !/^\d{4}$/.test(value)) return undefined;

  const year = Number(value);
  return year >= 1900 && year <= 9999 ? year : undefined;
}

export function parsePayRunId(value: string | undefined): number | undefined {
  if (!value || !/^\d+$/.test(value)) return undefined;

  const payRunId = Number(value);
  return Number.isSafeInteger(payRunId) && payRunId > 0 ? payRunId : undefined;
}

interface PayrollCheckStatus {
  check_number?: string | null;
  voided?: boolean;
}

export function countActivePayrollChecks(items: PayrollCheckStatus[]): number {
  return items.filter((item) => Boolean(item.check_number) && !item.voided).length;
}
