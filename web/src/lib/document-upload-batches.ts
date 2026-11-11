// Both document endpoints enforce 10 files / 50 MiB per atomic request.
const MAX_FILES = 10;
const MAX_BYTES = 50 * 1024 * 1024;
const MAX_FILE_BYTES = 25 * 1024 * 1024;

export async function uploadDocumentBatches(
  files: File[],
  fields: Record<string, string>,
  upload: (payload: FormData) => Promise<unknown>,
  onProgress: (completed: number, total: number) => void,
) {
  const uploaded: File[] = [];
  const failures: { file: File; message: string }[] = [];
  const batches: File[][] = [];
  let batch: File[] = [];
  let bytes = 0;
  for (const file of files) {
    if (file.size > MAX_FILE_BYTES || file.size === 0) {
      failures.push({ file, message: file.size === 0 ? 'This file is empty.' : 'Choose a file 25 MB or smaller.' });
      continue;
    }
    if (batch.length === MAX_FILES || bytes + file.size > MAX_BYTES) {
      batches.push(batch);
      batch = [];
      bytes = 0;
    }
    batch.push(file);
    bytes += file.size;
  }
  if (batch.length) batches.push(batch);
  const progress = () => onProgress(uploaded.length + failures.length, files.length);
  const send = async (group: File[]) => {
    const payload = new FormData();
    group.forEach((file) => payload.append('files[]', file));
    Object.entries(fields).forEach(([key, value]) => payload.append(key, value));
    await upload(payload);
    uploaded.push(...group);
  };
  progress();
  for (const group of batches) {
    try {
      await send(group);
    } catch (error) {
      // A 422 rolls back the whole batch. Isolate its invalid files so valid
      // neighbours can still upload. Never automatically retry uncertain writes.
      if (group.length > 1 && error instanceof Error && 'status' in error && error.status === 422) {
        for (const file of group) {
          try { await send([file]); }
          catch (failure) { failures.push({ file, message: failure instanceof Error ? failure.message : 'Upload failed. Please try again.' }); }
          progress();
        }
      } else {
        const message = error instanceof Error ? error.message : 'Upload failed. Please try again.';
        group.forEach((file) => failures.push({ file, message }));
      }
    }
    progress();
  }
  return { uploaded, failures };
}
