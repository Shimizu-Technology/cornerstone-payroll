import { useCallback, useState } from 'react';
import { PdfDocumentView } from '@/components/documents/PdfPreview';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { formatCurrency, formatDate } from '@/lib/utils';
import { ApiError, quickbooksStubUploadsApi, type QuickbooksStubPreviewPage, type QuickbooksCheckWarning } from '@/services/api';

const PAGE_MESSAGES = {
  full_ssn: 'Re-export without the full SSN.',
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
  const [opened, setOpened] = useState<Set<string>>(new Set());
  const [attested, setAttested] = useState<Set<string>>(new Set());
  const [pagePreview, setPagePreview] = useState<{ page: number; token: string; blob: Blob } | null>(null);
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
        setOpened(new Set());
        setAttested(new Set());
        const { data } = await quickbooksStubUploadsApi.preview(companyId, file);
        setPages(data);
      } else {
        const reviewed = pages.filter(selectable).filter((page) => selected.has(page.review_token));
        const tokens = reviewed.filter((page) => page.status === 'matched').map((page) => page.review_token);
        const imageTokens = reviewed.filter((page) => page.status === 'image_review').map((page) => page.review_token);
        const numberTokens = reviewed.filter((page) => page.status === 'possible_ssn').map((page) => page.review_token);
        const { data } = await quickbooksStubUploadsApi.confirm(companyId, file, tokens, imageTokens, numberTokens);
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

  async function viewPage(page: number, token: string) {
    if (!file) return;

    setBusy(true);
    setError('');
    try {
      const { blob } = await quickbooksStubUploadsApi.viewPage(companyId, file, token);
      setPagePreview({ page, token, blob });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not open this page. Try again.');
    } finally {
      setBusy(false);
    }
  }

  const markPageOpened = useCallback(() => {
    if (pagePreview) setOpened((previous) => new Set([...previous, pagePreview.token]));
  }, [pagePreview]);

  function attest(token: string, checked: boolean) {
    setAttested((previous) => {
      const next = new Set(previous);
      if (checked) next.add(token);
      else next.delete(token);
      return next;
    });
    if (!checked) selectPage(token, false);
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
                  {warning.employee_name} has {warning.row_count} checks on {warning.payday_count} {warning.payday_count === 1 ? 'payday' : 'paydays'}.
                  {' Some paydays have more than one check.'}
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
                setOpened(new Set());
                setAttested(new Set());
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
                  <div className="space-y-2">
                    <label className="flex items-start gap-3">
                      <input
                        aria-label={`Select page ${page.page}`}
                        className="mt-1"
                        type="checkbox"
                        disabled={page.status !== 'matched' && !attested.has(page.review_token)}
                        checked={selected.has(page.review_token)}
                        onChange={(event) => selectPage(page.review_token, event.target.checked)}
                      />
                      <span className="min-w-0 break-words">
                        Page {page.page} · {page.employee_name} · {formatDate(page.pay_date)} · {formatCurrency(Number(page.net_pay))}
                        {page.check_number && <> · Check #{page.check_number}</>}
                      </span>
                    </label>
                    {page.status !== 'matched' && (
                      <div className="space-y-2 pl-6">
                        {(page.status === 'image_review' || page.has_image) && <p>Has an image. Check this page by eye before posting.</p>}
                        {page.status === 'possible_ssn' && <p>A 9-digit number on this page might be an SSN or a bank number. Check it before posting.</p>}
                        <Button type="button" size="sm" variant="outline" aria-label={`View page ${page.page}`} onClick={() => void viewPage(page.page, page.review_token)}>
                          View page
                        </Button>
                        <label className="flex items-center gap-2">
                          <input
                            type="checkbox"
                            disabled={!opened.has(page.review_token)}
                            checked={attested.has(page.review_token)}
                            onChange={(event) => attest(page.review_token, event.target.checked)}
                          />
                          I checked this page
                        </label>
                      </div>
                    )}
                  </div>
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
      <Dialog open={pagePreview !== null} onOpenChange={(open) => { if (!open) setPagePreview(null); }}>
        <DialogContent className="flex h-[85dvh] w-[95vw] max-w-4xl flex-col">
          <DialogHeader>
            <DialogTitle>QuickBooks page {pagePreview?.page}</DialogTitle>
            <DialogDescription>Check the page for a full SSN before posting.</DialogDescription>
          </DialogHeader>
          <PdfDocumentView blob={pagePreview?.blob ?? null} onPageRendered={markPageOpened} />
          <Button type="button" variant="outline" onClick={() => setPagePreview(null)}>Back to matches</Button>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
