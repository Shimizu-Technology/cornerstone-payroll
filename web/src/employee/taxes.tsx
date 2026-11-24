import { useCallback, type ReactElement } from 'react';
import { Download, FileText, Mail, MapPin, TriangleAlert } from 'lucide-react';
import { Link } from 'react-router';
import { askManager } from './brand';
import type { TaxForm } from './contracts';
import { useBrand, useReadySession } from './contexts';
import { useDownload } from './download';
import { focusHeadingOnNextScreen } from './focus';
import { Card, Chip, EmpButton, LoadProblem, Page, Placeholder, SkeletonRows } from './ui';
import { useEmployeeData } from './useEmployeeData';

/**
 * How the paper copy reaches the employee, in plain words (§8a). Former
 * employees always get theirs by mail, at the last address on file.
 */
function PaperCopyLine(): ReactElement {
  const { state, isFormer } = useReadySession();
  const brand = useBrand();
  const delivery = isFormer ? 'mailed_last' : state.info.w2Delivery;
  if (delivery === 'mailed_last') {
    return (
      <p className="emp-inline-icon"><Mail aria-hidden="true" className="size-5 shrink-0" />Your paper copy is mailed to your last address on file.</p>
    );
  }
  if (delivery === 'mailed') {
    return (
      <p className="emp-inline-icon">
        <Mail aria-hidden="true" className="size-5 shrink-0" />
        <span>Your paper copy is mailed to your home address. <Link to="/my-info" className="emp-link-inline" onClick={focusHeadingOnNextScreen}>Check your address</Link></span>
      </p>
    );
  }
  if (delivery === 'handed_out') {
    return <p className="emp-inline-icon"><MapPin aria-hidden="true" className="size-5 shrink-0" />Your paper copy is handed out at work.</p>;
  }
  return <p className="text-neutral-700">You'll also get a paper copy. {askManager(brand, 'To find out how, ask your manager')}</p>;
}

function W2Card({ form }: { form: TaxForm }): ReactElement {
  const { api, state: session } = useReadySession();
  const linkId = session.link.id;
  const fetchPdf = useCallback(() => api.taxFormPdf(linkId, form.id), [api, linkId, form.id]);
  const { state, start } = useDownload(fetchPdf, `w-2gu-${form.taxYear}.pdf`);
  const withdrawn = form.status === 'withdrawn';
  return (
    <Card title={`${form.taxYear} W-2GU`} action={form.corrected && !withdrawn ? <Chip tone="warn">Corrected</Chip> : undefined}>
      <div className="space-y-4">
        {withdrawn ? (
          <div className="emp-notice-inline emp-notice-warn" role="note">
            <p className="emp-inline-icon font-bold"><TriangleAlert aria-hidden="true" className="size-5 shrink-0" />A corrected form is being prepared</p>
            <p className="text-neutral-700">We'll post it here when it's ready. Use the corrected form, not the earlier one, when you file.</p>
          </div>
        ) : (
          <>
            <p className="text-neutral-700">Your Wage and Tax Statement for {form.taxYear}. You need it to file your Guam tax return.</p>
            <EmpButton block variant="secondary" className="emp-narrow-button" onClick={start} disabled={state === 'working'} aria-busy={state === 'working'}>
              <Download aria-hidden="true" className="size-6" />
              {state === 'working' ? 'Downloading…' : 'Download W-2GU (PDF)'}
            </EmpButton>
            {state === 'failed' && <p className="emp-field-error" role="alert">Couldn't download the form. Try again.</p>}
            {state === 'offline' && <p className="emp-field-error" role="alert">You're offline. Connect to download the form.</p>}
          </>
        )}
        <PaperCopyLine />
      </div>
    </Card>
  );
}

function TaxFormsList(): ReactElement {
  const { state, reload } = useEmployeeData<TaxForm[]>('tax-forms', (api, linkId, signal) => api.taxForms(linkId, signal));
  if (state.status === 'loading') return <Card><SkeletonRows rows={2} label="Loading your tax forms" /></Card>;
  if (state.status === 'error') return <Card><LoadProblem kind={state.kind} onRetry={reload} what="your tax forms" /></Card>;
  const forms = [...state.data].sort((a, b) => b.taxYear - a.taxYear);
  if (forms.length === 0) {
    return (
      <Card title="W-2GU">
        <div className="space-y-4">
          <Placeholder icon={FileText} title="Your W-2GU will be posted here when it's ready">
            <p>It's a copy of the form you need to file your Guam tax return.</p>
          </Placeholder>
          <PaperCopyLine />
        </div>
      </Card>
    );
  }
  return <>{forms.map((form) => <W2Card key={form.id} form={form} />)}</>;
}

export function TaxesTab(): ReactElement {
  const { state } = useReadySession();
  return (
    <Page title="Tax forms">
      <div className="emp-cards-grid">
        {state.info.features.taxForms ? <TaxFormsList /> : (
          <Card>
            <Placeholder icon={FileText} title="Your tax forms will show here">
              <p>Your W-2GU will be here when it's ready. You'll still get a paper copy, the same way as other years.</p>
            </Placeholder>
          </Card>
        )}
      </div>
    </Page>
  );
}
