import { useState, useRef, useEffect } from 'react';
import { useCompany } from '@/contexts/CompanyContext';
import { analytics } from '@/lib/analytics';

export function CompanySwitcher() {
  const { companies, activeCompany, canSwitchCompany, switchCompany } = useCompany();
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  if (!canSwitchCompany || companies.length <= 1) {
    return (
      <div className="border-b border-neutral-200/70 px-4 py-3">
        <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-400">Company</p>
        <p className="mt-0.5 truncate text-sm font-semibold text-neutral-900">
          {activeCompany?.name || 'Loading...'}
        </p>
      </div>
    );
  }

  return (
    <div className="relative border-b border-neutral-200/70 px-4 py-3" ref={dropdownRef}>
      <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-400">Active Client</p>
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="mt-1 flex w-full items-center justify-between rounded-xl border border-neutral-200 bg-neutral-50/70 px-3 py-2 text-left transition-colors hover:bg-neutral-100"
      >
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-semibold text-neutral-900">
            {activeCompany?.name || 'Select Company'}
          </p>
          <p className="text-xs text-neutral-500">
            {activeCompany?.active_employees || 0} employees
          </p>
        </div>
        <svg
          className={`h-4 w-4 text-neutral-400 transition-transform duration-200 ${isOpen ? 'rotate-180' : ''}`}
          fill="none" stroke="currentColor" viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {isOpen && (
        <div className="absolute left-2 right-2 z-50 mt-1 max-h-64 overflow-y-auto rounded-xl border border-neutral-200 bg-white shadow-lg">
          {companies.map(company => (
            <button
              key={company.id}
              onClick={() => {
                switchCompany(company.id);
                analytics.companySwitch(company.id);
                setIsOpen(false);
              }}
              className={`flex w-full items-center justify-between border-b border-neutral-100 px-4 py-3 text-left transition-colors last:border-0 hover:bg-primary-50 ${
                company.id === activeCompany?.id ? 'border-l-2 border-l-primary-600 bg-primary-50' : ''
              }`}
            >
              <div className="min-w-0 flex-1">
                <p className={`truncate text-sm ${company.id === activeCompany?.id ? 'font-bold text-primary-700' : 'font-medium text-neutral-900'}`}>
                  {company.name}
                </p>
                <p className="text-xs text-neutral-500">
                  {company.active_employees} active employees &middot; {company.pay_frequency}
                </p>
              </div>
              {company.id === activeCompany?.id && (
                <svg className="ml-2 h-4 w-4 shrink-0 text-primary-600" fill="currentColor" viewBox="0 0 20 20">
                  <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
                </svg>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
