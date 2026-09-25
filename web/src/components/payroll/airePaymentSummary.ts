import type { AirePostLockComparison } from '@/types';

type SourceRow = AirePostLockComparison['rows'][number];
export type HourPair = { regular: number; overtime: number };
export type EmployeeSummary = {
  key: string; name: string; owed: HourPair; awaiting: HourPair; paid: HourPair; held: HourPair;
  remaining: Array<{ row: SourceRow; regular: number; overtime: number }>;
  payments: SourceRow[]; heldRows: SourceRow[]; reviewRows: SourceRow[];
};

export const sumHours = (pair: HourPair) => pair.regular + pair.overtime;
const blank = (): HourPair => ({ regular: 0, overtime: 0 });
const employeeKey = (row: SourceRow) => row.source_user_uuid || (row.employee_id ? `employee-${row.employee_id}` : `name-${row.employee_name}`);
const entryKey = (row: SourceRow) => `${employeeKey(row)}:${row.source_time_entry_id}:${row.work_date}`;

// Cutoff lines are immutable. Subtract only payment links with the same source
// employee, entry and work date when showing what remains to pay now.
export function summarizeEmployees(rows: SourceRow[]): EmployeeSummary[] {
  const employees = new Map<string, EmployeeSummary>();
  const allocations = new Map<string, HourPair>();
  rows.filter((row) => row.status === 'paid' || row.status === 'awaiting_payment').forEach((row) => {
    const key = entryKey(row);
    const value = allocations.get(key) || blank();
    value.regular += row.regular_hours;
    value.overtime += row.overtime_hours;
    allocations.set(key, value);
  });
  rows.forEach((row) => {
    const key = employeeKey(row);
    let employee = employees.get(key);
    if (!employee) {
      employee = { key, name: row.employee_name, owed: blank(), awaiting: blank(), paid: blank(), held: blank(),
        remaining: [], payments: [], heldRows: [], reviewRows: [] };
      employees.set(key, employee);
    }
    if (row.status === 'owed') {
      const applied = allocations.get(entryKey(row)) || blank();
      const regular = Math.max(0, row.regular_hours - applied.regular);
      const overtime = Math.max(0, row.overtime_hours - applied.overtime);
      applied.regular = Math.max(0, applied.regular - row.regular_hours);
      applied.overtime = Math.max(0, applied.overtime - row.overtime_hours);
      employee.owed.regular += regular;
      employee.owed.overtime += overtime;
      if (regular + overtime > 0) employee.remaining.push({ row, regular, overtime });
    } else if (row.status === 'paid' || row.status === 'awaiting_payment') {
      const value = row.status === 'paid' ? employee.paid : employee.awaiting;
      value.regular += row.regular_hours;
      value.overtime += row.overtime_hours;
      employee.payments.push(row);
    } else if (row.status === 'held') {
      employee.held.regular += row.regular_hours;
      employee.held.overtime += row.overtime_hours;
      employee.heldRows.push(row);
    } else employee.reviewRows.push(row);
  });
  return [...employees.values()].sort((a, b) => a.name.localeCompare(b.name));
}
