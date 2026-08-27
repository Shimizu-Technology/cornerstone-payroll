import { useEffect, type ReactElement } from 'react';
import { useNavigate, useParams } from 'react-router';
import { Form500EditorModal } from '@/components/form500/Form500EditorModal';
import { useCompany } from '@/contexts/CompanyContext';
import { payRunPath, payRunsPath } from '@/lib/routes';

export function Form500Page(): ReactElement | null {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const { activeCompanyId } = useCompany();
  const payPeriodId = Number(id);
  const isValidPayPeriodId = Number.isInteger(payPeriodId) && payPeriodId > 0;
  const payRunListHref = activeCompanyId ? payRunsPath(activeCompanyId) : '/pay-periods';

  useEffect(() => {
    if (!isValidPayPeriodId) {
      navigate(payRunListHref, { replace: true });
    }
  }, [isValidPayPeriodId, navigate, payRunListHref]);

  if (!isValidPayPeriodId) return null;

  const payRunHref = activeCompanyId ? payRunPath(activeCompanyId, payPeriodId, 'work') : `/pay-periods/${payPeriodId}`;
  return <Form500EditorModal open onClose={() => navigate(payRunHref)} payPeriodId={payPeriodId} />;
}
