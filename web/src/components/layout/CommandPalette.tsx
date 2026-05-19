import { createPortal } from 'react-dom';
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import {
  Building2,
  Calculator,
  CalendarDays,
  Check,
  ClipboardCheck,
  FileBarChart2,
  FileSpreadsheet,
  FolderOpen,
  HandCoins,
  LayoutDashboard,
  Link2,
  Printer,
  ReceiptText,
  ScanLine,
  Search,
  Settings,
  SlidersHorizontal,
  Users,
  WalletCards,
  X,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { analytics } from '@/lib/analytics';
import { getCompanySwitchRedirect } from '@/lib/company-switching';
import { cn } from '@/lib/utils';

interface CommandPaletteProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

type CommandKind = 'navigation' | 'company';

interface CommandItem {
  id: string;
  label: string;
  description: string;
  group: string;
  keywords: string[];
  icon: ReactNode;
  kind: CommandKind;
  href?: string;
  companyId?: number;
}

function shortcutLabel() {
  if (typeof navigator !== 'undefined' && /Mac|iPhone|iPad|iPod/.test(navigator.platform)) {
    return '⌘K';
  }
  return 'Ctrl K';
}

function normalize(value: string) {
  return value.trim().toLowerCase();
}

function scoreCommand(command: CommandItem, query: string) {
  if (!query) return 1;

  const haystack = [command.label, command.description, command.group, ...command.keywords]
    .join(' ')
    .toLowerCase();
  const label = command.label.toLowerCase();

  if (label === query) return 100;
  if (label.startsWith(query)) return 80;
  if (haystack.includes(query)) return 50;

  const terms = query.split(/\s+/).filter(Boolean);
  return terms.every((term) => haystack.includes(term)) ? 25 : 0;
}

export function CommandPalette({ open, onOpenChange }: CommandPaletteProps) {
  const navigate = useNavigate();
  const location = useLocation();
  const { isAdmin, isSuperAdmin, isClient } = useAuth();
  const { companies, activeCompany, canSwitchCompany, switchCompany } = useCompany();
  const [query, setQuery] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const commandButtonRefs = useRef<Array<HTMLButtonElement | null>>([]);

  const commands = useMemo<CommandItem[]>(() => {
    const items: CommandItem[] = [
      {
        id: 'go-dashboard',
        label: 'Dashboard',
        description: 'Open the main workspace overview.',
        group: 'Go to',
        keywords: ['home', 'overview', 'app'],
        icon: <LayoutDashboard className="h-4 w-4" />,
        kind: 'navigation',
        href: '/app',
      },
      {
        id: 'go-pay-periods',
        label: 'Pay Periods',
        description: 'Review, calculate, approve, and commit payroll runs.',
        group: 'Payroll',
        keywords: ['payroll', 'run payroll', 'periods'],
        icon: <CalendarDays className="h-4 w-4" />,
        kind: 'navigation',
        href: '/pay-periods',
      },
      {
        id: 'go-employees',
        label: 'Employees',
        description: 'Manage employee profiles, rates, and payroll setup.',
        group: 'People',
        keywords: ['workers', 'staff', 'employee list'],
        icon: <Users className="h-4 w-4" />,
        kind: 'navigation',
        href: '/employees',
      },
      {
        id: 'new-employee',
        label: 'Add Employee',
        description: 'Create a new employee or contractor record.',
        group: 'People',
        keywords: ['new employee', 'hire', 'contractor'],
        icon: <Users className="h-4 w-4" />,
        kind: 'navigation',
        href: '/employees/new',
      },
      {
        id: 'go-departments',
        label: 'Departments',
        description: 'Manage department lists for payroll grouping.',
        group: 'People',
        keywords: ['teams', 'groups'],
        icon: <Building2 className="h-4 w-4" />,
        kind: 'navigation',
        href: '/departments',
      },
      {
        id: 'go-reports',
        label: 'Reports Center',
        description: 'Open payroll, tax, and compliance reports.',
        group: 'Reports',
        keywords: ['reports', 'exports'],
        icon: <FileBarChart2 className="h-4 w-4" />,
        kind: 'navigation',
        href: '/reports',
      },
    ];

    if (!isClient) {
      items.push(
        {
          id: 'go-checks-payments',
          label: 'Checks & Payments',
          description: 'Manage standalone checks, tax deposits, and payment records.',
          group: 'Payroll',
          keywords: ['checks', 'payments', 'deposits'],
          icon: <WalletCards className="h-4 w-4" />,
          kind: 'navigation',
          href: '/checks-payments',
        },
        {
          id: 'quarterly-compliance',
          label: 'Quarterly Compliance Packet',
          description: 'Open Form 500, W-1, SWICA, 941, and Schedule B workflow.',
          group: 'Compliance',
          keywords: ['quarterly', 'form 500', 'w1', 'swica', '941', 'schedule b'],
          icon: <ClipboardCheck className="h-4 w-4" />,
          kind: 'navigation',
          href: '/reports?report=quarterly_compliance_packet',
        },
        {
          id: 'form-941',
          label: 'Federal Form 941 Report',
          description: 'Open the Guam-aware Federal Form 941 worksheet.',
          group: 'Compliance',
          keywords: ['941', 'federal', 'tax'],
          icon: <FileSpreadsheet className="h-4 w-4" />,
          kind: 'navigation',
          href: '/reports?report=form_941_gu',
        },
        {
          id: 'tax-summary',
          label: 'Tax Summary',
          description: 'Review quarterly or annual payroll tax totals.',
          group: 'Compliance',
          keywords: ['tax', 'withholding', 'fica'],
          icon: <Calculator className="h-4 w-4" />,
          kind: 'navigation',
          href: '/reports?report=tax_summary',
        },
        {
          id: 'employee-loans',
          label: 'Employee Loans',
          description: 'Manage employee installment loan balances and payments.',
          group: 'Payroll',
          keywords: ['loans', 'deductions'],
          icon: <HandCoins className="h-4 w-4" />,
          kind: 'navigation',
          href: '/employee-loans',
        },
        {
          id: 'timecard-ocr',
          label: 'Timecard OCR',
          description: 'Import and review scanned timecards.',
          group: 'Tools',
          keywords: ['timecards', 'ocr', 'scan'],
          icon: <ScanLine className="h-4 w-4" />,
          kind: 'navigation',
          href: '/tools/timecard-ocr',
        },
        {
          id: 'transmittals',
          label: 'General Transmittals',
          description: 'Prepare and manage transmittal documents.',
          group: 'Tools',
          keywords: ['transmittal', 'documents'],
          icon: <ReceiptText className="h-4 w-4" />,
          kind: 'navigation',
          href: '/tools/transmittals',
        },
        {
          id: 'invoice-maker',
          label: 'Invoice Maker',
          description: 'Create and manage client invoices.',
          group: 'Tools',
          keywords: ['invoice', 'billing'],
          icon: <ReceiptText className="h-4 w-4" />,
          kind: 'navigation',
          href: '/tools/invoices',
        },
        {
          id: 'client-documents-admin',
          label: 'Client Documents',
          description: 'Review documents uploaded through the client portal.',
          group: 'Client Portal',
          keywords: ['documents', 'portal', 'uploads'],
          icon: <FolderOpen className="h-4 w-4" />,
          kind: 'navigation',
          href: '/settings/client-documents',
        },
        {
          id: 'check-settings',
          label: 'Check Settings',
          description: 'Adjust check stock, printer profiles, and check layout.',
          group: 'Settings',
          keywords: ['printer', 'checks', 'layout'],
          icon: <Printer className="h-4 w-4" />,
          kind: 'navigation',
          href: '/check-settings',
        },
        {
          id: 'time-tracking-sources',
          label: 'Time Tracking Sources',
          description: 'Configure external time tracking import sources.',
          group: 'Settings',
          keywords: ['time tracking', 'integrations'],
          icon: <Link2 className="h-4 w-4" />,
          kind: 'navigation',
          href: '/time-tracking-sources',
        }
      );
    }

    if (isClient) {
      items.push({
        id: 'client-documents',
        label: 'Documents',
        description: 'View and upload payroll documents.',
        group: 'Client Portal',
        keywords: ['client documents', 'uploads'],
        icon: <FolderOpen className="h-4 w-4" />,
        kind: 'navigation',
        href: '/documents',
      });
    }

    if (isAdmin) {
      items.push(
        {
          id: 'clients',
          label: 'Client Management',
          description: 'Manage company/client records.',
          group: 'Administration',
          keywords: ['clients', 'companies'],
          icon: <Building2 className="h-4 w-4" />,
          kind: 'navigation',
          href: '/settings/clients',
        },
        {
          id: 'users',
          label: 'User Management',
          description: 'Invite and manage staff and client users.',
          group: 'Administration',
          keywords: ['users', 'permissions', 'invites'],
          icon: <Users className="h-4 w-4" />,
          kind: 'navigation',
          href: '/settings/users',
        },
        {
          id: 'tax-config',
          label: 'Tax Configuration',
          description: 'Review tax tables and payroll tax configuration.',
          group: 'Administration',
          keywords: ['tax config', 'rates'],
          icon: <SlidersHorizontal className="h-4 w-4" />,
          kind: 'navigation',
          href: '/settings/tax-config',
        }
      );
    }

    if (isSuperAdmin) {
      items.push({
        id: 'organizations',
        label: 'Organizations',
        description: 'Manage organization-level settings and accounts.',
        group: 'Platform',
        keywords: ['orgs', 'platform'],
        icon: <Settings className="h-4 w-4" />,
        kind: 'navigation',
        href: '/settings/organizations',
      });
    }

    if (canSwitchCompany && companies.length > 1) {
      companies.forEach((company) => {
        items.push({
          id: `company-${company.id}`,
          label: company.name,
          description: `${company.active_employees} active employees · ${company.pay_frequency}`,
          group: 'Switch client',
          keywords: ['client', 'company', 'switch', company.name],
          icon: company.id === activeCompany?.id ? <Check className="h-4 w-4" /> : <Building2 className="h-4 w-4" />,
          kind: 'company',
          companyId: company.id,
        });
      });
    }

    return items;
  }, [activeCompany?.id, canSwitchCompany, companies, isAdmin, isClient, isSuperAdmin]);

  const filteredCommands = useMemo(() => {
    const normalizedQuery = normalize(query);
    return commands
      .map((command) => ({ command, score: scoreCommand(command, normalizedQuery) }))
      .filter((row) => row.score > 0)
      .sort((left, right) => right.score - left.score || left.command.group.localeCompare(right.command.group) || left.command.label.localeCompare(right.command.label))
      .map((row) => row.command)
      .slice(0, 12);
  }, [commands, query]);

  const safeSelectedIndex = filteredCommands.length === 0
    ? -1
    : Math.min(selectedIndex, filteredCommands.length - 1);

  useEffect(() => {
    if (!open || safeSelectedIndex < 0) return;
    commandButtonRefs.current[safeSelectedIndex]?.scrollIntoView({ block: 'nearest' });
  }, [open, safeSelectedIndex, filteredCommands]);

  useEffect(() => {
    if (!open) return;
    const focusTimer = window.setTimeout(() => {
      setQuery('');
      setSelectedIndex(0);
      inputRef.current?.focus();
    }, 0);
    return () => window.clearTimeout(focusTimer);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = previous;
    };
  }, [open]);

  const runCommand = (command: CommandItem) => {
    onOpenChange(false);

    if (command.kind === 'company' && command.companyId) {
      if (command.companyId === activeCompany?.id) return;

      const redirect = getCompanySwitchRedirect(location.pathname);
      analytics.companySwitch(command.companyId);
      switchCompany(command.companyId);

      if (redirect) {
        navigate(redirect.to, {
          state: { companySwitchNotice: redirect.notice },
        });
      }
      return;
    }

    if (command.href) navigate(command.href);
  };

  if (!open || typeof document === 'undefined') return null;

  return createPortal(
    <div className="fixed inset-0 z-[140] overflow-hidden" role="dialog" aria-modal="true" aria-label="Command palette">
      <button
        type="button"
        aria-label="Close command palette"
        className="absolute inset-0 bg-neutral-950/35 backdrop-blur-[2px]"
        onClick={() => onOpenChange(false)}
      />
      <div className="pointer-events-none absolute inset-x-3 top-12 mx-auto max-w-2xl sm:top-20">
        <div className="pointer-events-auto overflow-hidden rounded-3xl border border-white/80 bg-white shadow-2xl shadow-neutral-950/20 ring-1 ring-neutral-950/5">
          <div className="border-b border-neutral-200/80 bg-gradient-to-r from-neutral-50 to-white px-4 py-3">
            <div className="flex items-center gap-3">
              <Search className="h-5 w-5 shrink-0 text-neutral-400" />
              <input
                ref={inputRef}
                value={query}
                onChange={(event) => {
                  setQuery(event.target.value);
                  setSelectedIndex(0);
                }}
                onKeyDown={(event) => {
                  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
                    event.preventDefault();
                    onOpenChange(false);
                    return;
                  }
                  if (event.key === 'Escape') {
                    event.preventDefault();
                    onOpenChange(false);
                    return;
                  }
                  if (event.key === 'ArrowDown') {
                    event.preventDefault();
                    setSelectedIndex((index) => Math.min(index + 1, Math.max(filteredCommands.length - 1, 0)));
                    return;
                  }
                  if (event.key === 'ArrowUp') {
                    event.preventDefault();
                    setSelectedIndex((index) => Math.max(index - 1, 0));
                    return;
                  }
                  if (event.key === 'Enter' && safeSelectedIndex >= 0) {
                    event.preventDefault();
                    runCommand(filteredCommands[safeSelectedIndex]);
                  }
                }}
                placeholder="Search pages, reports, actions, or clients..."
                className="h-10 flex-1 bg-transparent text-base font-medium text-neutral-950 outline-none placeholder:text-neutral-400"
              />
              <div className="hidden items-center gap-1 rounded-lg border border-neutral-200 bg-white px-2 py-1 text-[11px] font-semibold uppercase tracking-[0.08em] text-neutral-500 sm:flex">
                {shortcutLabel()}
              </div>
              <button
                type="button"
                className="rounded-full p-2 text-neutral-400 transition hover:bg-neutral-100 hover:text-neutral-700"
                onClick={() => onOpenChange(false)}
                aria-label="Close command palette"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>

          <div className="max-h-[min(68vh,34rem)] overflow-y-auto p-2">
            {filteredCommands.length === 0 ? (
              <div className="px-5 py-12 text-center">
                <p className="text-sm font-semibold text-neutral-900">No matching commands</p>
                <p className="mt-1 text-sm text-neutral-500">Try searching for payroll, reports, employees, or a client name.</p>
              </div>
            ) : (
              <div className="space-y-1">
                {filteredCommands.map((command, index) => (
                  <button
                    type="button"
                    key={command.id}
                    ref={(element) => {
                      commandButtonRefs.current[index] = element;
                    }}
                    onClick={() => runCommand(command)}
                    onMouseEnter={() => setSelectedIndex(index)}
                    className={cn(
                      'flex w-full items-center gap-3 rounded-2xl px-3 py-3 text-left transition',
                      index === safeSelectedIndex ? 'bg-primary-50 text-primary-950 ring-1 ring-primary-100' : 'text-neutral-800 hover:bg-neutral-50'
                    )}
                  >
                    <span className={cn(
                      'flex h-9 w-9 shrink-0 items-center justify-center rounded-xl border',
                      index === safeSelectedIndex ? 'border-primary-200 bg-white text-primary-700' : 'border-neutral-200 bg-neutral-50 text-neutral-500'
                    )}>
                      {command.icon}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-2">
                        <span className="truncate text-sm font-semibold">{command.label}</span>
                        <span className="rounded-full bg-white/80 px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.1em] text-neutral-400 ring-1 ring-neutral-200/80">
                          {command.group}
                        </span>
                      </span>
                      <span className="mt-0.5 block truncate text-xs text-neutral-500">{command.description}</span>
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>,
    document.body
  );
}
