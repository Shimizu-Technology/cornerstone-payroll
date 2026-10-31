import { Building2 } from 'lucide-react';
import { useCompany } from '@/contexts/CompanyContext';

interface HeaderProps {
  title: string;
  description?: string;
  subtitle?: string;
  actions?: React.ReactNode;
  contextLabel?: string;
  contextValue?: string;
  mobileSticky?: boolean;
}

export function Header({ title, description, subtitle, actions, contextLabel, contextValue, mobileSticky = true }: HeaderProps) {
  const helperText = description ?? subtitle;
  const { activeCompany } = useCompany();
  const displayedContext = contextValue || activeCompany?.name;
  const displayedLabel = contextValue ? contextLabel || 'Workspace' : 'Client';

  return (
    <div className={`${mobileSticky ? 'sticky top-0' : 'sm:sticky sm:top-0'} z-10 border-b border-border-subtle bg-surface-panel px-4 py-4 sm:px-6 sm:py-6 lg:px-8`}>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="mb-1.5 flex flex-wrap items-center gap-2">
            {displayedContext && (
              <span className="inline-flex max-w-full items-center gap-1.5 rounded-full border border-primary-100 bg-primary-50/80 px-2.5 py-1 text-xs font-semibold text-neutral-700 shadow-sm shadow-primary-100/40">
                <Building2 className="h-3.5 w-3.5 shrink-0 text-primary-700" />
                <span className="text-neutral-600">{displayedLabel}</span>
                <span className="max-w-[16rem] truncate text-neutral-950 sm:max-w-[22rem]">{displayedContext}</span>
              </span>
            )}
          </div>
          <h1 className="font-display text-[1.65rem] font-extrabold leading-tight tracking-tight text-neutral-950 sm:text-3xl">{title}</h1>
          {helperText && <p className="mt-1.5 max-w-3xl text-sm leading-6 text-neutral-600">{helperText}</p>}
        </div>
        {actions && (
          <div className="flex w-full flex-col gap-2 sm:w-auto sm:flex-row sm:flex-wrap sm:items-center sm:justify-end sm:gap-3 [&>button]:w-full sm:[&>button]:w-auto">
            {actions}
          </div>
        )}
      </div>
    </div>
  );
}

interface PageHeaderProps {
  title: string;
  description?: string;
  backHref?: string;
  actions?: React.ReactNode;
}

export function PageHeader({ title, description, actions }: PageHeaderProps) {
  return (
    <div className="mb-8">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="font-display text-2xl font-extrabold tracking-tight text-neutral-950 sm:text-3xl">{title}</h1>
          {description && <p className="mt-1.5 max-w-3xl text-sm leading-6 text-neutral-600">{description}</p>}
        </div>
        {actions && (
          <div className="flex w-full flex-col gap-2 sm:w-auto sm:flex-row sm:flex-wrap sm:items-center sm:justify-end sm:gap-3 [&>button]:w-full sm:[&>button]:w-auto">
            {actions}
          </div>
        )}
      </div>
    </div>
  );
}
