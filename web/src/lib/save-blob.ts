/**
 * Saves a downloaded file through a temporary link. The object URL stays
 * alive for a minute: mobile Safari reads it after the click returns, and
 * revoking it at once can leave an empty download.
 */
export function saveBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.rel = 'noopener';
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
