// @vitest-environment jsdom
import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ReportsDownloadPanel } from './ReportsDownloadPanel';
const api = vi.hoisted(() => ({ preview: vi.fn(), defaults: vi.fn(), pdf: vi.fn(), signoff: vi.fn(), formPdf: vi.fn() }));
vi.mock('@/services/api', () => ({ transmittalApi: { preview: api.preview }, form500Api: { defaults: api.defaults, preview: api.formPdf }, reportsApi: { fullPrintPackagePdf: api.pdf, checkSignoffPreview: api.signoff } }));
const preview = { company: { name: 'Synthetic' }, payroll_checks: { numbers: [], count: 0 }, non_employee_checks: [], tax_totals: { fit: 20, total_fica: 10 }, saved_transmittal: { notes: [], report_list: [], payroll_check_numbers: [], custom_entries: [] } };
beforeEach((): void => {
  api.preview.mockResolvedValue(preview);api.signoff.mockResolvedValue({});api.defaults.mockResolvedValue({data:{company_name:'Synthetic',tax_year:'2026',tax_period_quarter:4}});api.pdf.mockResolvedValue({blob:new Blob(['pdf']),filename:'package.pdf'});
  vi.spyOn(HTMLElement.prototype,'offsetParent','get').mockImplementation(function(this:HTMLElement): Element | null { return this.parentElement; });
  vi.stubGlobal('URL', {createObjectURL:vi.fn(()=> 'blob:synthetic'),revokeObjectURL:vi.fn()});
});
afterEach((): void => {cleanup();vi.restoreAllMocks();vi.unstubAllGlobals();vi.clearAllMocks();});
async function openPackage(): Promise<{user:ReturnType<typeof userEvent.setup>;trigger:HTMLElement;dialog:HTMLElement}> {
  const user=userEvent.setup();render(<MemoryRouter><ReportsDownloadPanel payPeriodId={2} payPeriodStatus="committed" payDate="2026-10-15" /></MemoryRouter>);
  const label=await screen.findByText('Full Print Package',{exact:true});const row=label.closest('div.flex.items-center.justify-between')!;
  const trigger=await within(row as HTMLElement).findByRole('button',{name:'Edit'});await user.click(trigger);const dialog=screen.getByRole('dialog',{name:'Edit Full Print Package'});await within(dialog).findByRole('button',{name:'Open saved Form 500'});return {user,trigger,dialog};
}
it('opens saved Form 500 above the package, owns focus and returns it to the package action',async():Promise<void>=>{
 const {user,dialog}=await openPackage();const trigger=within(dialog).getByRole('button',{name:'Open saved Form 500'});await user.click(trigger);
 const form=await screen.findByRole('dialog',{name:'Form 500'});await within(form).findByDisplayValue('Synthetic');await waitFor(()=>expect(form.contains(document.activeElement)).toBe(true));expect(form.closest('[inert]')).toBeNull();expect(dialog.closest('[inert]')).not.toBeNull();
 await user.keyboard('{Escape}');await waitFor(()=>expect(screen.queryByRole('dialog',{name:'Form 500'})).toBeNull());expect(document.activeElement).toBe(trigger);expect(dialog.closest('[inert]')).toBeNull();
});
it('opens the generated PDF only after the editor releases focus, then returns to the report opener',async():Promise<void>=>{
 const {user,trigger,dialog}=await openPackage();await user.click(within(dialog).getByRole('button',{name:'Generate Full Print Package'}));
 expect(api.pdf).not.toHaveBeenCalled();await waitFor(()=>expect(screen.queryByRole('dialog',{name:'Edit Full Print Package'})).toBeNull());
 const pdf=await screen.findByRole('dialog',{name:'Full Print Package'});await waitFor(()=>expect(pdf.contains(document.activeElement)).toBe(true));expect(pdf.closest('[inert]')).toBeNull();await user.tab({shift:true});expect(pdf.contains(document.activeElement)).toBe(true);
 await user.keyboard('{Escape}');await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull());expect(document.activeElement).toBe(trigger);
});

it('returns from an asynchronously generated Form 500 preview to its disabled-while-saving opener', async (): Promise<void> => {
 let finish!: (value: {blob: Blob; filename: string}) => void;
 api.formPdf.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
 const {user,dialog}=await openPackage();await user.click(within(dialog).getByRole('button',{name:'Open saved Form 500'}));
 const form=await screen.findByRole('dialog',{name:'Form 500'});await within(form).findByDisplayValue('Synthetic');
 const trigger=within(form).getByRole('button',{name:'Preview PDF'});await user.click(trigger);await waitFor(()=>expect((trigger as HTMLButtonElement).disabled).toBe(true));
 trigger.blur();finish({blob:new Blob(['pdf']),filename:'form500.pdf'});
 const pdf=await screen.findByRole('dialog',{name:'Form 500 Preview'});await waitFor(()=>expect(pdf.contains(document.activeElement)).toBe(true));
 await user.keyboard('{Escape}');await waitFor(()=>expect(screen.queryByRole('dialog',{name:'Form 500 Preview'})).toBeNull());expect(document.activeElement).toBe(trigger);
});
