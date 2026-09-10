import { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { ReportDownloadMenu, type ReportDownloadFormat } from '@/components/reports/ReportDownloadMenu';
import { Card } from '@/components/ui/card';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';

// This test module exports its imperative mount entry point.
// eslint-disable-next-line react-refresh/only-export-components
function Harness({ modal, count }: { modal: boolean; count: number }) {
  const [result, setResult] = useState('No export');
  const [disabled, setDisabled] = useState(false);
  const [busy, setBusy] = useState(false);
  const [dialogOpen, setDialogOpen] = useState(true);
  const formats: ReportDownloadFormat[] = [
    { key: 'pdf', label: 'PDF', kind: 'pdf', description: 'Print-ready report', onSelect: () => setResult('PDF') },
    { key: 'xlsx', label: 'Excel', kind: 'spreadsheet', description: 'Editable workbook', onSelect: () => setResult('Excel') },
    { key: 'csv', label: 'CSV', kind: 'data', description: 'Raw data download', onSelect: () => setResult('CSV') },
  ].slice(0, count) as ReportDownloadFormat[];
  formats[0].loading = busy;
  const content = (
    <>
      <button onClick={() => setDisabled(!disabled)}>Toggle disabled</button>
      <button onClick={() => setBusy(!busy)}>Toggle loading</button>
      <input aria-label="Before export" />
      <div data-testid="scroll-area" style={{ height: 360, overflow: 'auto', position: 'relative' }}>
        <div data-testid="anchor-space" style={{ height: 40 }} />
        <Card data-testid="controls-card" style={{ padding: 16, height: 90, overflow: 'hidden' }}>
          <ReportDownloadMenu formats={formats} disabled={disabled} ariaLabel="Download report" />
          <input aria-label="After export" />
        </Card>
        <Card data-testid="results-card" style={{ height: 400, position: 'relative', zIndex: 10 }}>Report results</Card>
      </div>
      <output data-testid="export-result">{result}</output>
      <input aria-label="Outside menu" />
    </>
  );
  return modal ? (
    <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
      <DialogContent>
        <DialogTitle>Report preview</DialogTitle>
        {content}
      </DialogContent>
    </Dialog>
  ) : <main style={{ width: '100%', padding: 12 }}>{content}</main>;
}

export function mountReportDownloadMenuHarness(modal = false, count = 3): void {
  const container = document.createElement('div');
  Object.assign(container.style, { position: 'fixed', inset: '0', zIndex: '200', overflow: 'auto', background: 'white' });
  document.body.appendChild(container);
  createRoot(container).render(<Harness modal={modal} count={count} />);
}
