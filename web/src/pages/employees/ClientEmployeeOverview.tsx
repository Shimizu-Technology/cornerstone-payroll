import { useEffect, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router';
import { ArrowLeft, Pencil } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { useCompany } from '@/contexts/CompanyContext';
import { employeePaymentDelivery } from '@/lib/employee-payment-delivery';
import { employeeStatusConfig, employmentTypeLabels, formatCurrency, payFrequencyLabels } from '@/lib/utils';
import { employeeEditPath, employeesPath, safeInternalReturnPath } from '@/lib/routes';
import { parsePositiveRouteId } from '@/lib/route-params';
import { clientEmployeesApi } from '@/services/api';
import type { Employee } from '@/types';

export function ClientEmployeeOverview() {
  const { companyId: companyIdParam, id: idParam } = useParams<{ companyId: string; id: string }>();
  const [searchParams] = useSearchParams();
  const { activeCompanyId } = useCompany();
  const companyId = parsePositiveRouteId(companyIdParam);
  const employeeId = parsePositiveRouteId(idParam);
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!companyId || !employeeId || activeCompanyId !== companyId) return;
    let current = true;
    setLoading(true);
    setEmployee(null);
    setError(null);
    void clientEmployeesApi.get(employeeId).then(
      ({ data }) => { if (current) setEmployee(data); },
      (caught) => { if (current) setError(caught instanceof Error ? caught.message : 'Could not load this employee.'); },
    ).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [activeCompanyId, companyId, employeeId]);

  if (!companyId || !employeeId) return <p role="alert" className="p-6">This employee link is invalid.</p>;
  if (activeCompanyId !== companyId || loading) return <WorkspaceLoader label="Loading employee" />;
  if (error || !employee) return <p role="alert" className="p-6 text-danger-700">{error || 'Employee not found.'}</p>;

  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), employeesPath(companyId));
  const delivery = employeePaymentDelivery(employee);
  const payRate = employee.employment_type === 'salary' && employee.salary_type === 'variable'
    ? 'Set each pay period'
    : `${formatCurrency(Number(employee.pay_rate) || 0)}${employee.employment_type === 'hourly' || (employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly') ? ' / hour' : employee.salary_type === 'per_period' || employee.employment_type === 'contractor' ? ' / period' : ' / year'}`;

  return (
    <div>
      <Header
        title={`${employee.first_name} ${employee.last_name}`}
        description={[employmentTypeLabels[employee.employment_type] || employee.employment_type, employee.department?.name || 'No department'].join(' · ')}
        actions={<div className="flex flex-wrap gap-2">
          <Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700" to={returnTo}><ArrowLeft className="h-4 w-4" />Back</Link>
          <Link className="inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white" to={employeeEditPath(companyId, employeeId, { returnTo })}><Pencil className="h-4 w-4" />Edit employee</Link>
        </div>}
      />
      <main className="mx-auto max-w-5xl space-y-6 p-4 sm:p-6 lg:p-8">
        <div className="flex flex-wrap gap-2">
          <Badge variant={employee.status === 'active' ? 'success' : employee.status === 'terminated' ? 'danger' : 'default'}>{employeeStatusConfig[employee.status]?.label || employee.status}</Badge>
          <Badge variant={employee.payment_delivery_method ? 'info' : 'warning'}>{delivery.label}</Badge>
        </div>
        <Card>
          <CardHeader><CardTitle>How this employee is paid</CardTitle></CardHeader>
          <CardContent>
            <p className="text-lg font-semibold text-neutral-950">{delivery.label}</p>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-neutral-600">{delivery.detail} Each pay run can use a different method.</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle>Employee details</CardTitle></CardHeader>
          <CardContent className="grid gap-5 sm:grid-cols-2">
            <Detail label="Worker type" value={employmentTypeLabels[employee.employment_type] || employee.employment_type} />
            <Detail label="Job title" value={employee.job_title || 'Not recorded'} />
            <Detail label="Department" value={employee.department?.name || 'Not assigned'} />
            <Detail label="Pay frequency" value={payFrequencyLabels[employee.pay_frequency] || employee.pay_frequency} />
            <Detail label="Pay rate" value={payRate} />
          </CardContent>
        </Card>
      </main>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return <div><p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{label}</p><p className="mt-1 text-sm font-medium text-neutral-950">{value}</p></div>;
}
