import { useParams } from 'react-router';
import { ContactChangeActivity } from '@/components/employees/ContactChangeActivity';
import { Header } from '@/components/layout/Header';

export function EmployeeContactChangesToConfirm() {
  const companyId = Number(useParams().companyId);
  return (
    <div>
      <Header title="Changes to confirm" description="Review employee contact and address changes, then mark them confirmed on payroll." />
      <div className="mx-auto max-w-4xl p-4 sm:p-6 lg:p-8">
        {companyId > 0 && <ContactChangeActivity key={companyId} staffCompanyId={companyId} />}
      </div>
    </div>
  );
}
