import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { Layout } from '@/components/layout/Layout';
import { Dashboard } from '@/pages/Dashboard';
import { EmployeeList } from '@/pages/employees/EmployeeList';
import { EmployeeForm } from '@/pages/employees/EmployeeForm';
import { Departments } from '@/pages/Departments';
import { PayPeriods } from '@/pages/PayPeriods';
import { PayPeriodDetail } from '@/pages/PayPeriodDetail';
import { PayrollRun } from '@/pages/PayrollRun';
import { Reports } from '@/pages/Reports';

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Layout />}>
          <Route index element={<Dashboard />} />
          <Route path="employees" element={<EmployeeList />} />
          <Route path="employees/new" element={<EmployeeForm />} />
          <Route path="employees/:id" element={<EmployeeForm />} />
          <Route path="departments" element={<Departments />} />
          <Route path="pay-periods" element={<PayPeriods />} />
          <Route path="pay-periods/:id" element={<PayPeriodDetail />} />
          <Route path="payroll/run" element={<PayrollRun />} />
          <Route path="reports" element={<Reports />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}

export default App;
