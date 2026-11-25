import type { ReactElement } from 'react';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { formatGuamDateTime } from '@/lib/utils';
import type { EmployeeDeliveryConsentItem, EmployeeDeliveryConsentsSummary } from '@/types';

const KIND_LABELS: Record<EmployeeDeliveryConsentItem['kind'], string> = {
  pay_statements: 'Pay statements',
  w2gu: 'Form W-2GU',
};

function statusBadge(status: EmployeeDeliveryConsentItem['status']): ReactElement {
  if (status === 'consented') return <Badge variant="success">Consented</Badge>;
  if (status === 'withdrawn') return <Badge variant="warning">Withdrawn (paper)</Badge>;
  return <Badge variant="outline">Not consented</Badge>;
}

export function EmployeeDeliveryConsentPanel({
  summary,
}: {
  summary?: EmployeeDeliveryConsentsSummary | null;
}): ReactElement | null {
  if (!summary) return null;

  return (
    <Card>
      <CardHeader className="flex-row flex-wrap items-center justify-between gap-2">
        <div>
          <CardTitle>Electronic delivery consent</CardTitle>
          <p className="mt-1 text-sm text-neutral-500">
            {summary.paper_delivery_continues
              ? 'Paper copies continue during the pilot regardless of consent status.'
              : 'Electronic-only readiness checks pass for consented items.'}
          </p>
          {!summary.feature_enabled && (
            <p className="mt-1 text-sm text-neutral-500">
              Employees don't see these consent screens yet: electronic delivery is switched off for this client.
            </p>
          )}
        </div>
        {!summary.feature_enabled && (
          <Badge variant="outline">Employee screens hidden</Badge>
        )}
      </CardHeader>
      <CardContent className="space-y-3">
        {summary.items.map((item) => (
          <div
            key={item.kind}
            className="flex flex-wrap items-start justify-between gap-3 rounded-xl border border-neutral-200 px-4 py-3"
          >
            <div className="min-w-0 space-y-1">
              <div className="flex flex-wrap items-center gap-2">
                <p className="font-semibold text-neutral-900">{KIND_LABELS[item.kind]}</p>
                {statusBadge(item.status)}
                {item.disclosure_status === 'draft' && (
                  <Badge variant="warning">Draft wording</Badge>
                )}
              </div>
              {item.status === 'consented' && item.given_at && (
                <p className="text-xs text-neutral-600">
                  Consented {formatGuamDateTime(item.given_at)}
                  {item.disclosure_version ? ` · ${item.disclosure_version}` : ''}
                </p>
              )}
              {item.status === 'withdrawn' && item.withdrawn_at && (
                <p className="text-xs text-neutral-600">
                  Withdrawn {formatGuamDateTime(item.withdrawn_at)} · Paper delivery required
                </p>
              )}
              {item.status === 'not_consented' && (
                <p className="text-xs text-neutral-500">No electronic consent recorded.</p>
              )}
              {item.disclosure_status === 'draft' && (
                <p className="text-xs text-neutral-500">The consent wording is still a draft waiting for counsel to approve it.</p>
              )}
            </div>
          </div>
        ))}
      </CardContent>
    </Card>
  );
}
