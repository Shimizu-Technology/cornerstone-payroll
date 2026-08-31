import type { ReactElement, ReactNode } from 'react';

interface SettingsSectionProps {
  eyebrow?: string;
  title: string;
  description: string;
  actions?: ReactNode;
  children: ReactNode;
}

export function SettingsSection({ eyebrow = 'Client configuration', title, description, actions, children }: SettingsSectionProps): ReactElement {
  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 border-b border-neutral-200 pb-5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">{eyebrow}</p>
          <h2 className="mt-1 font-display text-2xl font-extrabold tracking-tight text-neutral-950">{title}</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-neutral-500">{description}</p>
        </div>
        {actions && <div className="shrink-0">{actions}</div>}
      </div>
      {children}
    </div>
  );
}
