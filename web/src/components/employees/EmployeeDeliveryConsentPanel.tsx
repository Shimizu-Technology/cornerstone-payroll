import type { ReactElement } from 'react';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { formatGuamDateTime } from '@/lib/utils';
import type { EmployeeDeliveryAnswer, EmployeeDeliveryAnswerCounts, EmployeeDeliveryConsentItem, EmployeeDeliveryConsentsSummary } from '@/types';

const KIND_LABELS: Record<EmployeeDeliveryConsentItem['kind'], string> = {
  pay_statements: 'Pay statements',
  w2gu: 'Form W-2GU',
};

function answerOf(item: EmployeeDeliveryConsentItem): EmployeeDeliveryAnswer {
  if (item.answer) return item.answer;
  if (item.status === 'consented') return 'paperless';
  return item.status === 'withdrawn' ? 'keep_paper' : 'not_answered';
}

function answerBadge(answer: EmployeeDeliveryAnswer): ReactElement {
  if (answer === 'paperless') return <Badge variant="success">Paperless consent given</Badge>;
  if (answer === 'keep_paper') return <Badge variant="warning">Keep paper</Badge>;
  return <Badge variant="outline">Not answered</Badge>;
}

function countsLine(counts: EmployeeDeliveryAnswerCounts): string {
  const people = counts.total === 1 ? 'active employee' : 'active employees';
  return `Company: ${counts.paperless} paperless · ${counts.keep_paper} keep paper · ${counts.not_answered} not answered (${counts.total} ${people})`;
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
        {summary.items.map((item) => {
          const answer = answerOf(item);
          const counts = summary.company_counts?.[item.kind];
          return (
            <div
              key={item.kind}
              className="flex flex-wrap items-start justify-between gap-3 rounded-xl border border-neutral-200 px-4 py-3"
            >
              <div className="min-w-0 space-y-1">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-semibold text-neutral-900">{KIND_LABELS[item.kind]}</p>
                  {answerBadge(answer)}
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
                {item.status === 'not_consented' && answer === 'keep_paper' && (
                  <p className="text-xs text-neutral-600">
                    Chose to keep paper{item.paper_chosen_at ? ` ${formatGuamDateTime(item.paper_chosen_at)}` : ''} · Paper delivery required
                  </p>
                )}
                {answer === 'not_answered' && (
                  <p className="text-xs text-neutral-500">Hasn't answered yet. Paper delivery required.</p>
                )}
                {item.disclosure_status === 'draft' && (
                  <p className="text-xs text-neutral-500">The consent wording is still a draft waiting for counsel to approve it.</p>
                )}
                {counts && <p className="text-xs text-neutral-500">{countsLine(counts)}</p>}
              </div>
            </div>
          );
        })}
      </CardContent>
    </Card>
  );
}
