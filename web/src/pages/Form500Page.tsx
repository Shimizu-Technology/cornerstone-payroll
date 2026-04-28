import { useEffect } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { Form500EditorModal } from '@/components/form500/Form500EditorModal';

export function Form500Page() {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const payPeriodId = Number(id);

  useEffect(() => {
    if (!Number.isFinite(payPeriodId)) {
      navigate('/pay-periods', { replace: true });
    }
  }, [navigate, payPeriodId]);

  if (!Number.isFinite(payPeriodId)) return null;

  return <Form500EditorModal open onClose={() => navigate(`/pay-periods/${payPeriodId}`)} payPeriodId={payPeriodId} />;
}
