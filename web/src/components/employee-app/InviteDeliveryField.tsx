import { useId } from 'react';
import type { InviteDelivery } from '@/services/employee-app-rollout-api';

export function InviteDeliveryField({ value, onChange, disabled }: {
  value: InviteDelivery;
  onChange: (delivery: InviteDelivery) => void;
  disabled?: boolean;
}) {
  const name = useId();
  return (
    <fieldset className="space-y-1.5" disabled={disabled}>
      <legend className="text-sm font-semibold text-neutral-800">How to deliver the invite</legend>
      <div className="flex flex-wrap gap-2">
        {([{ value: 'email', label: 'Email' }, { value: 'code', label: 'Printed code' }] as const).map((option) => (
          <label key={option.value} className="flex min-h-11 cursor-pointer items-center gap-2 rounded-lg border border-neutral-200 px-3 text-sm has-checked:border-primary-600 has-checked:bg-primary-50">
            <input type="radio" name={name} value={option.value} className="accent-primary-700" checked={value === option.value} onChange={() => onChange(option.value)} />
            {option.label}
          </label>
        ))}
      </div>
    </fieldset>
  );
}
