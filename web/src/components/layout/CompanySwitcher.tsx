import { useState, useRef, useEffect } from 'react';
import { useCompany } from '@/contexts/CompanyContext';

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
    // Single-company user — just show company name
    return (
      <div className="px-4 py-3 border-b border-gray-200">
        <p className="text-xs font-medium text-gray-400 uppercase tracking-wider">Company</p>
        <p className="text-sm font-semibold text-gray-900 truncate mt-0.5">
          {activeCompany?.name || 'Loading...'}
        </p>
      </div>
    );
  }

  return (
    <div className="px-4 py-3 border-b border-gray-200 relative" ref={dropdownRef}>
      <p className="text-xs font-medium text-gray-400 uppercase tracking-wider">Active Client</p>
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="mt-1 w-full flex items-center justify-between px-3 py-2 bg-gray-50 hover:bg-gray-100 rounded-lg border border-gray-200 transition-colors text-left"
      >
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-gray-900 truncate">
            {activeCompany?.name || 'Select Company'}
          </p>
          <p className="text-xs text-gray-500">
            {activeCompany?.active_employees || 0} employees
          </p>
        </div>
        <svg
          className={`w-4 h-4 text-gray-400 transition-transform ${isOpen ? 'rotate-180' : ''}`}
          fill="none" stroke="currentColor" viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {isOpen && (
        <div className="absolute left-2 right-2 mt-1 bg-white border border-gray-200 rounded-lg shadow-lg z-50 max-h-64 overflow-y-auto">
          {companies.map(company => (
            <button
              key={company.id}
              onClick={() => {
                switchCompany(company.id);
                setIsOpen(false);
              }}
              className={`w-full flex items-center justify-between px-4 py-3 text-left hover:bg-blue-50 transition-colors border-b last:border-0 ${
                company.id === activeCompany?.id ? 'bg-blue-50 border-l-2 border-l-blue-600' : ''
              }`}
            >
              <div className="flex-1 min-w-0">
                <p className={`text-sm truncate ${company.id === activeCompany?.id ? 'font-bold text-blue-700' : 'font-medium text-gray-900'}`}>
                  {company.name}
                </p>
                <p className="text-xs text-gray-500">
                  {company.active_employees} active employees &middot; {company.pay_frequency}
                </p>
              </div>
              {company.id === activeCompany?.id && (
                <svg className="w-4 h-4 text-blue-600 shrink-0 ml-2" fill="currentColor" viewBox="0 0 20 20">
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
