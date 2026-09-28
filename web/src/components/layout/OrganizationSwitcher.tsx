import { useNavigate } from 'react-router';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';

export function OrganizationSwitcher({ onNavigate }: { onNavigate?: () => void }) {
  const { user } = useAuth();
  const { organizations, activeOrganizationId, activeOrganizationName, switchOrganization } = useCompany();
  const navigate = useNavigate();

  if (user?.role !== 'super_admin' || organizations.length <= 1) {
    return (
      <div className="border-b border-neutral-200/70 px-4 py-3">
        <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-400">Organization</p>
        <p className="mt-1 truncate text-sm font-semibold text-neutral-900">{activeOrganizationName || 'Loading...'}</p>
      </div>
    );
  }

  return (
    <div className="border-b border-neutral-200/70 px-4 py-3">
      <label htmlFor="active-organization" className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-500">
        Organization
      </label>
      <select
        id="active-organization"
        className="mt-1.5 min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-semibold text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500"
        value={activeOrganizationId ?? ''}
        onChange={(event) => {
          switchOrganization(Number(event.target.value));
          onNavigate?.();
          navigate('/app', { state: { companySwitchNotice: 'Switched organizations. Select a client or open Finance to continue.' } });
        }}
      >
        {organizations.map((organization) => (
          <option key={organization.id} value={organization.id}>{organization.name}</option>
        ))}
      </select>
    </div>
  );
}
