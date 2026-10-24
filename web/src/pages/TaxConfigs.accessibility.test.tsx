// @vitest-environment jsdom
import type { ReactNode, ReactElement } from 'react';
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import TaxConfigs from './TaxConfigs';
const {notify}=vi.hoisted(()=>({notify:vi.fn()}));
vi.mock('@/components/ui/action-feedback',()=>({useFeedback:()=>({notify})}));
vi.mock('@/components/layout/Header',()=>({Header:({actions}:{actions:ReactNode}):ReactElement=> <><h1>Tax Configuration</h1>{actions}</>}));
vi.mock('@/components/settings/TaxYearVerification',()=>({TaxYearVerification:()=>null}));
vi.mock('@/components/settings/AnnualRetirementLimitsPanel',()=>({AnnualRetirementLimitsPanel:()=>null}));
vi.mock('@/services/api',()=>({taxConfigsApi:{list:vi.fn().mockResolvedValue({tax_configs:[{id:1,tax_year:2026,is_active:true,ss_wage_base:184500,filing_statuses:[]}]}),get:vi.fn().mockResolvedValue({tax_config:{id:1,tax_year:2026,is_active:true,ss_wage_base:184500,ss_rate:.062,medicare_rate:.0145,additional_medicare_rate:.009,additional_medicare_threshold:200000,filing_statuses:[]},previous_year:null})}}));
afterEach(():void=>{cleanup();vi.clearAllMocks();});
it('names each editable global tax setting and both new-year controls by its visible label',async():Promise<void>=>{
 const user=userEvent.setup();render(<TaxConfigs/>);
 await user.click((await screen.findAllByRole('button',{name:'View details'}))[0]);
 const heading=await screen.findByRole('heading',{name:'Tax Rates & Thresholds'});
 await user.click(within(heading.parentElement!).getByRole('button',{name:'Edit'}));
 for(const label of ['SS wage base','SS rate','Medicare rate',"Add'l Medicare rate","Add'l Medicare threshold"]){
  expect(screen.getByRole('textbox',{name:label})).toBe(screen.getByLabelText(label,{exact:true}));
 }
 await user.click(screen.getByRole('button',{name:'Add tax year'}));
 expect(screen.getByLabelText('Tax year',{exact:true}).tagName).toBe('INPUT');
 expect(screen.getByLabelText('Copy from (optional)',{exact:true}).tagName).toBe('SELECT');
});
