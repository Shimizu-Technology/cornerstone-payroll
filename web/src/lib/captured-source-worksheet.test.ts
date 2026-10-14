import { describe, expect, it } from 'vitest';
import type { PayrollItem, PayrollItemWageRateHours } from '@/types';
import { capturedSourceContext, capturedSourceHoursLocked, worksheetHoursInvalid, worksheetPayBasisHold } from './captured-source-worksheet';

const bucket = (hours: number, kind: string): PayrollItemWageRateHours => ({
  source_bucket_key: kind, employee_wage_rate_id: 1, label: 'Regular', rate: 25,
  regular_hours: hours, overtime_hours: 0, holiday_hours: 0, pto_hours: 0,
  source_lines: [{ source_time_entry_id: kind, line_key: 'REG', source_time_entry_version: 1,
    source_kind: kind, original_work_date: '2026-10-10', total_hours: hours, regular_hours: hours, overtime_hours: 0 }],
});
const rates = [bucket(6, 'current'), bucket(-1, 'correction')];
const item = { import_source: 'time_tracking:custom:1:BATCH', hours_worked: 5, overtime_hours: 0, wage_rate_hours: rates } as PayrollItem;
const entry = { regular: 5, overtime: 0, wage_rates: rates };

describe('captured Source worksheet validation', () => {
  it('allows only unchanged captured signed buckets with bounded nonnegative net hours', () => {
    expect(worksheetHoursInvalid(entry, item, 200)).toBe(false);
    expect(capturedSourceHoursLocked(item)).toBe(true);
    expect(worksheetHoursInvalid(entry, { ...item, import_source: null } as unknown as PayrollItem, 200)).toBe(true);
    expect(worksheetHoursInvalid(entry, { ...item, timekeeping_source: 'correction_reference', import_source: undefined }, 200)).toBe(true);
  });

  it.each(['rate', 'hours', 'line', 'key', 'missing proof'])('does not exempt changed or incomplete %s evidence', change => {
    const changed = structuredClone(rates);
    if (change === 'rate') changed[1].rate = 99;
    if (change === 'hours') changed[1].regular_hours = -2;
    if (change === 'line') changed[1].source_lines![0].source_time_entry_version = 2;
    if (change === 'key') changed[1].source_bucket_key = 'other';
    if (change === 'missing proof') changed[1].source_lines = [];
    expect(worksheetHoursInvalid({ ...entry, wage_rates: changed }, item, 200)).toBe(true);
  });

  it('retains manual limits and rejects negative net or oversized captured hours', () => {
    expect(worksheetHoursInvalid({ regular: -1, overtime: 0 }, undefined, 200)).toBe(true);
    expect(worksheetHoursInvalid({ regular: 201, overtime: 0 }, undefined, 200)).toBe(true);
    expect(worksheetHoursInvalid({ regular: 1, overtime: 0, wage_rates: [bucket(-201, 'correction')] }, undefined, 200)).toBe(true);
    expect(worksheetHoursInvalid({ regular: 200, overtime: 0 }, undefined, 200)).toBe(false);
  });

  it('labels only recorded work kind/date context, without inventing missing context', () => {
    expect(capturedSourceContext(rates[1])).toBe('Correction · Oct 10, 2026');
    expect(capturedSourceContext({ ...rates[0], source_lines: undefined })).toBeNull();
  });

  it('holds recorded imported basis mismatch and legacy missing earning evidence without inventing current rates', () => {
    const retained = { ...item, employment_type: 'hourly' } as PayrollItem;
    expect(worksheetPayBasisHold(retained, { employment_type: 'salary' } as import('@/types').Employee)?.reason).toContain('differs');
    expect(worksheetPayBasisHold({ ...retained, wage_rate_hours: [] })?.reason).toContain('evidence is unavailable');
    expect(worksheetPayBasisHold(retained, { employment_type: 'hourly' } as import('@/types').Employee)).toBeNull();
    const serverHold = { reason: 'Retained frequency requires review.' };
    expect(worksheetPayBasisHold({ ...retained, correction_pay_basis_hold: serverHold })).toBe(serverHold);
  });
});
