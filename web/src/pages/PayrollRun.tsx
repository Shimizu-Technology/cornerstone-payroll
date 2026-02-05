import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { formatCurrency, formatDateRange } from '@/lib/utils';

// Placeholder data - will be replaced with API calls
const currentPeriod = {
  start_date: '2026-01-20',
  end_date: '2026-02-02',
  pay_date: '2026-02-06',
};

const payrollItems = [
  {
    id: 1,
    employee: { id: 1, first_name: 'John', last_name: 'Smith' },
    employment_type: 'salary',
    regular_hours: 80,
    overtime_hours: 0,
    gross_pay: 2000.00,
    withholding_tax: 180.00,
    social_security_tax: 124.00,
    medicare_tax: 29.00,
    retirement_payment: 80.00,
    net_pay: 1587.00,
  },
  {
    id: 2,
    employee: { id: 2, first_name: 'Maria', last_name: 'Santos' },
    employment_type: 'hourly',
    regular_hours: 76,
    overtime_hours: 4,
    gross_pay: 1517.00,
    withholding_tax: 112.00,
    social_security_tax: 94.05,
    medicare_tax: 22.00,
    retirement_payment: 0,
    net_pay: 1288.95,
  },
  {
    id: 3,
    employee: { id: 3, first_name: 'David', last_name: 'Cruz' },
    employment_type: 'hourly',
    regular_hours: 80,
    overtime_hours: 8,
    gross_pay: 1380.00,
    withholding_tax: 95.00,
    social_security_tax: 85.56,
    medicare_tax: 20.01,
    retirement_payment: 69.00,
    net_pay: 1060.43,
  },
  {
    id: 4,
    employee: { id: 4, first_name: 'Ana', last_name: 'Reyes' },
    employment_type: 'salary',
    regular_hours: 80,
    overtime_hours: 0,
    gross_pay: 1730.77,
    withholding_tax: 145.00,
    social_security_tax: 107.31,
    medicare_tax: 25.10,
    retirement_payment: 86.54,
    net_pay: 1366.82,
  },
];

const totals = {
  grossPay: payrollItems.reduce((sum, item) => sum + item.gross_pay, 0),
  withholdingTax: payrollItems.reduce((sum, item) => sum + item.withholding_tax, 0),
  socialSecurity: payrollItems.reduce((sum, item) => sum + item.social_security_tax, 0),
  medicare: payrollItems.reduce((sum, item) => sum + item.medicare_tax, 0),
  retirement: payrollItems.reduce((sum, item) => sum + item.retirement_payment, 0),
  netPay: payrollItems.reduce((sum, item) => sum + item.net_pay, 0),
};

export function PayrollRun() {
  return (
    <div>
      <Header
        title="Run Payroll"
        description={`Pay period: ${formatDateRange(currentPeriod.start_date, currentPeriod.end_date)}`}
        actions={
          <div className="flex gap-3">
            <Button variant="outline">Save Draft</Button>
            <Button>Calculate Payroll</Button>
          </div>
        }
      />

      <div className="p-8">
        {/* Summary Cards */}
        <div className="grid gap-6 md:grid-cols-4 mb-8">
          <Card>
            <CardContent className="pt-6">
              <p className="text-sm font-medium text-gray-500">Gross Pay</p>
              <p className="mt-2 text-2xl font-semibold text-gray-900">
                {formatCurrency(totals.grossPay)}
              </p>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-6">
              <p className="text-sm font-medium text-gray-500">Total Taxes</p>
              <p className="mt-2 text-2xl font-semibold text-gray-900">
                {formatCurrency(totals.withholdingTax + totals.socialSecurity + totals.medicare)}
              </p>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-6">
              <p className="text-sm font-medium text-gray-500">Total Deductions</p>
              <p className="mt-2 text-2xl font-semibold text-gray-900">
                {formatCurrency(totals.retirement)}
              </p>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-6">
              <p className="text-sm font-medium text-gray-500">Net Pay</p>
              <p className="mt-2 text-2xl font-semibold text-green-600">
                {formatCurrency(totals.netPay)}
              </p>
            </CardContent>
          </Card>
        </div>

        {/* Payroll Items Table */}
        <Card>
          <CardHeader>
            <CardTitle>Employee Payroll</CardTitle>
          </CardHeader>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Employee</TableHead>
                <TableHead className="text-right">Hours</TableHead>
                <TableHead className="text-right">Gross Pay</TableHead>
                <TableHead className="text-right">Fed Tax</TableHead>
                <TableHead className="text-right">SS Tax</TableHead>
                <TableHead className="text-right">Medicare</TableHead>
                <TableHead className="text-right">Retirement</TableHead>
                <TableHead className="text-right">Net Pay</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {payrollItems.map((item) => (
                <TableRow key={item.id}>
                  <TableCell>
                    <div className="flex items-center gap-3">
                      <div className="w-8 h-8 bg-primary-100 rounded-full flex items-center justify-center">
                        <span className="text-primary-700 text-sm font-medium">
                          {item.employee.first_name.charAt(0)}
                          {item.employee.last_name.charAt(0)}
                        </span>
                      </div>
                      <div>
                        <p className="font-medium text-gray-900">
                          {item.employee.first_name} {item.employee.last_name}
                        </p>
                        <p className="text-xs text-gray-500 capitalize">
                          {item.employment_type}
                        </p>
                      </div>
                    </div>
                  </TableCell>
                  <TableCell className="text-right">
                    <span className="text-sm text-gray-900">
                      {item.regular_hours}
                      {item.overtime_hours > 0 && (
                        <span className="text-gray-500"> +{item.overtime_hours} OT</span>
                      )}
                    </span>
                  </TableCell>
                  <TableCell className="text-right font-medium">
                    {formatCurrency(item.gross_pay)}
                  </TableCell>
                  <TableCell className="text-right text-sm text-gray-700">
                    {formatCurrency(item.withholding_tax)}
                  </TableCell>
                  <TableCell className="text-right text-sm text-gray-700">
                    {formatCurrency(item.social_security_tax)}
                  </TableCell>
                  <TableCell className="text-right text-sm text-gray-700">
                    {formatCurrency(item.medicare_tax)}
                  </TableCell>
                  <TableCell className="text-right text-sm text-gray-700">
                    {formatCurrency(item.retirement_payment)}
                  </TableCell>
                  <TableCell className="text-right font-medium text-green-600">
                    {formatCurrency(item.net_pay)}
                  </TableCell>
                  <TableCell className="text-right">
                    <Button variant="ghost" size="sm">
                      Edit
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {/* Totals row */}
              <TableRow className="bg-gray-50 font-medium">
                <TableCell>
                  <span className="font-semibold text-gray-900">Totals</span>
                </TableCell>
                <TableCell className="text-right">—</TableCell>
                <TableCell className="text-right">{formatCurrency(totals.grossPay)}</TableCell>
                <TableCell className="text-right">{formatCurrency(totals.withholdingTax)}</TableCell>
                <TableCell className="text-right">{formatCurrency(totals.socialSecurity)}</TableCell>
                <TableCell className="text-right">{formatCurrency(totals.medicare)}</TableCell>
                <TableCell className="text-right">{formatCurrency(totals.retirement)}</TableCell>
                <TableCell className="text-right text-green-600">{formatCurrency(totals.netPay)}</TableCell>
                <TableCell />
              </TableRow>
            </TableBody>
          </Table>
        </Card>
      </div>
    </div>
  );
}
