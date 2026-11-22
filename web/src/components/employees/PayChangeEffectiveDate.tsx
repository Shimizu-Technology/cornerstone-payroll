import { Input } from '@/components/ui/input';
import {
  payChangeTouchesLockedPayroll,
  type PayChangeEffectiveDates,
  type PayChangeEffectiveDateValue,
  type PayChangeTiming,
} from '@/lib/pay-change';
import { formatDate } from '@/lib/utils';

interface PayChangeEffectiveDateProps {
  dates: PayChangeEffectiveDates;
  canCorrect: boolean;
  value: PayChangeEffectiveDateValue;
  onChange: (value: PayChangeEffectiveDateValue) => void;
  errors?: Record<string, string[]>;
}

export function PayChangeEffectiveDate({ dates, canCorrect, value, onChange, errors = {} }: PayChangeEffectiveDateProps) {
  const update = (patch: Partial<PayChangeEffectiveDateValue>) => onChange({ ...value, ...patch });
  const choices: Array<{ timing: PayChangeTiming; label: string }> = [
    { timing: 'next_uncommitted_period', label: `Start of next uncommitted pay period (${formatDate(dates.next_uncommitted_period)})` },
    { timing: 'today', label: `Today (${formatDate(dates.today)})` },
    { timing: 'custom', label: 'Custom date' },
  ];
  const dateError = errors.compensation_effective_on?.[0];
  const reasonError = errors.compensation_change_reason?.[0];
  const touchesLocked = payChangeTouchesLockedPayroll(value, dates);

  return (
    <div className="mt-6 rounded-2xl border border-amber-200 bg-amber-50 p-4" data-testid="pay-change-effective-date">
      <fieldset aria-describedby="pay-change-effective-help">
        <legend className="text-sm font-semibold text-amber-950">
          When does this pay change take effect? <span className="text-danger-600">*</span>
        </legend>
        <p id="pay-change-effective-help" className="mt-1 text-xs leading-5 text-amber-800">
          Each payroll uses the rate in effect on its pay period end date. Approved and committed payroll keeps the rate it was paid at.
        </p>
        <div className="mt-3 space-y-2">
          {choices.map((choice) => (
            <label key={choice.timing} className="flex min-h-10 items-center gap-3 rounded-xl bg-white px-3 py-2 text-sm text-neutral-900 ring-1 ring-amber-200">
              <input
                type="radio"
                name="compensation_effective_on"
                className="shrink-0"
                value={choice.timing}
                checked={value.timing === choice.timing}
                onChange={() => update({ timing: choice.timing, historicalCorrection: false })}
                aria-invalid={Boolean(dateError)}
              />
              <span className="min-w-0 break-words">{choice.label}</span>
            </label>
          ))}
        </div>
        {value.timing === 'custom' && (
          <div className="mt-3">
            <label htmlFor="pay-change-custom-date" className="block text-xs font-medium text-amber-950">Pay change effective date</label>
            <Input
              id="pay-change-custom-date"
              name="compensation_effective_on"
              type="date"
              className="mt-1 bg-white"
              value={value.customDate}
              onChange={(event) => update({ customDate: event.target.value, historicalCorrection: false })}
              aria-invalid={Boolean(dateError)}
            />
          </div>
        )}
      </fieldset>

      {touchesLocked && canCorrect && (
        <label className="mt-3 flex items-start gap-3 rounded-xl bg-white px-3 py-2 text-sm text-neutral-900 ring-1 ring-amber-300">
          <input
            type="checkbox"
            className="mt-1 shrink-0"
            checked={value.historicalCorrection}
            onChange={(event) => update({ historicalCorrection: event.target.checked })}
          />
          <span>
            Record as a historical correction. The correction ends at the next recorded change or by {formatDate(dates.locked_through as string)}.
            Approved and paid amounts stay as saved. Open payroll ending after that date keeps its existing pay setup.
          </span>
        </label>
      )}
      {dateError && <p className="mt-2 text-sm text-danger-600" role="alert">{dateError}</p>}

      <label htmlFor="pay-change-reason" className="mt-4 block text-sm font-semibold text-amber-950">
        Reason for this pay change <span className="text-danger-600">*</span>
      </label>
      <Input
        id="pay-change-reason"
        name="compensation_change_reason"
        className="mt-1 bg-white"
        value={value.reason}
        onChange={(event) => update({ reason: event.target.value })}
        placeholder="Example: Annual raise approved by the owner"
        aria-invalid={Boolean(reasonError)}
      />
      {reasonError && <p className="mt-1 text-sm text-danger-600">{reasonError}</p>}
    </div>
  );
}
