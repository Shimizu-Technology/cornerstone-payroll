import { useId, type ReactElement } from 'react';
import { Textarea, type TextareaProps } from '@/components/ui/textarea';

// The label always names its textarea, including when a caller passes an id.
export function LabeledTextarea({ label, id, ...props }: TextareaProps & { label: string }): ReactElement {
  const generated = useId();
  const fieldId = id || generated;
  return <div className="space-y-1.5">
    <label htmlFor={fieldId} className="block text-xs font-medium text-neutral-600">{label}</label>
    <Textarea {...props} id={fieldId} />
  </div>;
}
