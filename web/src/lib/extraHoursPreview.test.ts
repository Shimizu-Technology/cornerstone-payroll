import { describe, expect, it } from 'vitest';
import { computeExtraHoursPreview } from './extraHoursPreview';

describe('computeExtraHoursPreview', () => {
  it('computes biweekly week 2 extra hours accurately (45/35 + 6.50 in week 2 -> 80.00 reg / 6.50 OT, +$145.00)', () => {
    const result = computeExtraHoursPreview({
      mode: 'workweek',
      rate: '20.0',
      baselineRegularHours: '75.0',
      baselineOvertimeHours: '5.0',
      baselineWeek1Hours: '45.0',
      baselineWeek2Hours: '35.0',
      hours: '6.50',
      workweek: 2,
      workweekCount: 2,
    });
    expect(result).toEqual({
      valid: true,
      totalHours: 6.5,
      deltaRegularHours: 5,
      deltaOvertimeHours: 1.5,
      resultingRegularHours: 80,
      resultingOvertimeHours: 6.5,
      resultingWeek1Hours: 45,
      resultingWeek2Hours: 41.5,
      grossPayDelta: 145,
    });
  });

  it('computes biweekly week 1 extra hours accurately (45/35 + 6.50 in week 1 -> 75.00 reg / 11.50 OT, +$195.00)', () => {
    const result = computeExtraHoursPreview({
      mode: 'workweek',
      rate: '20.0',
      baselineRegularHours: '75.0',
      baselineOvertimeHours: '5.0',
      baselineWeek1Hours: '45.0',
      baselineWeek2Hours: '35.0',
      hours: '6.50',
      workweek: 1,
      workweekCount: 2,
    });
    expect(result).toEqual({
      valid: true,
      totalHours: 6.5,
      deltaRegularHours: 0,
      deltaOvertimeHours: 6.5,
      resultingRegularHours: 75,
      resultingOvertimeHours: 11.5,
      resultingWeek1Hours: 51.5,
      resultingWeek2Hours: 35,
      grossPayDelta: 195,
    });
  });

  it('computes source_reports split accurately (4 reg + 2.5 OT @ $20/hr -> +$155.00)', () => {
    const result = computeExtraHoursPreview({
      mode: 'split',
      rate: '20.0',
      baselineRegularHours: '70.0',
      baselineOvertimeHours: '2.0',
      regularHours: '4',
      overtimeHours: '2.5',
    });
    expect(result).toEqual({
      valid: true,
      totalHours: 6.5,
      deltaRegularHours: 4,
      deltaOvertimeHours: 2.5,
      resultingRegularHours: 74,
      resultingOvertimeHours: 4.5,
      grossPayDelta: 155,
    });
  });

  it('keeps contractor extra hours straight time with no OT', () => {
    const result = computeExtraHoursPreview({
      mode: 'straight_time',
      rate: '20.0',
      baselineRegularHours: '75.0',
      baselineOvertimeHours: '0.0',
      hours: '6.50',
    });
    expect(result).toEqual({
      valid: true,
      totalHours: 6.5,
      deltaRegularHours: 6.5,
      deltaOvertimeHours: 0,
      resultingRegularHours: 81.5,
      resultingOvertimeHours: 0,
      grossPayDelta: 130,
    });
  });

  it('marks biweekly workweek invalid until a week is chosen', () => {
    const result = computeExtraHoursPreview({
      mode: 'workweek',
      rate: '20.0',
      baselineRegularHours: '75.0',
      baselineOvertimeHours: '5.0',
      baselineWeek1Hours: '45.0',
      baselineWeek2Hours: '35.0',
      hours: '6.50',
      workweek: undefined,
      workweekCount: 2,
    });
    expect(result.valid).toBe(false);
    expect(result.error).toContain('workweek');
  });

  it('marks split invalid when neither regular nor overtime is entered', () => {
    const result = computeExtraHoursPreview({
      mode: 'split',
      rate: '20.0',
      baselineRegularHours: '70.0',
      baselineOvertimeHours: '2.0',
      regularHours: '',
      overtimeHours: '',
    });
    expect(result.valid).toBe(false);
    expect(result.error).toContain('regular hours');
  });

  it('rounds per resulting earnings line so preview matches saved gross to the exact cent (0.01h + 0.05h @ $10.50 -> +$0.52)', () => {
    const split = computeExtraHoursPreview({
      mode: 'split',
      rate: '10.50',
      baselineRegularHours: '0.01',
      baselineOvertimeHours: '0.00',
      regularHours: '0.05',
      overtimeHours: '0',
    });
    expect(split.grossPayDelta).toBe(0.52);

    const workweek = computeExtraHoursPreview({
      mode: 'workweek',
      rate: '10.50',
      baselineRegularHours: '0.01',
      baselineOvertimeHours: '0.00',
      baselineWeek1Hours: '0.01',
      baselineWeek2Hours: '0.00',
      hours: '0.05',
      workweek: 1,
      workweekCount: 2,
    });
    expect(workweek.grossPayDelta).toBe(0.52);

    const contractor = computeExtraHoursPreview({
      mode: 'straight_time',
      rate: '10.50',
      baselineRegularHours: '0.01',
      baselineOvertimeHours: '0.00',
      hours: '0.05',
    });
    expect(contractor.grossPayDelta).toBe(0.52);

    // Separate job line starting at 0h rounds its own line independently: round(0.05 * 10.50) = 0.53
    const separateJob = computeExtraHoursPreview({
      mode: 'split',
      rate: '10.50',
      baselineRegularHours: '0.01',
      baselineOvertimeHours: '0.00',
      baselineLineRegularHours: '0.00',
      baselineLineOvertimeHours: '0.00',
      regularHours: '0.05',
      overtimeHours: '0',
    });
    expect(separateJob.grossPayDelta).toBe(0.53);
  });

  it('parses hourly rates with up to 6 decimal places ($20.125/hr, 2 OT -> +$60.38)', () => {
    const result = computeExtraHoursPreview({
      mode: 'split',
      rate: '20.125',
      baselineRegularHours: '40.00',
      baselineOvertimeHours: '0.00',
      regularHours: '0',
      overtimeHours: '2',
    });
    expect(result).toEqual({
      valid: true,
      totalHours: 2,
      deltaRegularHours: 0,
      deltaOvertimeHours: 2,
      resultingRegularHours: 40,
      resultingOvertimeHours: 2,
      grossPayDelta: 60.38,
    });

    const sixDecimals = computeExtraHoursPreview({
      mode: 'straight_time',
      rate: '20.123456',
      baselineRegularHours: '0',
      baselineOvertimeHours: '0',
      hours: '10',
    });
    expect(sixDecimals.grossPayDelta).toBe(201.23);
  });

  it('rejects workweek previews when weekly baselines do not reconcile with aggregate baselines', () => {
    const mismatched = computeExtraHoursPreview({
      mode: 'workweek',
      rate: '20.0',
      baselineRegularHours: '75.0',
      baselineOvertimeHours: '5.0',
      hours: '1',
      workweek: 1,
      workweekCount: 2,
    });
    expect(mismatched.valid).toBe(false);
    expect(mismatched.error).toContain('Weekly hours baseline does not match');
    expect(mismatched.grossPayDelta).toBeNull();
  });
});
