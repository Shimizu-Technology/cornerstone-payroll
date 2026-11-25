// @vitest-environment jsdom
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,expect,it,vi} from 'vitest';
import {EmployeeBulkImportModal} from './EmployeeBulkImportModal';
import {employeeBulkImportApi} from '@/services/api';

vi.mock('@/contexts/CompanyContext',()=>({useCompany:()=>({activeCompanyId:1})}));
vi.mock('@/hooks/useEmployeeIntakeSettings',()=>({useEmployeeIntakeSettings:()=>({settings:{enabled:false},loading:false})}));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return {
    ...actual,
    employeeBulkImportApi: {
      ...actual.employeeBulkImportApi,
      preview: vi.fn(),
      cancelPreview: vi.fn().mockResolvedValue(undefined),
      applyJson: vi.fn(),
      downloadTemplate: vi.fn(),
    },
  };
});

afterEach(():void=>{cleanup();vi.clearAllMocks();});

it('announces the bulk employee import close action',async():Promise<void>=>{
 const close=vi.fn();render(<EmployeeBulkImportModal open onClose={close} onComplete={vi.fn()}/>);
 await userEvent.setup().click(screen.getByRole('button',{name:'Close employee bulk import'}));expect(close).toHaveBeenCalledTimes(1);
});

it('cancels the previous server preview when clicking Back and re-uploading another file', async (): Promise<void> => {
  const user = userEvent.setup();
  const previewMock = vi.mocked(employeeBulkImportApi.preview);
  const cancelMock = vi.mocked(employeeBulkImportApi.cancelPreview);
  previewMock
    .mockResolvedValueOnce({
      preview_id: 'preview-first-1111',
      rows: [],
      summary: { total: 0, valid: 0, invalid: 0, duplicates: 0, new_departments: [] },
    })
    .mockResolvedValueOnce({
      preview_id: 'preview-second-2222',
      rows: [],
      summary: { total: 0, valid: 0, invalid: 0, duplicates: 0, new_departments: [] },
    });

  const { container } = render(<EmployeeBulkImportModal open onClose={vi.fn()} onComplete={vi.fn()} />);
  const input = container.querySelector('input[type="file"]') as HTMLInputElement;
  await user.upload(input, new File(['first_name,last_name\nA,B'], 'first.csv', { type: 'text/csv' }));
  await user.click(screen.getByRole('button', { name: 'Upload & Preview' }));

  await waitFor(() => expect(screen.getByRole('button', { name: 'Back' })).toBeTruthy());
  await user.click(screen.getByRole('button', { name: 'Back' }));

  expect(cancelMock).toHaveBeenCalledWith('preview-first-1111');

  const input2 = container.querySelector('input[type="file"]') as HTMLInputElement;
  await user.upload(input2, new File(['first_name,last_name\nC,D'], 'second.csv', { type: 'text/csv' }));
  await user.click(screen.getByRole('button', { name: 'Upload & Preview' }));

  await waitFor(() => expect(screen.getByRole('button', { name: 'Back' })).toBeTruthy());
  await user.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(cancelMock).toHaveBeenCalledWith('preview-second-2222');
});
