// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ReportsDownloadPanel } from './ReportsDownloadPanel';
const api = vi.hoisted(() => ({ preview: vi.fn(), defaults: vi.fn(), pdf: vi.fn(), signoff: vi.fn(), formPdf: vi.fn(), signoffPdf: vi.fn(), saved: vi.fn() }));
vi.mock('@/services/api', () => ({ transmittalApi: { preview: api.preview }, form500Api: { defaults: api.defaults, preview: api.formPdf }, reportsApi: { fullPrintPackagePdf: api.pdf, checkSignoffPreview: api.signoff, checkSignoffPdf: api.signoffPdf, savedDocuments: api.saved } }));
const preview = { company: { name: 'Synthetic' }, payroll_checks: { numbers: [], count: 0 }, non_employee_checks: [], tax_totals: { fit: 20, total_fica: 10 }, saved_transmittal: { notes: [], report_list: [], payroll_check_numbers: [], custom_entries: [] } };
beforeEach((): void => {
  api.saved.mockResolvedValue({ transmittal: { generated_at: null }, check_signoff: null });
  api.preview.mockResolvedValue(preview);api.signoff.mockResolvedValue({company_name:'Synthetic',entries:[{name:'Example, Avery',check_number:'101'}],saved_signoff:null});api.defaults.mockResolvedValue({data:{company_name:'Synthetic',tax_year:'2026',tax_period_quarter:4}});api.pdf.mockResolvedValue({blob:new Blob(['pdf']),filename:'package.pdf'});
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

it('returns focus when a generating preview is cancelled and ignores its late PDF result', async (): Promise<void> => {
 let finish!: (value: {blob: Blob; filename: string}) => void;
 api.pdf.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
 const {user,trigger,dialog}=await openPackage();await user.click(within(dialog).getByRole('button',{name:'Generate Full Print Package'}));
 const pdf=await screen.findByRole('dialog',{name:'Full Print Package'});await waitFor(()=>expect(pdf.contains(document.activeElement)).toBe(true));
 await user.keyboard('{Escape}');await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull());
 expect((trigger as HTMLButtonElement).disabled).toBe(false);expect(document.activeElement).toBe(trigger);
 await act(async (): Promise<void> => { finish({blob:new Blob(['late pdf']),filename:'late.pdf'}); });expect(URL.createObjectURL).not.toHaveBeenCalled();expect(screen.queryByRole('dialog')).toBeNull();
});

it('names the sign-off editor, contains focus, and returns to its opener on close or Escape', async (): Promise<void> => {
 const entries = [{ name: 'Example, Avery', check_number: '101' }];
 api.signoff.mockResolvedValue({
  company_name: 'Synthetic',
  entries,
  saved_signoff: { entries, generated_at: '2026-11-20T14:38:52Z' },
 });
 const user=userEvent.setup();render(<MemoryRouter><ReportsDownloadPanel payPeriodId={2} payPeriodStatus="committed" payDate="2026-10-15" /></MemoryRouter>);
 const row=screen.getByText('Check Sign-Off Sheet',{exact:true}).parentElement!.parentElement!;
 const trigger=within(row).getByRole('button',{name:'View'});await user.click(trigger);
 const dialog=await screen.findByRole('dialog',{name:'Edit Check Sign-Off Sheet'});
 expect(await within(dialog).findByText('Last generated: Nov 21, 2026, 12:38 AM ChST')).toBeTruthy();
 await within(dialog).findByDisplayValue('Example, Avery');await waitFor(()=>expect(dialog.contains(document.activeElement)).toBe(true));
 expect(trigger.closest('[inert]')).not.toBeNull();await user.tab({shift:true});expect(dialog.contains(document.activeElement)).toBe(true);
 await user.click(within(dialog).getByRole('button',{name:'Close check sign-off editor'}));
 await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull());expect(document.activeElement).toBe(trigger);
 await user.click(trigger);await screen.findByRole('dialog');await user.keyboard('{Escape}');
 await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull());expect(document.activeElement).toBe(trigger);
});

it('hands sign-off generation to its preview after exit and ignores a cancelled late PDF',async():Promise<void>=>{
 let finish!:(value:{blob:Blob;filename:string})=>void;api.signoffPdf.mockImplementation(()=>new Promise(resolve=>{finish=resolve;}));
 const user=userEvent.setup();render(<MemoryRouter><ReportsDownloadPanel payPeriodId={2} payPeriodStatus="committed" payDate="2026-10-15" /></MemoryRouter>);
 const row=screen.getByText('Check Sign-Off Sheet',{exact:true}).parentElement!.parentElement!;const trigger=within(row).getByRole('button',{name:'View'});
 await user.click(trigger);const editor=await screen.findByRole('dialog',{name:'Edit Check Sign-Off Sheet'});await within(editor).findByDisplayValue('Example, Avery');
 await user.click(within(editor).getByRole('button',{name:'Generate Sign-Off Sheet'}));expect(api.signoffPdf).not.toHaveBeenCalled();
 await waitFor(()=>expect(screen.queryByRole('dialog',{name:'Edit Check Sign-Off Sheet'})).toBeNull());
 const pdf=await screen.findByRole('dialog',{name:'Check Sign-Off Sheet'});await waitFor(()=>expect(pdf.contains(document.activeElement)).toBe(true));
 await user.keyboard('{Escape}');await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull());expect((trigger as HTMLButtonElement).disabled).toBe(false);expect(document.activeElement).toBe(trigger);
 await act(async (): Promise<void> => { finish({blob:new Blob(['late signoff']),filename:'signoff.pdf'}); });expect(URL.createObjectURL).not.toHaveBeenCalled();expect(screen.queryByRole('dialog')).toBeNull();
});

it('loads only the saved-state summary when the panel opens, so no report view is recorded', async (): Promise<void> => {
 api.saved.mockResolvedValue({ transmittal: { generated_at: '2026-11-16T09:00:00Z' }, check_signoff: { generated_at: '2026-11-16T09:00:00Z' } });
 render(<MemoryRouter><ReportsDownloadPanel payPeriodId={2} payPeriodStatus="committed" payDate="2026-10-15" /></MemoryRouter>);
 await waitFor(()=>expect(api.saved).toHaveBeenCalledWith(2));
 expect((await screen.findAllByText(/· Last: Nov 16/)).length).toBeGreaterThan(0);
 expect(api.preview).not.toHaveBeenCalled();expect(api.signoff).not.toHaveBeenCalled();
});

it('keeps a just-saved sign-off date when an older summary arrives late, and still applies its transmittal part', async (): Promise<void> => {
 let finishSummary!: (value: {transmittal: {generated_at: string}; check_signoff: null}) => void;
 api.saved.mockImplementation(() => new Promise(resolve => { finishSummary = resolve; }));
 api.signoffPdf.mockResolvedValue({blob:new Blob(['pdf']),filename:'signoff.pdf'});
 const user=userEvent.setup();render(<MemoryRouter><ReportsDownloadPanel payPeriodId={2} payPeriodStatus="committed" payDate="2026-10-15" /></MemoryRouter>);
 const row=screen.getByText('Check Sign-Off Sheet',{exact:true}).parentElement!.parentElement!;
 await user.click(within(row).getByRole('button',{name:'View'}));const editor=await screen.findByRole('dialog',{name:'Edit Check Sign-Off Sheet'});
 await within(editor).findByDisplayValue('Example, Avery');await user.click(within(editor).getByRole('button',{name:'Generate Sign-Off Sheet'}));
 await screen.findByRole('dialog',{name:'Check Sign-Off Sheet'});
 await waitFor(()=>expect(within(row).getByText(/· Last:/)).toBeTruthy());
 await act(async (): Promise<void> => { finishSummary({ transmittal: { generated_at: '2026-10-16T09:00:00Z' }, check_signoff: null }); });
 expect(within(row).getByText(/· Last:/)).toBeTruthy();
 const transmittalRow=screen.getByText('Transmittal Log',{exact:true}).closest('div.flex.items-center.justify-between') as HTMLElement;
 expect(within(transmittalRow).getByText(/· Last: Oct 16/)).toBeTruthy();
});

it('ignores a summary that arrives after the panel moved to another pay period', async (): Promise<void> => {
 let finishSummary!: (value: {transmittal: {generated_at: string}; check_signoff: {generated_at: string}}) => void;
 api.saved.mockImplementationOnce(() => new Promise(resolve => { finishSummary = resolve; }));
 const view=render(<MemoryRouter><ReportsDownloadPanel payPeriodId={2} payPeriodStatus="committed" payDate="2026-10-15" /></MemoryRouter>);
 view.rerender(<MemoryRouter><ReportsDownloadPanel payPeriodId={3} payPeriodStatus="committed" payDate="2026-10-29" /></MemoryRouter>);
 await waitFor(()=>expect(api.saved).toHaveBeenLastCalledWith(3));
 await act(async (): Promise<void> => { finishSummary({ transmittal: { generated_at: '2026-10-16T09:00:00Z' }, check_signoff: { generated_at: '2026-10-16T09:00:00Z' } }); });
 expect(screen.queryByText(/· Last:/)).toBeNull();
});
