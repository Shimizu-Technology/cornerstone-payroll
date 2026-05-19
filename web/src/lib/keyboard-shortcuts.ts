export function platformShortcut(key: string) {
  const normalizedKey = key.trim().toUpperCase();
  if (typeof navigator !== 'undefined' && /Mac|iPhone|iPad|iPod/.test(navigator.platform)) {
    return `⌘${normalizedKey}`;
  }
  return `Ctrl ${normalizedKey}`;
}
