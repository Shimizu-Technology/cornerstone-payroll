import { useEffect } from 'react';
import { useNavigate, useParams } from 'react-router';
import { Form500EditorModal } from '@/components/form500/Form500EditorModal';
import { useCompany } from '@/contexts/CompanyContext';
import { payRunPath, payRunsPath } from '@/lib/routes';

export function Form500Page() {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const { activeCompanyId } = useCompany();
  const payPeriodId = Number(id);
  const payRunListHref = activeCompanyId ? payRunsPath(activeCompanyId) : '/pay-periods';

  useEffect(() => {
    if (!Number.isFinite(payPeriodId)) {
      navigate(payRunListHref, { replace: true });
    }
  }, [navigate, payPeriodId, payRunListHref]);

  if (!Number.isFinite(payPeriodId)) return null;

  const payRunHref = activeCompanyId ? payRunPath(activeCompanyId, payPeriodId, 'work') : `/pay-periods/${payPeriodId}`;
  return <Form500EditorModal open onClose={() => navigate(payRunHref)} payPeriodId={payPeriodId} />;
}
