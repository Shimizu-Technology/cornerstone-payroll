interface HeaderProps {
  title: string;
  description?: string;
  subtitle?: string;
  actions?: React.ReactNode;
}

export function Header({ title, description, subtitle, actions }: HeaderProps) {
  const helperText = description ?? subtitle;

  return (
    <div className="sticky top-0 z-10 border-b border-neutral-200/70 bg-white/80 px-4 py-5 backdrop-blur-xl sm:px-6 sm:py-6 lg:px-8">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="mb-1 text-[11px] font-bold uppercase tracking-[0.16em] text-primary-700">Workspace</p>
          <h1 className="font-display text-2xl font-extrabold tracking-tight text-neutral-950 sm:text-3xl">{title}</h1>
          {helperText && <p className="mt-1.5 max-w-3xl text-sm leading-6 text-neutral-500">{helperText}</p>}
        </div>
        {actions && (
          <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:justify-end sm:gap-3">
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
          {description && <p className="mt-1.5 max-w-3xl text-sm leading-6 text-neutral-500">{description}</p>}
        </div>
        {actions && (
          <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:justify-end sm:gap-3">
            {actions}
          </div>
        )}
      </div>
    </div>
  );
}
