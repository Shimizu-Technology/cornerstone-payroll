import { useId, type ReactNode, type SelectHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

const SELECT = 'block min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-base text-neutral-900 shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200';

interface SelectFieldProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label: string;
  help?: ReactNode;
  wrapperClassName?: string;
}

/** A label and select side by side, so the select's name is only its label. */
export function SelectField({ label, help, wrapperClassName, className, children, ...props }: SelectFieldProps) {
  const id = useId();
  const helpId = `${id}-help`;
  return (
    <div className={wrapperClassName}>
      <label htmlFor={id} className="block text-sm font-medium text-neutral-700">{label}</label>
      <select id={id} aria-describedby={help ? helpId : undefined} className={cn(SELECT, 'mt-1.5', className)} {...props}>{children}</select>
      {help && <p id={helpId} className="mt-1 text-xs leading-5 text-neutral-600">{help}</p>}
    </div>
  );
}
