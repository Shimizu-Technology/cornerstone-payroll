import { useCallback, useState } from 'react';
import { useReadySession } from './contexts';
import { isSessionError } from './useEmployeeData';

/**
 * Hands a PDF held in memory to the browser as a download. The PDF came from
 * the API with no-store, so it isn't kept in the HTTP cache, and the object URL
 * is released once the browser has it.
 */
export function savePdf(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob.type === 'application/pdf' ? blob : new Blob([blob], { type: 'application/pdf' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.rel = 'noopener';
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

export type DownloadState = 'idle' | 'working' | 'failed' | 'offline';

/**
 * One download button's state: "Downloading…", then done, or a short message
 * with Try again. A 401 or 404 goes to the session instead.
 */
export function useDownload(fetchPdf: () => Promise<Blob>, filename: string): { state: DownloadState; start: () => void } {
  const { reportError } = useReadySession();
  const [state, setState] = useState<DownloadState>('idle');
  const start = useCallback(() => {
    setState('working');
    fetchPdf().then((blob) => {
      savePdf(blob, filename);
      setState('idle');
    }, (error: unknown) => {
      // Signed out or access ended: the session's own screen, as for any other load.
      if (isSessionError(error)) {
        setState('idle');
        reportError(error);
      } else {
        setState((error as { kind?: string } | null)?.kind === 'offline' ? 'offline' : 'failed');
      }
    });
  }, [fetchPdf, filename, reportError]);
  return { state, start };
}
