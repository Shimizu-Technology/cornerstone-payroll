import { expect, it, vi } from 'vitest';
import { uploadDocumentBatches } from './document-upload-batches';

const image = (name: string, size = 10) => {
  const file = new File(['image'], name, { type: 'image/jpeg' });
  Object.defineProperty(file, 'size', { value: size });
  return file;
};
it('respects both aggregate bytes and file count and retains upload metadata', async () => {
  const upload = vi.fn().mockResolvedValue({});
  const files = Array.from({ length: 30 }, (_, i) => image(`${i}.jpg`, 20 * 1024 * 1024));
  const result = await uploadDocumentBatches(files, { category: 'payroll_source', employee_id: '7' }, upload, vi.fn());
  expect(result.uploaded).toEqual(files);
  expect(upload).toHaveBeenCalledTimes(15);
  for (const [payload] of upload.mock.calls) {
    expect(payload.getAll('files[]')).toHaveLength(2);
    expect(payload.get('employee_id')).toBe('7');
  }
});
it('isolates a rejected batch, reports per-file errors, and keeps successes out of retry selection', async () => {
  const files = [image('good.jpg'), image('bad.jpg'), image('also-good.jpg')];
  const upload = vi.fn(async (payload: FormData) => {
    const group = payload.getAll('files[]') as File[];
    if (group.some((file) => file.name === 'bad.jpg')) throw Object.assign(new Error('File does not match its extension.'), { status: 422 });
  });
  const progress = vi.fn();
  const result = await uploadDocumentBatches(files, { category: 'misc' }, upload, progress);
  expect(result.uploaded).toEqual([files[0], files[2]]);
  expect(result.failures).toEqual([{ file: files[1], message: 'File does not match its extension.' }]);
  expect(upload).toHaveBeenCalledTimes(4);
  expect(progress).toHaveBeenLastCalledWith(3, 3);
});
it('does not automatically repeat a request with an uncertain network outcome', async () => {
  const upload = vi.fn().mockRejectedValue(new Error('Network unavailable'));
  const result = await uploadDocumentBatches([image('a.jpg'), image('b.jpg')], {}, upload, vi.fn());
  expect(upload).toHaveBeenCalledTimes(1);
  expect(result.failures.map((failure) => failure.file.name)).toEqual(['a.jpg', 'b.jpg']);
});
it('rejects empty and oversized files individually and still uploads valid neighbours', async () => {
  const upload = vi.fn().mockResolvedValue({});
  const result = await uploadDocumentBatches([image('empty.jpg', 0), image('huge.jpg', 26 * 1024 * 1024), image('good.jpg')], {}, upload, vi.fn());
  expect(result.uploaded.map((file) => file.name)).toEqual(['good.jpg']);
  expect(result.failures.map((failure) => failure.file.name)).toEqual(['empty.jpg', 'huge.jpg']);
});

it('keeps 30 large rejected photos within 45 requests, below the 60/minute allowance', async () => {
  const upload = vi.fn().mockRejectedValue(Object.assign(new Error('Invalid image'), { status: 422 }));
  const files = Array.from({ length: 30 }, (_, i) => image(`${i}.jpg`, 25 * 1024 * 1024));
  const result = await uploadDocumentBatches(files, {}, upload, vi.fn());
  expect(upload).toHaveBeenCalledTimes(45);
  expect(result.failures).toHaveLength(30);
});
