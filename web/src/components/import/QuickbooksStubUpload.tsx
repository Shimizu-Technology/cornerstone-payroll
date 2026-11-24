import { useState } from 'react';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { formatCurrency, formatDate } from '@/lib/utils';
import { ApiError, quickbooksStubUploadsApi, type QuickbooksStubPreviewPage, type QuickbooksCheckWarning } from '@/services/api';

const PAGE_MESSAGES = {
  full_ssn: 'Re-export without the full SSN.',
  possible_ssn: 'A 9-digit number on this page might be an SSN or a bank number. Check it before posting.',
  unreadable: 'Use the QuickBooks PDF, not a scan.',
  ambiguous: 'More than one check matched. Compare the checks in QuickBooks.',
  duplicate_page: 'Another page matches this check. Upload only the correct page.',
  unmatched: 'No check with this name, pay date and net pay. Check the QuickBooks export.',
  already_posted: 'Already posted. Skip this page.',
  conflicting_original: 'A different original is already posted. Compare the two versions.',
};

function selectable(page: QuickbooksStubPreviewPage): page is Extract<QuickbooksStubPreviewPage, { review_token: string }> {
  return 'review_token' in page;
}

export function QuickbooksStubUpload({ companyId, warnings, enabled }: { companyId: number; warnings: QuickbooksCheckWarning[]; enabled: boolean }) {
  const [file, setFile] = useState<File | null>(null);
  const [pages, setPages] = useState<QuickbooksStubPreviewPage[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  async function submit(action: 'preview' | 'confirm') {
    if (!file) return;

    setBusy(true);
    setError('');
    setNotice('');
    try {
      if (action === 'preview') {
        setSelected(new Set());
        setPages([]);
        const { data } = await quickbooksStubUploadsApi.preview(companyId, file);
        setPages(data);
      } else {
        const reviewed = pages.filter(selectable).filter((page) => selected.has(page.review_token));
        const tokens = reviewed.filter((page) => page.status === 'matched').map((page) => page.review_token);
        const imageTokens = reviewed.filter((page) => page.status === 'image_review').map((page) => page.review_token);
        const { data } = await quickbooksStubUploadsApi.confirm(companyId, file, tokens, imageTokens);
        setPages(pages.filter((page) => !selectable(page) || !selected.has(page.review_token)));
        setSelected(new Set());
        setNotice(data.length === 1 ? '1 original stub posted.' : `${data.length} original stubs posted.`);
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'The request failed. Try again.');
    } finally {
      setBusy(false);
    }
  }

  function selectPage(token: string, checked: boolean) {
    setSelected((previous) => {
      const next = new Set(previous);
      if (checked) next.add(token);
      else next.delete(token);
      return next;
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Original QuickBooks stubs</CardTitle>
        {enabled && <CardDescription>Choose a PDF with one check per page. Compare each match with the original and select the pages to post.</CardDescription>}
      </CardHeader>
      <CardContent className="space-y-4">
        {warnings.length > 0 && (
          <ActionFeedback tone="warning" message="Compare these checks with the original QuickBooks export before posting.">
            <ul className="mt-2 list-disc space-y-1 pl-5">
              {warnings.map((warning) => (
                <li key={warning.employee_id}>
                  {warning.employee_name} has {warning.row_count} rows and fewer distinct pay dates.
                  {warning.duplicate_groups > 0 && ' Some rows share the same pay date, gross pay and net pay.'}
                </li>
              ))}
            </ul>
          </ActionFeedback>
        )}
        {enabled && <div className="flex flex-wrap items-end gap-3">
          <div className="min-w-0 max-w-full space-y-1">
            <label htmlFor="quickbooks-stub-pdf" className="text-sm font-medium">QuickBooks stub PDF</label>
            <Input
              id="quickbooks-stub-pdf"
              type="file"
              accept=".pdf,application/pdf"
              disabled={busy}
              onChange={(event) => {
                setFile(event.target.files?.[0] ?? null);
                setPages([]);
                setSelected(new Set());
                setError('');
                setNotice('');
              }}
            />
          </div>
          <Button variant="outline" disabled={!file || busy} onClick={() => void submit('preview')}>
            Preview matches
          </Button>
        </div>}
        {enabled && error && <ActionFeedback tone="error" message={error} />}
        {enabled && notice && <ActionFeedback tone="success" message={notice} />}
        {enabled && pages.length > 0 && (
          <fieldset className="space-y-2" disabled={busy}>
            <legend className="mb-2 text-sm font-semibold">Review each page</legend>
            {pages.some((page) => page.status === 'matched') && (
              <Button variant="outline" size="sm" onClick={() => setSelected((previous) =>
                new Set([...previous, ...pages.filter(selectable).filter((page) => page.status === 'matched').map((page) => page.review_token)])
              )}>
                Select all matched
              </Button>
            )}
            {pages.map((page) => (
              <div key={page.page} className="rounded-lg border border-neutral-200 px-3 py-2 text-sm">
                {selectable(page) ? (
                  <label className="flex items-start gap-3">
                    <input
                      className="mt-1"
                      type="checkbox"
                      checked={selected.has(page.review_token)}
                      onChange={(event) => selectPage(page.review_token, event.target.checked)}
                    />
                    <span className="min-w-0 break-words">
                      Page {page.page} · {page.employee_name} · {formatDate(page.pay_date)} · {formatCurrency(Number(page.net_pay))}
                      {page.check_number && <> · Check #{page.check_number}</>}
                      {page.status === 'image_review' && (
                        <span className="mt-1 block">
                          Has an image: check this page by eye before posting. <strong>I checked this page</strong>
                        </span>
                      )}
                    </span>
                  </label>
                ) : (
                  <p>Page {page.page} · {PAGE_MESSAGES[page.status]}</p>
                )}
              </div>
            ))}
            <Button disabled={selected.size === 0 || busy} onClick={() => void submit('confirm')}>
              Post selected stubs{selected.size > 0 && ` (${selected.size})`}
            </Button>
          </fieldset>
        )}
      </CardContent>
    </Card>
  );
}
