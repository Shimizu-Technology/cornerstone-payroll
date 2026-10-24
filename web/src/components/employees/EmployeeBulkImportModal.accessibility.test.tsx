// @vitest-environment jsdom
import {cleanup,render,screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,expect,it,vi} from 'vitest';
import {EmployeeBulkImportModal} from './EmployeeBulkImportModal';
vi.mock('@/contexts/CompanyContext',()=>({useCompany:()=>({activeCompanyId:1})}));
vi.mock('@/hooks/useEmployeeIntakeSettings',()=>({useEmployeeIntakeSettings:()=>({settings:{enabled:false},loading:false})}));
afterEach(():void=>cleanup());
it('announces the bulk employee import close action',async():Promise<void>=>{
 const close=vi.fn();render(<EmployeeBulkImportModal open onClose={close} onComplete={vi.fn()}/>);
 await userEvent.setup().click(screen.getByRole('button',{name:'Close employee bulk import'}));expect(close).toHaveBeenCalledTimes(1);
});
