import { useState } from 'react';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { formatCurrency } from '@/lib/utils';
import { ApiError, quickbooksStubUploadsApi, type QuickbooksStubPreviewPage } from '@/services/api';

const PAGE_MESSAGES = {
  full_ssn: 'Blocked because the page may show a full SSN.',
  unreadable: 'The page could not be safely read.',
  ambiguous: 'More than one match. Check the source records.',
  duplicate_page: 'Another page in this PDF matched the same check.',
  unmatched: 'No matching QuickBooks check.',
};

export function QuickbooksStubUpload({ companyId }: { companyId: number }) {
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
        const { data } = await quickbooksStubUploadsApi.confirm(companyId, file, [...selected]);
        setPages(pages.filter((page) => page.status !== 'matched' || !selected.has(page.review_token)));
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
        <CardDescription>Choose a PDF with one check per page. Compare each match with the original and select the pages to post.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-wrap items-end gap-3">
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
        </div>
        {error && <ActionFeedback tone="error" message={error} />}
        {notice && <ActionFeedback tone="success" message={notice} />}
        {pages.length > 0 && (
          <fieldset className="space-y-2" disabled={busy}>
            <legend className="mb-2 text-sm font-semibold">Review each page</legend>
            {pages.map((page) => (
              <div key={page.page} className="rounded-lg border border-neutral-200 px-3 py-2 text-sm">
                {page.status === 'matched' ? (
                  <label className="flex items-start gap-3">
                    <input
                      className="mt-1"
                      type="checkbox"
                      checked={selected.has(page.review_token)}
                      onChange={(event) => selectPage(page.review_token, event.target.checked)}
                    />
                    <span className="min-w-0 break-words">
                      Page {page.page} · {page.employee_name} · {page.pay_date} · {formatCurrency(Number(page.net_pay))}
                      {page.check_number && <> · Check #{page.check_number}</>}
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
