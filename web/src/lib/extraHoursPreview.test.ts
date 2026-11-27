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
});
