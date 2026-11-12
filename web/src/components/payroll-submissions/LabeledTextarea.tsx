import { useId, type ReactElement } from 'react';
import { Textarea, type TextareaProps } from '@/components/ui/textarea';

export function LabeledTextarea({ label, ...props }: TextareaProps & { label: string }): ReactElement {
  const id = useId();
  return <div className="space-y-1.5">
    <label htmlFor={id} className="block text-xs font-medium text-neutral-600">{label}</label>
    <Textarea id={id} {...props} />
  </div>;
}
