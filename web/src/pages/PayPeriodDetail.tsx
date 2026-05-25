import { useEffect, useState, useCallback, useRef, Fragment } from 'react';
import type { FormEvent } from 'react';
import { Link, useParams, useNavigate } from 'react-router-dom';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { formatCurrency, formatDate, formatDateRange, formatGuamDateTime, payPeriodStatusConfig } from '@/lib/utils';
import { payPeriodsApi, employeesApi } from '@/services/api';
import { ImportModal } from '@/components/import/ImportModal';
import { ChecksPanel } from '@/components/payroll/ChecksPanel';
import { CorrectionPanel } from '@/components/payroll/CorrectionPanel';
import { PayrollItemEditModal } from '@/components/payroll/PayrollItemEditModal';
import { CorrectivePaycheckModal } from '@/components/payroll/CorrectivePaycheckModal';
import { ReplaceCheckModal } from '@/components/payroll/ReplaceCheckModal';
import { TimecardOcrPanel } from '@/components/payroll/TimecardOcrPanel';
import { TimecardHistoryPanel } from '@/components/payroll/TimecardHistoryPanel';
import { TimeTrackingImportModal } from '@/components/payroll/TimeTrackingImportModal';
import { ReportsDownloadPanel } from '@/components/reports/ReportsDownloadPanel';
import { NonEmployeeChecksPanel } from '@/components/checks/NonEmployeeChecksPanel';
import type { PayPeriod, PayrollItem, Employee, PayrollItemWageRateHours, TaxSyncStatus, NonEmployeeCheck, SupplementalPayPeriodSummary, PayrollAdjustmentTreatment, PayPeriodComparisonResponse } from '@/types';

interface HoursEntry {
  regular: number;
  overtime: number;
  wage_rates?: PayrollItemWageRateHours[];
}

const TABLE_STICKY_TOP_CLASS = 'top-0';

const MAX_HOURS_PER_PERIOD = 200;
const adjustmentTreatmentLabels: Record<PayrollAdjustmentTreatment, string> = {
  taxable_addition: 'Taxable add.',
  non_taxable_addition: 'Non-taxable add.',
  pre_tax_deduction: 'Pre-tax ded.',
  post_tax_deduction: 'Post-tax ded.',
};
const toNumber = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

const effectiveLoanDeduction = (item: PayrollItem): number => {
  const calculatedLoanPayment = toNumber(item.loan_payment);
  return calculatedLoanPayment > 0 ? calculatedLoanPayment : toNumber(item.loan_deduction);
};

const comparisonMetricLabels: Record<string, string> = {
  employee_count: 'Employees',
  gross_pay: 'Gross Pay',
  net_pay: 'Net Pay',
  fit: 'FIT',
  social_security: 'Social Security',
  medicare: 'Medicare',
  total_deductions: 'Total Deductions',
  reported_tips: 'Reported Tips',
  tips_paid_out: 'Tips Paid Out',
  loan_deduction: 'Loan Deduction',
  loan_payment: 'Loan Payment',
};

function formatSignedCurrency(value: number) {
  const formatted = formatCurrency(Math.abs(value));
  if (value > 0) return `+${formatted}`;
  if (value < 0) return `-${formatted}`;
  return formatted;
}

function formatSignedNumber(value: number) {
  if (value > 0) return `+${value}`;
  if (value < 0) return String(value);
  return '0';
}

function templateWageRates(employee: Employee, payrollItem?: PayrollItem): PayrollItemWageRateHours[] {
  const existing = payrollItem?.wage_rate_hours;
  const configuredRates = employee.wage_rates || [];
  if (configuredRates.length > 0) {
    const existingById = new Map(
      (existing || []).flatMap((entry) => (
        entry.employee_wage_rate_id != null ? [[entry.employee_wage_rate_id, entry]] : []
      ))
    );
    const existingByLabel = new Map(
      (existing || []).map((entry) => [entry.label.trim().toLowerCase(), entry])
    );
    const defaultPrimaryHours = configuredRates.length > 1 ? 0 : toNumber(payrollItem?.hours_worked ?? 0);

    return configuredRates.map((rate) => {
      const matchedExisting =
        (rate.id != null ? existingById.get(rate.id) : undefined) ||
        existingByLabel.get(rate.label.trim().toLowerCase());

      return {
        employee_wage_rate_id: rate.id,
        label: rate.label,
        rate: toNumber(rate.rate),
        regular_hours: matchedExisting ? toNumber(matchedExisting.regular_hours) : (rate.is_primary ? defaultPrimaryHours : 0),
        overtime_hours: matchedExisting ? toNumber(matchedExisting.overtime_hours) : (rate.is_primary ? toNumber(payrollItem?.overtime_hours ?? 0) : 0),
        holiday_hours: matchedExisting ? toNumber(matchedExisting.holiday_hours) : (rate.is_primary ? toNumber(payrollItem?.holiday_hours ?? 0) : 0),
        pto_hours: matchedExisting ? toNumber(matchedExisting.pto_hours) : (rate.is_primary ? toNumber(payrollItem?.pto_hours ?? 0) : 0),
        is_primary: rate.is_primary,
        active: rate.active,
      };
    });
  }

  if (existing && existing.length > 0) {
    return existing.map((entry) => ({
      employee_wage_rate_id: entry.employee_wage_rate_id,
      label: entry.label,
      rate: toNumber(entry.rate),
      regular_hours: toNumber(entry.regular_hours),
      overtime_hours: toNumber(entry.overtime_hours),
      holiday_hours: toNumber(entry.holiday_hours),
      pto_hours: toNumber(entry.pto_hours),
      is_primary: entry.is_primary ?? false,
      active: entry.active ?? true,
    }));
  }

  return configuredRates.map((rate) => ({
    employee_wage_rate_id: rate.id,
    label: rate.label,
    rate: toNumber(rate.rate),
    regular_hours: rate.is_primary ? toNumber(payrollItem?.hours_worked ?? 0) : 0,
    overtime_hours: rate.is_primary ? toNumber(payrollItem?.overtime_hours ?? 0) : 0,
    holiday_hours: rate.is_primary ? toNumber(payrollItem?.holiday_hours ?? 0) : 0,
    pto_hours: rate.is_primary ? toNumber(payrollItem?.pto_hours ?? 0) : 0,
    is_primary: rate.is_primary,
    active: rate.active,
  }));
}

function buildHoursMap(payrollItems: PayrollItem[], employees: Employee[]): Record<string, HoursEntry> {
  const hours: Record<string, HoursEntry> = {};
  const employeeMap = new Map(employees.map((emp) => [emp.id, emp]));

  payrollItems.forEach((item) => {
    const employee = employeeMap.get(item.employee_id);
    const noHours = employee?.employment_type === 'salary' || (employee?.employment_type === 'contractor' && employee?.contractor_pay_type !== 'hourly');
    const wageRates = employee && (employee.employment_type === 'hourly' || (employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly'))
      ? templateWageRates(employee, item)
      : [];
    hours[String(item.employee_id)] = {
      regular: noHours ? 0 : (item.hours_worked || 0),
      overtime: noHours ? 0 : (item.overtime_hours || 0),
      wage_rates: wageRates.length > 0 ? wageRates : undefined,
    };
  });

  employees.forEach((emp) => {
    if (!hours[String(emp.id)]) {
      const wageRates = emp.employment_type === 'hourly' || (emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly')
        ? templateWageRates(emp)
        : [];
      const regularDefault = wageRates.length > 1
        ? wageRates.reduce((sum, rate) => sum + toNumber(rate.regular_hours), 0)
        : 0;
      hours[String(emp.id)] = {
        regular: regularDefault,
        overtime: 0,
        wage_rates: wageRates.length > 0 ? wageRates : undefined,
      };
    }
  });

  return hours;
}

function derivePayrollUiState(payrollItems: PayrollItem[]) {
  const salaryOverrides: Record<string, number> = {};
  const tips: Record<string, { amount: number; pool: string }> = {};
  const tipsPaidOut: Record<string, number> = {};
  const loans: Record<string, number> = {};

  payrollItems.forEach((item) => {
    if (item.salary_override && toNumber(item.salary_override) > 0) {
      salaryOverrides[String(item.employee_id)] = toNumber(item.salary_override);
    }

    const tipAmount = toNumber(item.reported_tips);
    if (tipAmount > 0) {
      tips[String(item.employee_id)] = { amount: tipAmount, pool: item.tip_pool || '' };
    }

    const tipsPaidOutAmount = toNumber(item.tips_paid_out);
    if (tipsPaidOutAmount > 0) {
      tipsPaidOut[String(item.employee_id)] = tipsPaidOutAmount;
    }

    const loanAmount = toNumber(item.loan_deduction);
    if (loanAmount > 0) {
      loans[String(item.employee_id)] = loanAmount;
    }
  });

  return {
    salaryOverrides,
    tips,
    tipsPaidOut,
    loans,
    showTipsLoans: Object.keys(tips).length > 0 || Object.keys(tipsPaidOut).length > 0 || Object.keys(loans).length > 0,
  };
}

const taxSyncStatusConfig: Record<TaxSyncStatus, { label: string; variant: 'default' | 'success' | 'warning' | 'danger' | 'info' }> = {
  pending: { label: 'Tax Sync Pending', variant: 'default' },
  syncing: { label: 'Tax Syncing...', variant: 'info' },
  synced: { label: 'Tax Synced', variant: 'success' },
  failed: { label: 'Tax Sync Failed', variant: 'danger' },
};

export function PayPeriodDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [payPeriod, setPayPeriod] = useState<PayPeriod | null>(null);
  const [payrollItems, setPayrollItems] = useState<PayrollItem[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  // Mirrors the non-employee checks loaded by NonEmployeeChecksPanel so we
  // can detect when the FIT auto-deposit amount has been overridden away
  // from the calculated total. Updated via the panel's onChecksLoaded prop.
  const [nonEmployeeChecks, setNonEmployeeChecks] = useState<NonEmployeeCheck[]>([]);
  const [hoursMap, setHoursMap] = useState<Record<string, HoursEntry>>({});
  const [salaryOverrideMap, setSalaryOverrideMap] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);
  const [retryingSyncTax, setRetryingSyncTax] = useState(false);
  const [importModalOpen, setImportModalOpen] = useState(false);
  const [timeTrackingImportOpen, setTimeTrackingImportOpen] = useState(false);
  const [payDateCorrectionOpen, setPayDateCorrectionOpen] = useState(false);
  const [payDateCorrectionDate, setPayDateCorrectionDate] = useState('');
  const [payDateCorrectionReason, setPayDateCorrectionReason] = useState('');
  const [payDateCorrectionSubmitting, setPayDateCorrectionSubmitting] = useState(false);
  const [editingItem, setEditingItem] = useState<PayrollItem | null>(null);
  const [correctingItem, setCorrectingItem] = useState<PayrollItem | null>(null);
  const [replacingItem, setReplacingItem] = useState<PayrollItem | null>(null);
  const [supplementals, setSupplementals] = useState<SupplementalPayPeriodSummary[]>([]);
  const [supplementalsLoading, setSupplementalsLoading] = useState(false);
  const [comparison, setComparison] = useState<PayPeriodComparisonResponse | null>(null);
  const [comparisonLoading, setComparisonLoading] = useState(false);
  const [comparisonError, setComparisonError] = useState<string | null>(null);
  const [additionalEmployeeIds, setAdditionalEmployeeIds] = useState<Set<number>>(new Set());
  const [searchTerm, setSearchTerm] = useState('');
  const [employeeTypeFilter, setEmployeeTypeFilter] = useState<'all' | 'salary' | 'hourly' | 'contractor'>('all');
  const [departmentFilter, setDepartmentFilter] = useState<string>('all');
  const [hoursSortBy, setHoursSortBy] = useState<'name' | 'rate' | 'hours' | 'gross'>('name');
  const [hoursSortDirection, setHoursSortDirection] = useState<'asc' | 'desc'>('asc');
  const [resultsSortBy, setResultsSortBy] = useState<'name' | 'rate' | 'hours' | 'gross' | 'net' | 'fit'>('name');
  const [resultsSortDirection, setResultsSortDirection] = useState<'asc' | 'desc'>('asc');
  const [hoursTableOpen, setHoursTableOpen] = useState(true);
  const [tipsMap, setTipsMap] = useState<Record<string, { amount: number; pool: string }>>({});
  const [tipsPaidOutMap, setTipsPaidOutMap] = useState<Record<string, number>>({});
  const [loansMap, setLoansMap] = useState<Record<string, number>>({});
  const [showTipsLoans, setShowTipsLoans] = useState(false);
  const tipsLoansVisibilityModeRef = useRef<'auto' | 'manual'>('auto');

  const syncDerivedPayrollState = useCallback((items: PayrollItem[]) => {
    const derivedState = derivePayrollUiState(items);
    setSalaryOverrideMap(derivedState.salaryOverrides);
    setTipsMap(derivedState.tips);
    setTipsPaidOutMap(derivedState.tipsPaidOut);
    setLoansMap(derivedState.loans);
    setShowTipsLoans((previous) => (
      tipsLoansVisibilityModeRef.current === 'manual' ? previous : derivedState.showTipsLoans
    ));
  }, []);

  const loadAllActiveEmployees = useCallback(async () => {
    const allEmployees: Employee[] = [];
    let page = 1;
    let totalPages = 1;

    try {
      do {
        const response = await employeesApi.list({ status: 'active', per_page: 100, page });
        allEmployees.push(...response.data);
        totalPages = response.meta.total_pages;
        page += 1;
      } while (page <= totalPages);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Unknown error';
      throw new Error(`Failed to load active employees page ${page}: ${message}`);
    }

    return allEmployees;
  }, []);

  const loadPayPeriod = useCallback(async (periodId: number, silent = false) => {
    try {
      if (!silent) setLoading(true);
      setError(null);

      const [ppResponse, empResponse] = await Promise.all([
        payPeriodsApi.get(periodId),
        loadAllActiveEmployees(),
      ]);

      setPayPeriod(ppResponse.pay_period);
      setPayrollItems(ppResponse.pay_period.payroll_items || []);
      setEmployees(empResponse);
      setHoursMap(buildHoursMap(ppResponse.pay_period.payroll_items || [], empResponse));
      syncDerivedPayrollState(ppResponse.pay_period.payroll_items || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay period');
    } finally {
      if (!silent) setLoading(false);
    }
  }, [loadAllActiveEmployees, syncDerivedPayrollState]);

  useEffect(() => {
    if (id) {
      // Reset cross-pay-period observer state so divergence indicators don't
      // momentarily render against the previous period's checks while the
      // new panel loads.
      setNonEmployeeChecks([]);
      setSupplementals([]);
      setComparison(null);
      setComparisonError(null);
      tipsLoansVisibilityModeRef.current = 'auto';
      loadPayPeriod(parseInt(id));
    }
  }, [id, loadPayPeriod]);

  const loadComparison = useCallback(async (payPeriodId: number) => {
    setComparisonLoading(true);
    setComparisonError(null);
    try {
      const res = await payPeriodsApi.comparison(payPeriodId);
      setComparison(res);
    } catch (err) {
      setComparison(null);
      setComparisonError(err instanceof Error ? err.message : 'Failed to load pay period comparison');
    } finally {
      setComparisonLoading(false);
    }
  }, []);

  // Load any linked corrective supplemental periods for a regular,
  // committed period. Refetches whenever a new corrective is issued.
  const loadSupplementals = useCallback(async (payPeriodId: number) => {
    setSupplementalsLoading(true);
    try {
      const res = await payPeriodsApi.supplementalPayPeriods(payPeriodId);
      setSupplementals(res.supplemental_pay_periods);
    } catch {
      // Non-fatal: hide the section silently
      setSupplementals([]);
    } finally {
      setSupplementalsLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!payPeriod) return;
    if (payPeriod.cycle === 'supplemental' || !['calculated', 'approved', 'committed'].includes(payPeriod.status)) {
      setComparison(null);
      setComparisonError(null);
      return;
    }
    loadComparison(payPeriod.id);
  }, [payPeriod, loadComparison]);

  useEffect(() => {
    if (!payPeriod) return;
    if (payPeriod.cycle === 'supplemental') return; // never loads its own supplementals
    if (payPeriod.status !== 'committed') return;
    loadSupplementals(payPeriod.id);
  }, [payPeriod, loadSupplementals]);

  const updateHours = (employeeId: number, field: 'regular' | 'overtime', value: number) => {
    const clampedValue = Math.max(0, Math.min(MAX_HOURS_PER_PERIOD, value));
    setHoursMap((prev) => ({
      ...prev,
      [String(employeeId)]: {
        ...prev[String(employeeId)],
        [field]: clampedValue,
      },
    }));
  };

  const updateWageRateHours = (
    employeeId: number,
    index: number,
    field: 'regular_hours' | 'overtime_hours',
    value: number
  ) => {
    const clampedValue = Math.max(0, Math.min(MAX_HOURS_PER_PERIOD, value));
    setHoursMap((prev) => {
      const current = prev[String(employeeId)];
      const wageRates = [...(current?.wage_rates || [])];
      if (!wageRates[index]) return prev;

      wageRates[index] = {
        ...wageRates[index],
        [field]: clampedValue,
      };

      return {
        ...prev,
        [String(employeeId)]: {
          regular: wageRates.reduce((sum, entry) => sum + toNumber(entry.regular_hours), 0),
          overtime: wageRates.reduce((sum, entry) => sum + toNumber(entry.overtime_hours), 0),
          wage_rates: wageRates,
        },
      };
    });
  };

  const updateSalaryOverride = (employeeId: number, value: number) => {
    setSalaryOverrideMap((prev) => ({ ...prev, [String(employeeId)]: Math.max(0, value) }));
  };

  const updateTip = (employeeId: number, amount: number, pool?: string) => {
    setTipsMap((prev) => {
      const existing = prev[String(employeeId)] || { amount: 0, pool: '' };
      return { ...prev, [String(employeeId)]: { amount: Math.max(0, amount), pool: pool ?? existing.pool } };
    });
  };

  const updateLoan = (employeeId: number, amount: number) => {
    setLoansMap((prev) => ({ ...prev, [String(employeeId)]: Math.max(0, amount) }));
  };

  const updateTipsPaidOut = (employeeId: number, amount: number) => {
    setTipsPaidOutMap((prev) => ({ ...prev, [String(employeeId)]: Math.max(0, amount) }));
  };

  const handleRunPayroll = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);

      const invalidHours = Object.entries(hoursMap).find(([, entry]) => {
        const rateEntryInvalid = (entry.wage_rates || []).some((rate) => (
          toNumber(rate.regular_hours) < 0 ||
          toNumber(rate.overtime_hours) < 0 ||
          toNumber(rate.regular_hours) > MAX_HOURS_PER_PERIOD ||
          toNumber(rate.overtime_hours) > MAX_HOURS_PER_PERIOD
        ));

        return (
          entry.regular < 0 ||
          entry.overtime < 0 ||
          entry.regular > MAX_HOURS_PER_PERIOD ||
          entry.overtime > MAX_HOURS_PER_PERIOD ||
          rateEntryInvalid
        );
      });
      if (invalidHours) {
        setError(`Hours must be between 0 and ${MAX_HOURS_PER_PERIOD} per period`);
        return;
      }

      // Build hours payload
      const hours: Record<string, { regular?: number; overtime?: number; wage_rates?: PayrollItemWageRateHours[] }> = {};
      Object.entries(hoursMap).forEach(([empId, entry]) => {
        hours[empId] = entry.wage_rates && entry.wage_rates.length > 1
          ? {
              regular: entry.regular,
              overtime: entry.overtime,
              wage_rates: entry.wage_rates,
            }
          : { regular: entry.regular, overtime: entry.overtime };
      });

      // Build salary overrides payload for variable salary employees.
      // Send zeroes too so clearing a variable salary amount removes stale overrides.
      const includedEmployeeIds = new Set([
        ...payrollItems.map((pi) => pi.employee_id),
        ...additionalEmployeeIds,
      ]);
      const salary_overrides: Record<string, number> = {};
      const missingVariableSalaryEmployees: string[] = [];
      employees.forEach((employee) => {
        if (employee.employment_type === 'salary' && employee.salary_type === 'variable' && includedEmployeeIds.has(employee.id)) {
          const amount = Math.max(0, toNumber(salaryOverrideMap[String(employee.id)]));
          salary_overrides[String(employee.id)] = amount;
          if (amount <= 0) {
            missingVariableSalaryEmployees.push(`${employee.first_name} ${employee.last_name}`);
          }
        }
      });

      if (missingVariableSalaryEmployees.length > 0) {
        setError(`Enter period pay before recalculating for variable salary employee(s): ${missingVariableSalaryEmployees.join(', ')}`);
        return;
      }

      // Build tips payload
      const tips: Record<string, { amount: number; pool: string }> = {};
      Object.entries(tipsMap).forEach(([empId, data]) => {
        tips[empId] = { amount: Math.max(0, toNumber(data.amount)), pool: data.pool || '' };
      });

      const tips_paid_out: Record<string, number> = {};
      Object.entries(tipsPaidOutMap).forEach(([empId, amount]) => {
        tips_paid_out[empId] = Math.max(0, toNumber(amount));
      });

      // Build loan deductions payload
      const loan_deductions: Record<string, number> = {};
      Object.entries(loansMap).forEach(([empId, amount]) => {
        loan_deductions[empId] = Math.max(0, toNumber(amount));
      });

      // Include any manually-added employees who were missing from the import
      const employee_ids = additionalEmployeeIds.size > 0
        ? [...new Set([...payrollItems.map(pi => pi.employee_id), ...additionalEmployeeIds])]
        : undefined;

      const response = await payPeriodsApi.runPayroll(payPeriod.id, {
        hours,
        ...(Object.keys(salary_overrides).length > 0 ? { salary_overrides } : {}),
        ...(Object.keys(tips).length > 0 ? { tips } : {}),
        ...(Object.keys(tips_paid_out).length > 0 ? { tips_paid_out } : {}),
        ...(Object.keys(loan_deductions).length > 0 ? { loan_deductions } : {}),
        ...(employee_ids ? { employee_ids } : {}),
      });
      setPayPeriod(response.pay_period);
      setPayrollItems(response.pay_period.payroll_items || []);
      setHoursMap(buildHoursMap(response.pay_period.payroll_items || [], employees));
      syncDerivedPayrollState(response.pay_period.payroll_items || []);
      setAdditionalEmployeeIds(new Set());

      if (response.results.errors.length > 0) {
        setError(
          `Calculated ${response.results.success.length} employees. ${response.results.errors.length} errors: ${response.results.errors.map((e) => e.error).join(', ')}`
        );
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to run payroll');
    } finally {
      setProcessing(false);
    }
  };

  const handleApprove = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.approve(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to approve');
    } finally {
      setProcessing(false);
    }
  };

  const handleUnapprove = async () => {
    if (!payPeriod) return;
    if (!confirm('Roll back approval? This will return the pay period to "Calculated" status.')) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.unapprove(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to unapprove');
    } finally {
      setProcessing(false);
    }
  };

  const handleCommit = async () => {
    if (!payPeriod) return;
    if (!confirm('Commit this payroll? This will update YTD totals and cannot be undone.')) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.commit(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to commit');
    } finally {
      setProcessing(false);
    }
  };

  const handleRetryTaxSync = async () => {
    if (!payPeriod) return;
    try {
      setRetryingSyncTax(true);
      setError(null);
      const response = await payPeriodsApi.retryTaxSync(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to retry tax sync');
    } finally {
      setRetryingSyncTax(false);
    }
  };

  const openPayDateCorrection = () => {
    if (!payPeriod) return;
    setPayDateCorrectionDate(payPeriod.pay_date);
    setPayDateCorrectionReason('');
    setPayDateCorrectionOpen(true);
  };

  const handleCorrectPayDate = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!payPeriod) return;

    if (!payDateCorrectionDate) {
      setError('Pay date is required');
      return;
    }

    if (payDateCorrectionDate < payPeriod.end_date) {
      setError('Pay date must be on or after end date');
      return;
    }

    if (!payDateCorrectionReason.trim()) {
      setError('A reason is required to correct a committed pay date');
      return;
    }

    try {
      setPayDateCorrectionSubmitting(true);
      setError(null);
      const response = await payPeriodsApi.correctPayDate(payPeriod.id, {
        pay_date: payDateCorrectionDate,
        reason: payDateCorrectionReason.trim(),
      });
      setPayPeriod(response.pay_period);
      setPayDateCorrectionOpen(false);
      setPayDateCorrectionReason('');
      await loadPayPeriod(payPeriod.id, true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to correct pay date');
    } finally {
      setPayDateCorrectionSubmitting(false);
    }
  };

  const handleImportComplete = (updatedPayPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => {
    setPayPeriod(updatedPayPeriod);
    setPayrollItems(updatedPayPeriod.payroll_items || []);
    setHoursMap(buildHoursMap(updatedPayPeriod.payroll_items || [], employees));
    syncDerivedPayrollState(updatedPayPeriod.payroll_items || []);
    setAdditionalEmployeeIds(new Set());
  };

  const handlePayrollItemSaved = (updated: PayrollItem) => {
    setPayrollItems((prev) =>
      prev.map((item) => (item.id === updated.id ? updated : item))
    );
  };

  const handlePayrollItemApplied = (updated?: PayrollItem) => {
    if (!updated) return;

    setPayrollItems((prev) => {
      const exists = prev.some((item) => item.id === updated.id);
      return exists
        ? prev.map((item) => (item.id === updated.id ? { ...item, ...updated } : item))
        : [...prev, updated];
    });
    setHoursMap((prev) => {
      const updatedHours = buildHoursMap([updated], employees)[String(updated.employee_id)] || {
        regular: toNumber(updated.hours_worked),
        overtime: toNumber(updated.overtime_hours),
        wage_rates: updated.wage_rate_hours,
      };

      return {
        ...prev,
        [String(updated.employee_id)]: updatedHours,
      };
    });
  };

  if (loading) {
    return <div className="p-8 text-center text-gray-500">Loading...</div>;
  }

  if (!payPeriod) {
    return <div className="p-8 text-center text-gray-500">Pay period not found</div>;
  }

  const isDraft = payPeriod.status === 'draft';
  const isCalculated = payPeriod.status === 'calculated';
  const isApproved = payPeriod.status === 'approved';
  const isCommitted = payPeriod.status === 'committed';
  const isVoided = payPeriod.correction_status === 'voided';
  const isCorrection = payPeriod.correction_status === 'correction';
  const statusConfig = payPeriodStatusConfig[payPeriod.status];

  const syncStatus = payPeriod.tax_sync_status as TaxSyncStatus | null | undefined;
  const syncConfig = syncStatus ? taxSyncStatusConfig[syncStatus] : null;
  const MAX_SYNC_ATTEMPTS = 5;
  const canRetrySyncTax = isCommitted && (syncStatus === 'failed' || syncStatus === 'pending');
  const canEditPayPeriod = !isCommitted && !isVoided;
  const canImportMosa = isDraft && canEditPayPeriod;
  const canImportTimeTracking = isDraft && canEditPayPeriod;

  // Summaries
  const reportablePayrollItems = payrollItems.filter(i => !i.voided);
  const contractorItems = reportablePayrollItems.filter(i => i.employment_type === 'contractor');
  const totalGross = reportablePayrollItems.reduce((s, i) => s + toNumber(i.gross_pay), 0);
  const totalWithholding = reportablePayrollItems.reduce((s, i) => s + toNumber(i.withholding_tax), 0);
  const totalAddlWH = reportablePayrollItems.reduce((s, i) => s + toNumber(i.additional_withholding), 0);
  const totalSS = reportablePayrollItems.reduce((s, i) => s + toNumber(i.social_security_tax), 0);
  const totalMedicare = reportablePayrollItems.reduce((s, i) => s + toNumber(i.medicare_tax), 0);
  const totalDeductions = reportablePayrollItems.reduce((s, i) => s + toNumber(i.total_deductions), 0);
  const totalNet = reportablePayrollItems.reduce((s, i) => s + toNumber(i.net_pay), 0);
  const totalEmployerSS = reportablePayrollItems.reduce((s, i) => s + toNumber(i.employer_social_security_tax), 0);
  const totalEmployerMedicare = reportablePayrollItems.reduce((s, i) => s + toNumber(i.employer_medicare_tax), 0);
  const totalDRTDeposit = totalWithholding;

  // Detect FIT-deposit override: if the user has edited the auto-FIT
  // non-employee check's amount, it'll no longer equal the calculated
  // FIT total derived from PayrollItem.withholding_tax. Surfacing this
  // divergence prevents silent desync between "what payroll says we owe"
  // and "what we're actually depositing."
  const fitDepositCheck = nonEmployeeChecks.find(
    c =>
      !c.voided &&
      (c.auto_generated_type === 'fit_deposit' ||
        (c.check_type === 'tax_deposit' &&
          (c.payable_to === 'Treasurer of Guam' || c.payable_to === 'EFTPS - Federal Income Tax')))
  );
  const fitDepositAmount = fitDepositCheck ? Number(fitDepositCheck.amount) : null;
  const fitDivergence =
    fitDepositAmount !== null && Math.abs(fitDepositAmount - totalWithholding) > 0.005
      ? { calculated: totalWithholding, deposited: fitDepositAmount, delta: fitDepositAmount - totalWithholding }
      : null;
  const totalContractorPay = contractorItems.reduce((s, i) => s + toNumber(i.gross_pay), 0);
  const totalCustomEarnings = reportablePayrollItems.reduce(
    (sum, item) => sum + (item.custom_earnings || []).reduce((itemSum, earning) => itemSum + toNumber(earning.amount), 0),
    0
  );
  const totalCustomDeductions = reportablePayrollItems.reduce(
    (sum, item) => sum + (item.custom_deductions || []).reduce((itemSum, deduction) => itemSum + toNumber(deduction.amount), 0),
    0
  );
  const totalPayrollAdjustments = reportablePayrollItems.reduce(
    (sum, item) => sum + (item.payroll_adjustments || [])
      .filter((adjustment) => adjustment.active !== false)
      .reduce((itemSum, adjustment) => {
        const amount = toNumber(adjustment.amount);
        return itemSum + (adjustment.treatment === 'pre_tax_deduction' || adjustment.treatment === 'post_tax_deduction' ? -amount : amount);
      }, 0),
    0
  );

  const comparisonHighlights = comparison
    ? ['employee_count', 'gross_pay', 'net_pay', 'fit', 'reported_tips', 'loan_deduction']
      .filter((key) => comparison.summary[key])
      .map((key) => ({ key, ...comparison.summary[key] }))
    : [];
  const comparisonFlagTone = comparison?.review_flags.status === 'warning'
    ? 'border-red-200 bg-red-50 text-red-800'
    : comparison?.review_flags.status === 'review'
      ? 'border-amber-200 bg-amber-50 text-amber-800'
      : 'border-emerald-200 bg-emerald-50 text-emerald-800';
  const comparisonRowLimit = 10;
  const comparisonTotalRows = comparison?.employee_changes.length || 0;
  const comparisonRows = comparison?.employee_changes.slice(0, comparisonRowLimit) || [];
  const comparisonHiddenRows = Math.max(0, comparisonTotalRows - comparisonRows.length);

  // showTipsLoans is toggled by user or auto-set when imported data has tips/loans

  const employeeLookup = new Map(employees.map((emp) => [emp.id, emp]));
  const departmentOptions = Array.from(
    new Map(
      [
        ...employees
          .filter((emp) => emp.department_id && emp.department?.name)
          .map((emp) => [String(emp.department_id), emp.department?.name || ''] as const),
        ...payrollItems
          .filter((item) => item.department_id && item.department_name)
          .map((item) => [String(item.department_id), item.department_name || ''] as const),
      ].sort((left, right) => left[1].localeCompare(right[1]))
    ).entries()
  );
  const typeOrder: Record<string, number> = { salary: 0, hourly: 1, contractor: 2 };
  const matchesEmployeeFilters = (employmentType: string, searchableValues: string[], departmentId?: number | null) => {
    if (employeeTypeFilter !== 'all' && employmentType !== employeeTypeFilter) return false;
    if (departmentFilter !== 'all' && String(departmentId || '') !== departmentFilter) return false;
    if (!searchTerm.trim()) return true;

    const term = searchTerm.trim().toLowerCase();
    return searchableValues.some((value) => value.toLowerCase().includes(term));
  };

  const compareDirectional = (left: number | string, right: number | string, direction: 'asc' | 'desc') => {
    const multiplier = direction === 'asc' ? 1 : -1;
    if (typeof left === 'string' && typeof right === 'string') {
      return left.localeCompare(right) * multiplier;
    }

    return ((Number(left) || 0) - (Number(right) || 0)) * multiplier;
  };
  const employeeLastNameSortKey = (item: PayrollItem) => {
    const employee = employeeLookup.get(item.employee_id);
    const lastName = item.employee_last_name || employee?.last_name || '';
    const firstName = item.employee_first_name || employee?.first_name || '';
    return `${lastName} ${firstName} ${item.employee_name || ''}`.trim();
  };

  const sortPayrollItems = [...payrollItems]
    .filter((item) => matchesEmployeeFilters(
      item.employment_type,
      [item.employee_name || '', item.check_number || '', item.department_name || employeeLookup.get(item.employee_id)?.department?.name || ''],
      item.department_id ?? employeeLookup.get(item.employee_id)?.department_id
    ))
    .sort((left, right) => {
      const typeDiff = employeeTypeFilter === 'all'
        ? (typeOrder[left.employment_type] ?? 9) - (typeOrder[right.employment_type] ?? 9)
        : 0;
      if (typeDiff !== 0) return typeDiff;

      switch (resultsSortBy) {
      case 'rate':
        return compareDirectional(toNumber(left.pay_rate), toNumber(right.pay_rate), resultsSortDirection);
      case 'hours':
        return compareDirectional(toNumber(left.hours_worked), toNumber(right.hours_worked), resultsSortDirection);
      case 'gross':
        return compareDirectional(toNumber(left.gross_pay), toNumber(right.gross_pay), resultsSortDirection);
      case 'net':
        return compareDirectional(toNumber(left.net_pay), toNumber(right.net_pay), resultsSortDirection);
      case 'fit':
        return compareDirectional(toNumber(left.withholding_tax), toNumber(right.withholding_tax), resultsSortDirection);
      case 'name':
      default:
        return compareDirectional(
          employeeLastNameSortKey(left),
          employeeLastNameSortKey(right),
          resultsSortDirection
        );
      }
    });

  const lifecycle = payPeriod.lifecycle || {};
  const processedAt = payPeriod.processed_at || payPeriod.committed_at || lifecycle.committed?.timestamp;
  const processedBy = payPeriod.processed_by_name || lifecycle.committed?.actor_name;
  const payDateCorrections = payPeriod.pay_date_corrections || [];
  const formatCorrectionPayDate = (date?: string | null) => (
    date ? formatDate(date, { month: 'long', day: 'numeric', year: 'numeric' }) : 'Unknown date'
  );
  const lifecycleActor = (actorName?: string | null) => {
    if (actorName) return `by ${actorName}`;
    return 'Operator not recorded';
  };
  const lifecycleItems = [
    {
      label: 'Created',
      timestamp: lifecycle.created?.timestamp || payPeriod.created_at,
      actor: lifecycleActor(lifecycle.created?.actor_name),
      tone: 'default' as const,
    },
    {
      label: 'Calculated',
      timestamp: lifecycle.calculated?.timestamp,
      actor: lifecycleActor(lifecycle.calculated?.actor_name),
      tone: isDraft ? 'default' as const : 'warning' as const,
    },
    {
      label: 'Approved',
      timestamp: lifecycle.approved?.timestamp,
      actor: lifecycleActor(lifecycle.approved?.actor_name),
      tone: (isApproved || isCommitted) ? 'info' as const : 'default' as const,
    },
    ...(lifecycle.unapproved?.timestamp ? [{
      label: 'Unapproved',
      timestamp: lifecycle.unapproved.timestamp,
      actor: lifecycleActor(lifecycle.unapproved.actor_name),
      tone: 'warning' as const,
    }] : []),
    {
      label: 'Committed / processed',
      timestamp: processedAt,
      actor: processedBy
        ? `by ${processedBy}`
        : lifecycleActor(lifecycle.committed?.actor_name),
      tone: isCommitted ? 'success' as const : 'default' as const,
    },
    ...(syncStatus || payPeriod.tax_synced_at ? [{
      label: 'Tax sync',
      timestamp: lifecycle.tax_synced?.timestamp || payPeriod.tax_synced_at,
      actor: syncConfig?.label || 'Not started',
      tone: syncConfig?.variant || 'default' as const,
    }] : []),
  ].sort((left, right) => {
    if (left.timestamp && right.timestamp) {
      return new Date(left.timestamp).getTime() - new Date(right.timestamp).getTime();
    }

    if (left.timestamp) return -1;
    if (right.timestamp) return 1;
    return 0;
  });

  return (
    <div>
      <Header
        title={`Pay Period: ${formatDateRange(payPeriod.start_date, payPeriod.end_date)}`}
        description={`Pay Date: ${new Date(payPeriod.pay_date).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}`}
        actions={
          <div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end">
            <Button variant="outline" onClick={() => navigate('/pay-periods')}>
              Back to List
            </Button>
            {isCommitted && !isVoided && (
              <Button variant="outline" onClick={openPayDateCorrection}>
                Correct Pay Date
              </Button>
            )}
            {isDraft && (
              <>
                {canImportMosa && (
                  <Button variant="outline" onClick={() => setImportModalOpen(true)}>
                    Import (MoSa)
                  </Button>
                )}
                {canImportTimeTracking && (
                  <Button variant="outline" onClick={() => setTimeTrackingImportOpen(true)}>
                    Import Time Tracking
                  </Button>
                )}
                <Button onClick={handleRunPayroll} disabled={processing}>
                  {processing ? 'Calculating...' : 'Calculate Payroll'}
                </Button>
              </>
            )}
            {isCalculated && (
              <>
                <Button variant="outline" onClick={handleRunPayroll} disabled={processing}>
                  Recalculate
                </Button>
                <Button onClick={handleApprove} disabled={processing}>
                  Approve
                </Button>
              </>
            )}
            {isApproved && (
              <>
                <Button variant="outline" onClick={handleUnapprove} disabled={processing}>
                  Roll Back Approval
                </Button>
                <Button onClick={handleCommit} disabled={processing}>
                  {processing ? 'Committing...' : 'Commit & Finalize'}
                </Button>
              </>
            )}
          </div>
        }
      />

      <div className="p-4 space-y-6 sm:p-6 lg:p-8">
        {error && (
          <div className="p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}

        {/* Status Bar */}
        <div className="flex flex-wrap items-center gap-3">
          <Badge
            variant={
              isVoided ? 'danger' :
              isCommitted ? 'success' : isApproved ? 'info' : isCalculated ? 'warning' : 'default'
            }
          >
            {isVoided ? 'Voided' : statusConfig?.label || payPeriod.status}
          </Badge>
          {isCorrection && (
            <Badge variant="warning">Correction Run</Badge>
          )}
          {isCommitted && payPeriod.committed_at && (
            <span className="text-sm text-gray-500">
              Processed {formatGuamDateTime(payPeriod.committed_at)}
              {processedBy ? ` by ${processedBy}` : ''}
            </span>
          )}
          {isCommitted && syncConfig && (
            <>
              <Badge variant={syncConfig.variant}>
                {syncConfig.label}
              </Badge>
              {syncStatus === 'synced' && payPeriod.tax_synced_at && (
                <span className="text-sm text-gray-500">
                  Synced {formatGuamDateTime(payPeriod.tax_synced_at)}
                </span>
              )}
              {syncStatus === 'failed' && payPeriod.tax_sync_last_error && (
                <span className="text-sm text-red-600 max-w-md truncate" title={payPeriod.tax_sync_last_error}>
                  {payPeriod.tax_sync_last_error}
                </span>
              )}
              {canRetrySyncTax && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={handleRetryTaxSync}
                  disabled={retryingSyncTax}
                >
                  {retryingSyncTax ? 'Retrying...' : 'Retry Tax Sync'}
                </Button>
              )}
              {payPeriod.tax_sync_attempts != null && payPeriod.tax_sync_attempts > 0 && syncStatus !== 'synced' && (
                <span className="text-xs text-gray-400">
                  Attempt {payPeriod.tax_sync_attempts}/{MAX_SYNC_ATTEMPTS}
                </span>
              )}
            </>
          )}
        </div>

        {payDateCorrections.length > 0 && (
          <Card className="border-amber-200 bg-amber-50">
            <CardContent className="space-y-4 py-4">
              <div>
                <h3 className="text-base font-semibold text-amber-950">Pay Date Corrections</h3>
                <p className="mt-1 text-sm text-amber-800">
                  Date-only corrections made after this payroll was committed. Payroll dollar amounts were not changed.
                </p>
              </div>
              <div className="divide-y divide-amber-200 rounded-md border border-amber-200 bg-white/70">
                {payDateCorrections.map((correction) => (
                  <div key={correction.id} className="space-y-2 p-4">
                    <div className="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between">
                      <p className="text-sm font-medium text-gray-900">
                        Pay date changed from {formatCorrectionPayDate(correction.old_pay_date)} to {formatCorrectionPayDate(correction.new_pay_date)}
                      </p>
                      <p className="text-xs text-gray-500">
                        {formatGuamDateTime(correction.corrected_at)}
                        {correction.corrected_by_name ? ` by ${correction.corrected_by_name}` : ''}
                      </p>
                    </div>
                    <div>
                      <p className="text-xs font-medium uppercase tracking-wider text-amber-700">Reason</p>
                      <p className="mt-1 whitespace-pre-wrap text-sm text-gray-700">
                        {correction.reason || 'No reason recorded'}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}

        <Card>
          <div className="border-b px-4 py-3">
            <h3 className="text-base font-semibold text-gray-900">Processing Timeline</h3>
            <p className="text-sm text-gray-500">
              Guam timestamps for payroll lifecycle and operator actions.
            </p>
          </div>
          <div className="grid gap-0 divide-y divide-gray-100 sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-[repeat(auto-fit,minmax(11rem,1fr))]">
            {lifecycleItems.map((item) => (
              <div key={item.label} className="min-w-0 p-4">
                <div className="mb-2 flex items-center gap-2">
                  <Badge variant={item.timestamp ? item.tone : 'outline'}>
                    {item.label}
                  </Badge>
                </div>
                <p className="text-sm font-medium text-gray-900">
                  {item.timestamp ? formatGuamDateTime(item.timestamp) : 'Not recorded'}
                </p>
                <p className={`mt-1 text-xs ${item.timestamp ? 'text-gray-500' : 'text-gray-400'}`}>
                  {item.timestamp ? item.actor : 'No audit timestamp yet'}
                </p>
              </div>
            ))}
          </div>
        </Card>

        {/* Summary Cards */}
        {payrollItems.length > 0 && (
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5 lg:gap-4">
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Employees</p>
                <p className="mt-1 text-2xl font-semibold text-gray-900">{payrollItems.length}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Gross Pay</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-gray-900 sm:text-2xl">{formatCurrency(totalGross)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Total Taxes</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-red-600 sm:text-2xl">{formatCurrency(totalDeductions)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Net Pay</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-green-600 sm:text-2xl">{formatCurrency(totalNet)}</p>
              </CardContent>
            </Card>
            <Card className="border-amber-200 bg-amber-50">
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-amber-700 uppercase tracking-wider">DRT Deposit</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-amber-800 sm:text-2xl">{formatCurrency(totalDRTDeposit)}</p>
              </CardContent>
            </Card>
            {contractorItems.length > 0 && (
              <Card className="border-emerald-200 bg-emerald-50">
                <CardContent className="pt-5 pb-4">
                  <p className="text-xs font-medium text-emerald-700 uppercase tracking-wider">1099 Contractors ({contractorItems.length})</p>
                  <p className="mt-1 wrap-break-word text-xl font-semibold text-emerald-800 sm:text-2xl">{formatCurrency(totalContractorPay)}</p>
                </CardContent>
              </Card>
            )}
          </div>
        )}

        {/* Previous Period Comparison */}
        {payrollItems.length > 0 && payPeriod.cycle !== 'supplemental' && (isCalculated || isApproved || isCommitted) && (
          <Card className="border-blue-100 bg-blue-50/40">
            <CardContent className="space-y-4 py-5">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <h3 className="text-base font-semibold text-gray-900">Previous Pay Period Comparison</h3>
                  <p className={`mt-1 text-sm ${comparisonError ? 'text-red-700' : 'text-gray-600'}`}>
                    {comparisonError
                      ? 'Comparison failed to load. Retry before approving this payroll.'
                      : comparison?.previous_pay_period
                        ? `Compared with ${formatDateRange(comparison.previous_pay_period.start_date, comparison.previous_pay_period.end_date)} · Pay date ${formatDate(comparison.previous_pay_period.pay_date)}`
                        : comparisonLoading ? 'Loading previous period comparison…' : 'No previous committed pay period found for this company.'}
                  </p>
                </div>
                {comparison && (
                  <Badge className={comparisonFlagTone}>
                    {comparison.review_flags.message}
                  </Badge>
                )}
              </div>

              {comparisonError ? (
                <div className="flex flex-col gap-3 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 sm:flex-row sm:items-center sm:justify-between">
                  <span>Unable to load comparison data: {comparisonError}</span>
                  <Button variant="outline" size="sm" onClick={() => loadComparison(payPeriod.id)} disabled={comparisonLoading}>
                    Retry comparison
                  </Button>
                </div>
              ) : comparisonLoading ? (
                <p className="text-sm text-gray-500">Loading comparison…</p>
              ) : comparison?.previous_pay_period ? (
                <>
                  <div className="overflow-x-auto pb-1">
                    <div className="grid min-w-[58rem] grid-cols-6 gap-3">
                      {comparisonHighlights.map((metric) => {
                      const isCount = metric.key === 'employee_count';
                      const deltaClass = metric.delta > 0 ? 'text-emerald-700' : metric.delta < 0 ? 'text-red-700' : 'text-gray-500';
                      return (
                        <div key={metric.key} className="rounded-xl border border-white/70 bg-white px-3 py-3 shadow-sm">
                          <p className="text-[11px] font-semibold uppercase tracking-[0.08em] text-gray-500">{comparisonMetricLabels[metric.key]}</p>
                          <p className="mt-1 text-lg font-semibold text-gray-900">
                            {isCount ? metric.current : formatCurrency(metric.current)}
                          </p>
                          <p className={`mt-0.5 text-xs font-medium ${deltaClass}`}>
                            {isCount ? formatSignedNumber(metric.delta) : formatSignedCurrency(metric.delta)}
                            {metric.percent_delta !== null && ` · ${metric.percent_delta > 0 ? '+' : ''}${metric.percent_delta}%`}
                          </p>
                        </div>
                      );
                      })}
                    </div>
                  </div>

                  {comparisonRows.length > 0 ? (
                    <div className="space-y-2">
                      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-gray-600">
                        <span>
                          Showing {comparisonRows.length} of {comparisonTotalRows} flagged employee{comparisonTotalRows === 1 ? '' : 's'}.
                        </span>
                        {comparisonHiddenRows > 0 && (
                          <span className="font-medium text-amber-700">
                            {comparisonHiddenRows} more flagged employee{comparisonHiddenRows === 1 ? '' : 's'} not shown in this summary.
                          </span>
                        )}
                      </div>
                      <div className="overflow-x-auto rounded-xl border border-blue-100 bg-white">
                        <table className="min-w-[64rem] w-full text-sm">
                        <thead className="bg-blue-50 text-xs uppercase tracking-wide text-blue-900">
                          <tr>
                            <th className="whitespace-nowrap px-3 py-2 text-left font-semibold">Review item</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Gross Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Net Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Tips Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Loan Ded. Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Loan Pmt. Δ</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-blue-50">
                          {comparisonRows.map((row) => (
                            <tr key={`${row.employee_id}-${row.change_type}`}>
                              <td className="px-3 py-2">
                                <div className="font-medium text-gray-900">{row.employee_name}</div>
                                <div className="mt-1 flex flex-wrap gap-1">
                                  {row.flags.slice(0, 3).map((flag) => (
                                    <span key={flag.key} className={`rounded-full px-2 py-0.5 text-xs font-medium ${flag.severity === 'warning' ? 'bg-red-50 text-red-700' : 'bg-amber-50 text-amber-700'}`}>
                                      {flag.message}
                                    </span>
                                  ))}
                                </div>
                              </td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.gross_pay?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.net_pay?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.reported_tips?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.loan_deduction?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.loan_payment?.delta || 0)}</td>
                            </tr>
                          ))}
                        </tbody>
                        </table>
                      </div>
                    </div>
                  ) : (
                    <div className="rounded-xl border border-emerald-100 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
                      No material employee-level changes detected against the previous committed period.
                    </div>
                  )}
                </>
              ) : null}
            </CardContent>
          </Card>
        )}

        {/* Missing Employees Warning */}
        {isCalculated && (() => {
          const payrollEmployeeIds = new Set(payrollItems.map((pi) => pi.employee_id));
          const excludedEmployeeIds = new Set(payPeriod.excluded_employee_ids || []);
          const missingEmployees = employees.filter((emp) => !payrollEmployeeIds.has(emp.id) && !excludedEmployeeIds.has(emp.id));
          if (missingEmployees.length === 0) return null;
          return (
            <div className="p-4 bg-amber-50 border border-amber-200 rounded-lg">
              <div className="flex items-start justify-between">
                <div>
                  <p className="font-medium text-amber-800">
                    {missingEmployees.length} active employee{missingEmployees.length !== 1 ? 's' : ''} not included in this payroll:
                  </p>
                  <ul className="mt-2 text-sm text-amber-700 space-y-1">
                    {missingEmployees.map((emp) => (
                      <li key={emp.id} className="flex items-center gap-2">
                        <span>{emp.first_name} {emp.last_name}</span>
                        <span className="text-amber-500 text-xs">({emp.employment_type})</span>
                        {additionalEmployeeIds.has(emp.id) ? (
                          <span className="text-xs text-green-600 font-medium">Added — enter hours below, then Recalculate</span>
                        ) : (
                          <button
                            onClick={() => {
                              setAdditionalEmployeeIds(prev => { const next = new Set(prev); next.add(emp.id); return next; });
                              setHoursMap(prev => ({
                                ...prev,
                                [String(emp.id)]: { regular: 0, overtime: 0, wage_rates: prev[String(emp.id)]?.wage_rates },
                              }));
                            }}
                            className="text-xs text-blue-600 hover:text-blue-800 hover:underline font-medium"
                          >
                            Include in Payroll
                          </button>
                        )}
                      </li>
                    ))}
                  </ul>
                </div>
                {additionalEmployeeIds.size > 0 && (
                  <Button size="sm" variant="outline" onClick={handleRunPayroll} disabled={processing}>
                    Recalculate with {additionalEmployeeIds.size} added
                  </Button>
                )}
              </div>
              <p className="mt-2 text-xs text-amber-600">
                These employees were not in the imported payroll data. Click &quot;Include in Payroll&quot; then Recalculate to add them.
              </p>
            </div>
          );
        })()}

        {/* Hours Input (Draft Mode) */}
        {(isDraft || isCalculated) && (
          <Card>
            <div
              role="button"
              tabIndex={0}
              className="w-full border-b p-4 text-left transition-colors hover:bg-gray-50/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-300 focus-visible:ring-inset"
              onClick={() => setHoursTableOpen(prev => !prev)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault();
                  setHoursTableOpen(prev => !prev);
                }
              }}
            >
              <div className="flex items-start justify-between gap-4">
                <div className="flex items-center gap-2">
                  <svg
                    className={`w-4 h-4 text-gray-500 transition-transform ${hoursTableOpen ? 'rotate-90' : ''}`}
                    fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}
                  >
                    <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
                  </svg>
                  <div>
                    <h3 className="font-semibold text-gray-900">
                      {isCalculated ? 'Adjust Hours' : 'Enter Hours'}
                    </h3>
                    {!hoursTableOpen && (
                      <p className="text-xs text-gray-400 mt-0.5">Click to expand</p>
                    )}
                  </div>
                </div>
                {hoursTableOpen && (
                  <div className="flex items-center gap-3 shrink-0" onClick={(e) => e.stopPropagation()}>
                    <Select
                      value={employeeTypeFilter}
                      onChange={(event) => setEmployeeTypeFilter(event.target.value as typeof employeeTypeFilter)}
                      className="w-36"
                    >
                      <option value="all">All Types</option>
                      <option value="salary">Salary</option>
                      <option value="hourly">Hourly</option>
                      <option value="contractor">1099</option>
                    </Select>
                    <Select
                      value={departmentFilter}
                      onChange={(event) => setDepartmentFilter(event.target.value)}
                      className="w-44"
                    >
                      <option value="all">All Departments</option>
                      {departmentOptions.map(([deptId, deptName]) => (
                        <option key={deptId} value={deptId}>{deptName}</option>
                      ))}
                    </Select>
                    <Select
                      value={`${hoursSortBy}:${hoursSortDirection}`}
                      onChange={(event) => {
                        const [sortBy, direction] = event.target.value.split(':') as [typeof hoursSortBy, typeof hoursSortDirection];
                        setHoursSortBy(sortBy);
                        setHoursSortDirection(direction);
                      }}
                      className="w-44"
                    >
                      <option value="name:asc">Name A-Z</option>
                      <option value="name:desc">Name Z-A</option>
                      <option value="rate:desc">Rate High-Low</option>
                      <option value="rate:asc">Rate Low-High</option>
                      <option value="hours:desc">Hours High-Low</option>
                      <option value="hours:asc">Hours Low-High</option>
                      <option value="gross:desc">Est. Gross High-Low</option>
                      <option value="gross:asc">Est. Gross Low-High</option>
                    </Select>
                    <button
                      type="button"
                      onClick={(event) => {
                        event.preventDefault();
                        event.stopPropagation();
                        tipsLoansVisibilityModeRef.current = 'manual';
                        setShowTipsLoans(prev => !prev);
                      }}
                      className={`text-xs font-medium px-2.5 py-1 rounded-full border transition-colors ${
                        showTipsLoans
                          ? 'bg-blue-100 text-blue-700 border-blue-300'
                          : 'bg-gray-100 text-gray-500 border-gray-200 hover:bg-gray-200'
                      }`}
                    >
                      {showTipsLoans ? 'Tips & Deductions ✓' : '+ Tips & Deductions'}
                    </button>
                        <div className="relative">
                          <input
                            type="text"
                            placeholder="Search employees..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                        className="w-48 border border-gray-300 rounded-lg pl-8 pr-3 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                      />
                      <svg className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                      </svg>
                    </div>
                  </div>
                )}
              </div>
            </div>
            {hoursTableOpen && (
            <div className="overflow-x-auto">
              <Table
                stickyHeader
                containerClassName="max-h-[32rem]"
                style={{ minWidth: 1380 + (showTipsLoans ? 420 : 0) }}
              >
                <TableHeader>
                  <TableRow>
                    <TableHead stickyLeft className={`w-[260px] min-w-[260px] bg-gray-50 ${TABLE_STICKY_TOP_CLASS}`}>Employee</TableHead>
                    <TableHead className={`w-[300px] bg-gray-50 ${TABLE_STICKY_TOP_CLASS}`}>Rate</TableHead>
                    <TableHead className={`w-[300px] bg-gray-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Regular Hours</TableHead>
                    <TableHead className={`w-[300px] bg-gray-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Overtime Hours</TableHead>
                    {showTipsLoans && <TableHead className={`w-[190px] min-w-[190px] bg-gray-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Tips</TableHead>}
                    {showTipsLoans && <TableHead className={`w-[150px] min-w-[150px] bg-gray-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Tips Pd Out</TableHead>}
                    {showTipsLoans && <TableHead className={`w-[150px] min-w-[150px] bg-gray-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Loan Ded.</TableHead>}
                    <TableHead className={`w-[160px] bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Est. Gross</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(() => {
                    const payrollEmployeeIds = new Set(payrollItems.map((pi) => pi.employee_id));
                    const draftDividerCols = 5 + (showTipsLoans ? 3 : 0);
                    const filtered = isCalculated
                      ? employees.filter((emp) => payrollEmployeeIds.has(emp.id) || additionalEmployeeIds.has(emp.id))
                      : employees;
                    const displayEmployees = [...filtered]
                      .filter((emp) => matchesEmployeeFilters(
                        emp.employment_type,
                        [`${emp.first_name} ${emp.last_name}`, `${emp.last_name}, ${emp.first_name}`, emp.department?.name || ''],
                        emp.department_id
                      ))
                      .sort((a, b) => {
                        const orderDiff = employeeTypeFilter === 'all'
                          ? (typeOrder[a.employment_type] ?? 9) - (typeOrder[b.employment_type] ?? 9)
                          : 0;
                        if (orderDiff !== 0) return orderDiff;

                        if (hoursSortBy === 'rate') {
                          return compareDirectional(toNumber(a.pay_rate), toNumber(b.pay_rate), hoursSortDirection);
                        }

                        if (hoursSortBy === 'hours') {
                          const aHours = toNumber(hoursMap[String(a.id)]?.regular) + toNumber(hoursMap[String(a.id)]?.overtime);
                          const bHours = toNumber(hoursMap[String(b.id)]?.regular) + toNumber(hoursMap[String(b.id)]?.overtime);
                          return compareDirectional(aHours, bHours, hoursSortDirection);
                        }

                        if (hoursSortBy === 'gross') {
                          const estimateGross = (employee: Employee) => {
                            const entry = hoursMap[String(employee.id)] || { regular: 0, overtime: 0 };
                            const rate = toNumber(employee.pay_rate);
                            const isHourlyContractor = employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly';
                            const isFlatContractor = employee.employment_type === 'contractor' && employee.contractor_pay_type !== 'hourly';
                            const activeRates = (entry.wage_rates || []).filter((row) => row.active !== false);
                            const usesMultipleRates = (employee.employment_type === 'hourly' || isHourlyContractor) && activeRates.length > 1;
                            const variableSalary = employee.employment_type === 'salary' && employee.salary_type === 'variable';
                            const perPeriodSalary = employee.employment_type === 'salary' && employee.salary_type === 'per_period';
                            const periodsPerYear = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[employee.pay_frequency] || 26;
                            const override = salaryOverrideMap[String(employee.id)] || 0;

                            if (variableSalary) return override;
                            if (perPeriodSalary) return rate;
                            if (employee.employment_type === 'salary') return rate / periodsPerYear;
                            if (isFlatContractor) return rate;
                            if (usesMultipleRates) {
                              return activeRates.reduce(
                                (sum, row) => sum + (toNumber(row.regular_hours) * toNumber(row.rate)) + (toNumber(row.overtime_hours) * toNumber(row.rate) * 1.5),
                                0
                              );
                            }

                            return (toNumber(entry.regular) * rate) + (toNumber(entry.overtime) * rate * 1.5);
                          };

                          return compareDirectional(estimateGross(a), estimateGross(b), hoursSortDirection);
                        }

                        return compareDirectional(
                          `${a.last_name} ${a.first_name}`,
                          `${b.last_name} ${b.first_name}`,
                          hoursSortDirection
                        );
                      });
                    let prevType: string | null = null;
                    return displayEmployees.map((emp, rowIndex) => {
                      const showDivider = emp.employment_type !== prevType;
                      prevType = emp.employment_type;
                      const hours = hoursMap[String(emp.id)] || { regular: 0, overtime: 0 };
                      const payRate = toNumber(emp.pay_rate);
                      const isContractorHourly = emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly';
                      const isContractorFlat = emp.employment_type === 'contractor' && emp.contractor_pay_type !== 'hourly';
                      const activeWageRates = (hours.wage_rates || []).filter((rate) => rate.active !== false);
                      const hasMultiRate = (emp.employment_type === 'hourly' || isContractorHourly) && activeWageRates.length > 1;
                      const isVariableSalary = emp.employment_type === 'salary' && emp.salary_type === 'variable';
                      const isPerPeriodSalary = emp.employment_type === 'salary' && emp.salary_type === 'per_period';
                      const noHoursType = emp.employment_type === 'salary' || isContractorFlat;
                      const salaryOverride = salaryOverrideMap[String(emp.id)] || 0;
                      const periodsPerYear = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[emp.pay_frequency] || 26;
                      const rowTone = rowIndex % 2 === 0 ? 'bg-white' : 'bg-slate-100';
                      const estGross = isVariableSalary
                        ? salaryOverride
                        : isPerPeriodSalary
                        ? payRate
                        : emp.employment_type === 'salary'
                        ? payRate / periodsPerYear
                        : isContractorFlat
                        ? payRate
                        : hasMultiRate
                        ? activeWageRates.reduce(
                            (sum, rate) => sum + (toNumber(rate.regular_hours) * toNumber(rate.rate)) + (toNumber(rate.overtime_hours) * toNumber(rate.rate) * 1.5),
                            0
                          )
                        : (hours.regular * payRate) + (hours.overtime * payRate * 1.5);
                      return (
                      <Fragment key={emp.id}>
                      {showDivider && (
                        <TableRow className={emp.employment_type === 'contractor' ? 'bg-emerald-50' : emp.employment_type === 'hourly' ? 'bg-gray-100' : 'bg-indigo-50'}>
                          <TableCell stickyLeft colSpan={draftDividerCols} className={`py-1.5 text-xs font-semibold uppercase tracking-wider ${
                            emp.employment_type === 'contractor' ? 'text-emerald-700' : emp.employment_type === 'hourly' ? 'text-gray-600' : 'text-indigo-700'
                          } ${emp.employment_type === 'contractor' ? 'bg-emerald-50' : emp.employment_type === 'hourly' ? 'bg-gray-100' : 'bg-indigo-50'}`}>
                            {emp.employment_type === 'contractor' ? '1099 Contractors' : emp.employment_type === 'hourly' ? 'Hourly Employees' : 'Salary Employees'}
                          </TableCell>
                        </TableRow>
                      )}
                      <TableRow className={rowTone}>
                          <TableCell stickyLeft className={`min-w-[260px] ${rowTone}`}>
                          <div>
                            <div className="flex items-center gap-1.5">
                              <p className="font-medium text-gray-900">{emp.first_name} {emp.last_name}</p>
                              {additionalEmployeeIds.has(emp.id) && (
                                <span className="text-[10px] font-medium text-blue-700 bg-blue-100 rounded-full px-1.5 py-0.5">New</span>
                              )}
                            </div>
                            <p className="text-xs text-gray-500 capitalize">
                              {isContractorHourly ? '1099 (Hourly)' : isContractorFlat ? '1099 (Flat Fee)' : emp.employment_type}
                              {emp.department?.name ? ` · ${emp.department.name}` : ''}
                            </p>
                          </div>
                        </TableCell>
                        <TableCell className={`text-gray-700 ${rowTone}`}>
                          {isVariableSalary ? (
                            <span className="text-indigo-600 font-medium">Variable</span>
                          ) : isPerPeriodSalary ? (
                            `${formatCurrency(payRate)}/period`
                          ) : emp.employment_type === 'salary' ? (
                            `${formatCurrency(payRate / periodsPerYear)}/period`
                          ) : isContractorFlat ? (
                            `${formatCurrency(payRate)}/period`
                          ) : hasMultiRate ? (
                            <div className="space-y-1 text-left">
                              {activeWageRates.map((rate) => (
                                <div key={`${emp.id}-${rate.label}`} className="text-xs">
                                  <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                                  <span className="text-gray-500">{formatCurrency(toNumber(rate.rate))}/hr</span>
                                </div>
                              ))}
                            </div>
                          ) : (
                            `${formatCurrency(payRate)}/hr`
                          )}
                        </TableCell>
                        <TableCell className={`text-center align-top ${rowTone}`} colSpan={isVariableSalary ? 2 : 1}>
                          {isVariableSalary ? (
                            <div className="flex items-center justify-center gap-2">
                              <span className="text-xs text-gray-500">Pay this period: $</span>
                              <NumericInput
                                value={salaryOverride || null}
                                onValueChange={(value) => updateSalaryOverride(emp.id, value ?? 0)}
                                placeholder="0.00"
                                className="w-28 text-center border border-indigo-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 bg-indigo-50/50"
                                min={0}
                                fixedDecimalsOnBlur={2}
                              />
                            </div>
                          ) : hasMultiRate ? (
                            <div className="space-y-2">
                              {activeWageRates.map((rate, index) => (
                                <div key={`${emp.id}-${rate.label}-regular`} className="grid grid-cols-[12rem_5rem] items-center gap-3">
                                  <span
                                    className="text-left text-xs leading-tight text-gray-500 whitespace-nowrap"
                                    title={rate.label}
                                  >
                                    {rate.label}
                                  </span>
                                  <NumericInput
                                    value={toNumber(rate.regular_hours)}
                                    onValueChange={(value) => updateWageRateHours(emp.id, index, 'regular_hours', value ?? 0)}
                                    className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                                    min={0}
                                    max={MAX_HOURS_PER_PERIOD}
                                  />
                                </div>
                              ))}
                            </div>
                          ) : (
                            <NumericInput
                              value={hours.regular}
                              onValueChange={(value) => updateHours(emp.id, 'regular', value ?? 0)}
                              className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 disabled:text-gray-400"
                              min={0}
                              max={MAX_HOURS_PER_PERIOD}
                              disabled={noHoursType}
                            />
                          )}
                        </TableCell>
                        {!isVariableSalary && (
                        <TableCell className={`text-center align-top ${rowTone}`}>
                          {hasMultiRate ? (
                            <div className="space-y-2">
                              {activeWageRates.map((rate, index) => (
                                <div key={`${emp.id}-${rate.label}-overtime`} className="grid grid-cols-[12rem_5rem] items-center gap-3">
                                  <span
                                    className="text-left text-xs leading-tight text-gray-500 whitespace-nowrap"
                                    title={rate.label}
                                  >
                                    {rate.label}
                                  </span>
                                  <NumericInput
                                    value={toNumber(rate.overtime_hours)}
                                    onValueChange={(value) => updateWageRateHours(emp.id, index, 'overtime_hours', value ?? 0)}
                                    className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                                    min={0}
                                    max={MAX_HOURS_PER_PERIOD}
                                  />
                                </div>
                              ))}
                            </div>
                          ) : (
                            <NumericInput
                              value={hours.overtime}
                              onValueChange={(value) => updateHours(emp.id, 'overtime', value ?? 0)}
                              className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 disabled:text-gray-400"
                              min={0}
                              max={MAX_HOURS_PER_PERIOD}
                              disabled={noHoursType}
                            />
                          )}
                        </TableCell>
                        )}
                        {showTipsLoans && (
                        <TableCell className={`min-w-[190px] text-center align-top ${rowTone}`}>
                          <div className="flex min-w-[160px] items-center justify-center gap-2">
                            <span className="text-xs text-gray-400">$</span>
                            <NumericInput
                              value={tipsMap[String(emp.id)]?.amount ?? null}
                              onValueChange={(value) => updateTip(emp.id, value ?? 0)}
                              placeholder="0"
                              className="w-24 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                              min={0}
                              fixedDecimalsOnBlur={2}
                            />
                            <select
                              value={tipsMap[String(emp.id)]?.pool || ''}
                              onChange={(e) => updateTip(emp.id, tipsMap[String(emp.id)]?.amount || 0, e.target.value)}
                              className="w-20 border border-gray-300 rounded-md px-2 py-1.5 text-xs focus:ring-2 focus:ring-blue-500 focus:border-blue-500 bg-white"
                            >
                              <option value="">—</option>
                              <option value="foh">FOH</option>
                              <option value="boh">BOH</option>
                              <option value="mixed">Mixed</option>
                            </select>
                          </div>
                        </TableCell>
                        )}
                        {showTipsLoans && (
                        <TableCell className={`min-w-[150px] text-center align-top ${rowTone}`}>
                          <div className="flex min-w-[120px] items-center justify-center gap-2">
                            <span className="text-xs text-gray-400">$</span>
                            <NumericInput
                              value={tipsPaidOutMap[String(emp.id)] ?? null}
                              onValueChange={(value) => updateTipsPaidOut(emp.id, value ?? 0)}
                              placeholder="0"
                              className="w-24 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                              min={0}
                              fixedDecimalsOnBlur={2}
                            />
                          </div>
                        </TableCell>
                        )}
                        {showTipsLoans && (
                        <TableCell className={`min-w-[150px] text-center align-top ${rowTone}`}>
                          <div className="flex min-w-[120px] items-center justify-center gap-2">
                            <span className="text-xs text-gray-400">$</span>
                            <NumericInput
                              value={loansMap[String(emp.id)] ?? null}
                              onValueChange={(value) => updateLoan(emp.id, value ?? 0)}
                              placeholder="0"
                              className="w-24 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                              min={0}
                              fixedDecimalsOnBlur={2}
                            />
                          </div>
                        </TableCell>
                        )}
                        <TableCell className={`text-right font-medium text-gray-700 ${rowTone}`}>
                          {formatCurrency(estGross)}
                        </TableCell>
                      </TableRow>
                      </Fragment>
                      );
                    });
                  })()}
                </TableBody>
              </Table>
            </div>
            )}
          </Card>
        )}

        {/* Payroll Results Table (Calculated/Approved/Committed) */}
        {!isDraft && payrollItems.length > 0 && (() => {
          const hasTips = payrollItems.some(i => toNumber(i.reported_tips) > 0);
          const hasTipsPaidOut = payrollItems.some(i => toNumber(i.tips_paid_out) > 0);
          const hasLoans = payrollItems.some(i => effectiveLoanDeduction(i) > 0);
          const hasCustomEarnings = payrollItems.some(i => (i.custom_earnings || []).some((earning) => toNumber(earning.amount) > 0));
          const hasCustomDeductions = payrollItems.some(i => (i.custom_deductions || []).some((deduction) => toNumber(deduction.amount) > 0));
          const hasPayrollAdjustments = payrollItems.some(i => (i.payroll_adjustments || []).some((adjustment) => adjustment.active !== false && toNumber(adjustment.amount) > 0));
          const extraColCount = (hasCustomEarnings ? 1 : 0) + (hasCustomDeductions ? 1 : 0) + (hasPayrollAdjustments ? 1 : 0) + (hasTips ? 1 : 0) + (hasTipsPaidOut ? 1 : 0) + (hasLoans ? 1 : 0);
          const totalCols = 10 + extraColCount + (isCalculated || isCommitted ? 1 : 0);
          return (
          <Card>
            <div className="p-4 border-b">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h3 className="font-semibold text-gray-900">Employee Payroll</h3>
                  <p className="text-sm text-gray-500 mt-1">
                    Salary employees listed first, then hourly alphabetically.
                  </p>
                </div>
                <div className="flex shrink-0 flex-wrap items-center gap-3">
                  <Select
                    value={employeeTypeFilter}
                    onChange={(event) => setEmployeeTypeFilter(event.target.value as typeof employeeTypeFilter)}
                    className="w-36"
                  >
                    <option value="all">All Types</option>
                    <option value="salary">Salary</option>
                    <option value="hourly">Hourly</option>
                    <option value="contractor">1099</option>
                  </Select>
                  <Select
                    value={departmentFilter}
                    onChange={(event) => setDepartmentFilter(event.target.value)}
                    className="w-44"
                  >
                    <option value="all">All Departments</option>
                    {departmentOptions.map(([deptId, deptName]) => (
                      <option key={deptId} value={deptId}>{deptName}</option>
                    ))}
                  </Select>
                  <Select
                    value={`${resultsSortBy}:${resultsSortDirection}`}
                    onChange={(event) => {
                      const [sortBy, direction] = event.target.value.split(':') as [typeof resultsSortBy, typeof resultsSortDirection];
                      setResultsSortBy(sortBy);
                      setResultsSortDirection(direction);
                    }}
                    className="w-44"
                  >
                    <option value="name:asc">Name A-Z</option>
                    <option value="name:desc">Name Z-A</option>
                    <option value="rate:desc">Rate High-Low</option>
                    <option value="rate:asc">Rate Low-High</option>
                    <option value="hours:desc">Hours High-Low</option>
                    <option value="hours:asc">Hours Low-High</option>
                    <option value="gross:desc">Gross High-Low</option>
                    <option value="gross:asc">Gross Low-High</option>
                    <option value="net:desc">Net High-Low</option>
                    <option value="net:asc">Net Low-High</option>
                    <option value="fit:desc">FIT High-Low</option>
                    <option value="fit:asc">FIT Low-High</option>
                  </Select>
                  <div className="relative">
                    <input
                      type="text"
                      placeholder="Search employees and checks..."
                      value={searchTerm}
                      onChange={(e) => setSearchTerm(e.target.value)}
                      className="w-56 border border-gray-300 rounded-lg pl-8 pr-3 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                    />
                    <svg className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                    </svg>
                  </div>
                </div>
              </div>
            </div>
            <div className="overflow-x-auto">
              <Table stickyHeader containerClassName="max-h-[34rem]" className="min-w-[1640px]">
                <TableHeader>
                  <TableRow>
                    <TableHead stickyLeft className={`w-[260px] min-w-[260px] bg-gray-50 ${TABLE_STICKY_TOP_CLASS}`}>Employee</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Hours</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Rate</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Gross</TableHead>
                    {hasCustomEarnings && <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Custom Earn.</TableHead>}
                    {hasCustomDeductions && <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Custom Ded.</TableHead>}
                    {hasPayrollAdjustments && <TableHead className={`min-w-[180px] bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Adjustments</TableHead>}
                    {hasTips && <TableHead className={`min-w-[130px] bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Tips</TableHead>}
                    {hasTipsPaidOut && <TableHead className={`min-w-[130px] bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Tips Pd Out</TableHead>}
                    {hasLoans && <TableHead className={`min-w-[130px] bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Loan Ded.</TableHead>}
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>FIT</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Addtl W/H</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>SS (6.2%)</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Medicare</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Total Ded.</TableHead>
                    <TableHead className={`bg-gray-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Net Pay</TableHead>
                    {(isCalculated || isCommitted) && <TableHead className="text-center w-20"></TableHead>}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(() => {
                    const displayItems = sortPayrollItems;
                    return displayItems.map((item, idx) => {
                    const isManual = !item.import_source;
                    const isSalary = item.employment_type === 'salary';
                    const isContractor = item.employment_type === 'contractor';
                    const empRecord = employeeLookup.get(item.employee_id);
                    const isContractorHourly = isContractor && empRecord?.contractor_pay_type === 'hourly';
                    const isContractorFlat = isContractor && empRecord?.contractor_pay_type !== 'hourly';
                    const itemWageRates = (item.wage_rate_hours || []).filter((rate) => rate.active !== false);
                    const hasMultiRateResults = (item.employment_type === 'hourly' || isContractorHourly) && itemWageRates.length > 1;
                    const prevType = idx > 0 ? displayItems[idx - 1]?.employment_type : null;
                    const showSalaryDivider = isSalary && idx === 0;
                    const showHourlyDivider = item.employment_type === 'hourly' && prevType !== 'hourly';
                    const showContractorDivider = isContractor && prevType !== 'contractor';
                    const rowTone = idx % 2 === 0 ? 'bg-white' : 'bg-slate-100';

                    return (
                      <Fragment key={item.id}>
                        {showSalaryDivider && (
                          <TableRow className="bg-indigo-50">
                            <TableCell stickyLeft colSpan={totalCols} className="bg-indigo-50 py-1.5 text-xs font-semibold text-indigo-700 uppercase tracking-wider">
                              Salary Employees
                            </TableCell>
                          </TableRow>
                        )}
                        {showHourlyDivider && (
                          <TableRow className="bg-gray-100">
                            <TableCell stickyLeft colSpan={totalCols} className="bg-gray-100 py-1.5 text-xs font-semibold text-gray-600 uppercase tracking-wider">
                              Hourly Employees
                            </TableCell>
                          </TableRow>
                        )}
                        {showContractorDivider && (
                          <TableRow className="bg-emerald-50">
                            <TableCell stickyLeft colSpan={totalCols} className="bg-emerald-50 py-1.5 text-xs font-semibold text-emerald-700 uppercase tracking-wider">
                              1099 Contractors
                            </TableCell>
                          </TableRow>
                        )}
                        <TableRow key={item.id} className={rowTone}>
                          <TableCell stickyLeft className={`min-w-[260px] ${rowTone}`}>
                            <div className="flex items-center gap-2">
                              <div>
                                <p className="font-medium text-gray-900">{item.employee_name}</p>
                                {(item.department_name || empRecord?.department?.name) && (
                                  <p className="mt-0.5 text-xs text-gray-500">
                                    {item.department_name || empRecord?.department?.name}
                                  </p>
                                )}
                                <div className="flex items-center gap-1.5 mt-0.5">
                                  {isSalary && (
                                    <span className="inline-flex items-center rounded-full bg-indigo-100 px-1.5 py-0.5 text-[10px] font-medium text-indigo-700">
                                      Salary
                                    </span>
                                  )}
                                  {isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-emerald-100 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700">
                                      1099
                                    </span>
                                  )}
                                  {hasMultiRateResults && (
                                    <span className="inline-flex items-center rounded-full bg-blue-100 px-1.5 py-0.5 text-[10px] font-medium text-blue-700">
                                      Multi-rate
                                    </span>
                                  )}
                                  {(isManual || (isSalary && item.salary_override)) && !isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700">
                                      Manual
                                    </span>
                                  )}
                                  {item.withholding_tax_adjustment != null && toNumber(item.withholding_tax_adjustment) !== 0 && (
                                    <span className="inline-flex items-center rounded-full bg-orange-100 px-1.5 py-0.5 text-[10px] font-medium text-orange-700" title={`FIT adjusted by ${formatCurrency(toNumber(item.withholding_tax_adjustment))} for this pay period`}>
                                      FIT Adj
                                    </span>
                                  )}
                                  {item.withholding_tax_override != null && (
                                    <span className="inline-flex items-center rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700" title="Final FIT manually overridden for this pay period">
                                      FIT Override
                                    </span>
                                  )}
                                  {toNumber(item.additional_withholding) > 0 && (
                                    <span className="inline-flex items-center rounded-full bg-purple-100 px-1.5 py-0.5 text-[10px] font-medium text-purple-700" title={item.additional_withholding_override != null ? `W-4 Step 4(c) overridden for this pay period: ${formatCurrency(toNumber(item.additional_withholding))}` : `W-4 Step 4(c) extra withholding for this pay period: ${formatCurrency(toNumber(item.additional_withholding))}`}>
                                      +{formatCurrency(toNumber(item.additional_withholding))} W/H
                                    </span>
                                  )}
                                  {empRecord?.w4_step2_multiple_jobs && (
                                    <span className="inline-flex items-center rounded-full bg-sky-100 px-1.5 py-0.5 text-[10px] font-medium text-sky-700" title="W-4 Step 2: Two jobs or spouse works">
                                      Step 2
                                    </span>
                                  )}
                                </div>
                              </div>
                            </div>
                          </TableCell>
                          <TableCell className={`text-right ${rowTone}`}>
                            {isSalary || isContractorFlat ? (
                              <span className="text-gray-400">—</span>
                            ) : hasMultiRateResults ? (
                              <div className="space-y-1 text-left inline-block">
                                {itemWageRates.map((rate) => {
                                  const totalHours = toNumber(rate.regular_hours) + toNumber(rate.overtime_hours);
                                  return (
                                    <div key={`${item.id}-${rate.label}-hours`} className="text-xs">
                                      <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                                      <span className="text-gray-600">{totalHours}</span>
                                      {toNumber(rate.overtime_hours) > 0 && (
                                        <span className="text-orange-600 ml-1">({toNumber(rate.overtime_hours)} OT)</span>
                                      )}
                                    </div>
                                  );
                                })}
                              </div>
                            ) : (
                              <>
                                {item.hours_worked || 0}
                                {(item.overtime_hours || 0) > 0 && (
                                  <span className="text-orange-600 ml-1">+{item.overtime_hours} OT</span>
                                )}
                              </>
                            )}
                          </TableCell>
                          <TableCell className={`text-right ${rowTone}`}>
                            {(() => {
                              if (isSalary) {
                                const override = item.salary_override ? toNumber(item.salary_override) : 0;
                                if (override > 0) return <span className="text-indigo-600" title="Salary Override">{formatCurrency(override)}/period</span>;
                                if (empRecord?.salary_type === 'variable') return <span className="text-indigo-600 font-medium">Variable</span>;
                                const payRate = toNumber(item.pay_rate);
                                const isPerPeriod = empRecord?.salary_type === 'per_period';
                                if (isPerPeriod) return `${formatCurrency(payRate)}/period`;
                                const periodsPerYear = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[empRecord?.pay_frequency || ''] || 26;
                                return `${formatCurrency(payRate / periodsPerYear)}/period`;
                              }
                              if (isContractorFlat) {
                                const override = item.salary_override ? toNumber(item.salary_override) : 0;
                                if (override > 0) return <span className="text-emerald-600" title="Flat Fee Override">{formatCurrency(override)}/period</span>;
                                return <span className="text-emerald-600">{formatCurrency(toNumber(item.pay_rate))}/period</span>;
                              }
                              if (hasMultiRateResults) {
                                return (
                                  <div className="space-y-1 text-left inline-block">
                                    {itemWageRates.map((rate) => (
                                      <div key={`${item.id}-${rate.label}-rate`} className="text-xs">
                                        <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                                        <span className="text-gray-500">{formatCurrency(toNumber(rate.rate))}/hr</span>
                                      </div>
                                    ))}
                                  </div>
                                );
                              }
                              if (isContractorHourly) {
                                return `${formatCurrency(toNumber(item.pay_rate))}/hr`;
                              }
                              return `${formatCurrency(toNumber(item.pay_rate))}/hr`;
                            })()}
                          </TableCell>
                          <TableCell className={`text-right font-medium ${rowTone}`}>{formatCurrency(toNumber(item.gross_pay))}</TableCell>
                          {hasCustomEarnings && (
                          <TableCell className={`text-right ${rowTone}`}>
                            {(item.custom_earnings || []).some((earning) => toNumber(earning.amount) > 0) ? (
                              <div className="space-y-1">
                                {(item.custom_earnings || []).filter((earning) => toNumber(earning.amount) > 0).map((earning, index) => (
                                  <div key={`${item.id}-custom-earning-${index}-${earning.label}-${earning.amount}`} className="text-xs">
                                    <span className="text-gray-500">{earning.label}</span>{' '}
                                    <span className="font-medium text-gray-900">{formatCurrency(toNumber(earning.amount))}</span>
                                  </div>
                                ))}
                              </div>
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasCustomDeductions && (
                          <TableCell className={`text-right ${rowTone}`}>
                            {(item.custom_deductions || []).some((deduction) => toNumber(deduction.amount) > 0) ? (
                              <div className="space-y-1">
                                {(item.custom_deductions || []).filter((deduction) => toNumber(deduction.amount) > 0).map((deduction, index) => (
                                  <div key={`${item.id}-custom-deduction-${index}-${deduction.label}-${deduction.amount}`} className="text-xs">
                                    <span className="text-gray-500">{deduction.label}</span>{' '}
                                    <span className="font-medium text-red-600">{formatCurrency(toNumber(deduction.amount))}</span>
                                  </div>
                                ))}
                              </div>
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasPayrollAdjustments && (
                          <TableCell className={`text-right ${rowTone}`}>
                            {(item.payroll_adjustments || []).some((adjustment) => adjustment.active !== false && toNumber(adjustment.amount) > 0) ? (
                              <div className="space-y-1">
                                {(item.payroll_adjustments || []).filter((adjustment) => adjustment.active !== false && toNumber(adjustment.amount) > 0).map((adjustment, index) => {
                                  const isDeduction = adjustment.treatment === 'pre_tax_deduction' || adjustment.treatment === 'post_tax_deduction';
                                  return (
                                    <div key={`${item.id}-payroll-adjustment-${index}-${adjustment.label}-${adjustment.amount}`} className="text-xs">
                                      <span className="text-gray-500">{adjustment.label}</span>{' '}
                                      <span className={isDeduction ? 'font-medium text-red-600' : 'font-medium text-emerald-700'}>
                                        {isDeduction ? '-' : '+'}{formatCurrency(toNumber(adjustment.amount))}
                                      </span>
                                      <div className="text-[10px] uppercase tracking-wide text-slate-400">{adjustmentTreatmentLabels[adjustment.treatment]}</div>
                                    </div>
                                  );
                                })}
                              </div>
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasTips && (
                          <TableCell className={`text-right ${rowTone}`}>
                            {toNumber(item.reported_tips) > 0 ? (
                              <span>
                                {formatCurrency(toNumber(item.reported_tips))}
                                {item.tip_pool && (
                                  <span className={`ml-1 text-[10px] font-medium uppercase ${
                                    item.tip_pool === 'boh'
                                      ? 'text-amber-600'
                                      : item.tip_pool === 'mixed'
                                      ? 'text-violet-600'
                                      : 'text-blue-600'
                                  }`}>
                                    {item.tip_pool}
                                  </span>
                                )}
                              </span>
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasTipsPaidOut && (
                          <TableCell className={`text-right ${rowTone}`}>
                            {toNumber(item.tips_paid_out) > 0 ? (
                              formatCurrency(toNumber(item.tips_paid_out))
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasLoans && (
                          <TableCell className={`text-right ${rowTone}`}>
                            {effectiveLoanDeduction(item) > 0 ? (
                              formatCurrency(effectiveLoanDeduction(item))
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </TableCell>
                          )}
                          <TableCell className={`text-right text-red-600 ${rowTone}`}>
                            {formatCurrency(toNumber(item.withholding_tax))}
                            {item.withholding_tax_adjustment != null && toNumber(item.withholding_tax_adjustment) !== 0 && (
                              <span className="ml-0.5 text-[10px] text-orange-600" title={`FIT adjusted by ${formatCurrency(toNumber(item.withholding_tax_adjustment))}`}>†</span>
                            )}
                            {item.withholding_tax_override != null && (
                              <span className="ml-0.5 text-[10px] text-amber-600" title="Final FIT manually overridden">*</span>
                            )}
                          </TableCell>
                          <TableCell className={`text-right text-red-600 ${rowTone}`}>
                            {toNumber(item.additional_withholding) > 0 ? formatCurrency(toNumber(item.additional_withholding)) : '—'}
                          </TableCell>
                          <TableCell className={`text-right text-red-600 ${rowTone}`}>{formatCurrency(toNumber(item.social_security_tax))}</TableCell>
                          <TableCell className={`text-right text-red-600 ${rowTone}`}>{formatCurrency(toNumber(item.medicare_tax))}</TableCell>
                          <TableCell className={`text-right text-red-600 font-medium ${rowTone}`}>{formatCurrency(toNumber(item.total_deductions))}</TableCell>
                          <TableCell className={`text-right font-bold text-green-600 ${rowTone}`}>{formatCurrency(toNumber(item.net_pay))}</TableCell>
                          {isCalculated && (
                            <TableCell className={`text-center ${rowTone}`}>
                              <button
                                onClick={() => setEditingItem(item)}
                                className="text-xs text-blue-600 hover:text-blue-800 hover:underline font-medium"
                              >
                                Edit
                              </button>
                            </TableCell>
                          )}
                          {isCommitted && !isContractor && (() => {
                            const canCorrect = !!payPeriod?.can_issue_corrective_paycheck;
                            // Replace (uncashed) is offered when we can cleanly
                            // void+reissue or in-place edit a single check on
                            // this period: must be a regular (non-supplemental)
                            // committed period and the item must still own a
                            // non-voided check number.
                            const canReplace =
                              payPeriod?.cycle !== 'supplemental' &&
                              !item.voided &&
                              !!item.check_number;
                            if (!canCorrect && !canReplace) return <TableCell />;
                            return (
                              <TableCell className={`text-center ${rowTone}`}>
                                <div className="flex flex-col items-center gap-0.5">
                                  {canCorrect && (
                                    <button
                                      onClick={() => setCorrectingItem(item)}
                                      className="text-xs text-amber-700 hover:text-amber-900 hover:underline font-medium"
                                      title="Issue a separate supplemental check for the difference (use when the original was cashed)"
                                    >
                                      Correct
                                    </button>
                                  )}
                                  {canReplace && (
                                    <button
                                      onClick={() => setReplacingItem(item)}
                                      className="text-xs text-orange-700 hover:text-orange-900 hover:underline font-medium"
                                      title="Void & reissue this check (use when the original is uncashed or never distributed)"
                                    >
                                      Replace
                                    </button>
                                  )}
                                </div>
                              </TableCell>
                            );
                          })()}
                          {isCommitted && isContractor && (
                            <TableCell className={rowTone} />
                          )}
                        </TableRow>
                      </Fragment>
                    );
                  });
                  })()}
                  {/* Totals */}
                  {(() => {
                    const totalTips = reportablePayrollItems.reduce((s, i) => s + toNumber(i.reported_tips), 0);
                    const totalTipsPaidOut = reportablePayrollItems.reduce((s, i) => s + toNumber(i.tips_paid_out), 0);
                    const totalLoans = reportablePayrollItems.reduce((s, i) => s + effectiveLoanDeduction(i), 0);
                    return (
                      <TableRow className="bg-gray-50 font-bold border-t-2">
                        <TableCell stickyLeft colSpan={3} className="bg-gray-50">Totals ({reportablePayrollItems.length} employees)</TableCell>
                        <TableCell className="text-right">{formatCurrency(totalGross)}</TableCell>
                        {hasCustomEarnings && <TableCell className="text-right">{totalCustomEarnings > 0 ? formatCurrency(totalCustomEarnings) : '—'}</TableCell>}
                        {hasCustomDeductions && <TableCell className="text-right text-red-600">{totalCustomDeductions > 0 ? formatCurrency(totalCustomDeductions) : '—'}</TableCell>}
                        {hasPayrollAdjustments && (
                          <TableCell className={totalPayrollAdjustments < 0 ? 'text-right text-red-600' : 'text-right'}>
                            {totalPayrollAdjustments !== 0 ? `${totalPayrollAdjustments < 0 ? '-' : ''}${formatCurrency(Math.abs(totalPayrollAdjustments))}` : '—'}
                          </TableCell>
                        )}
                        {hasTips && <TableCell className="text-right">{totalTips > 0 ? formatCurrency(totalTips) : '—'}</TableCell>}
                        {hasTipsPaidOut && <TableCell className="text-right">{totalTipsPaidOut > 0 ? formatCurrency(totalTipsPaidOut) : '—'}</TableCell>}
                        {hasLoans && <TableCell className="text-right">{totalLoans > 0 ? formatCurrency(totalLoans) : '—'}</TableCell>}
                        <TableCell className="text-right text-red-600">{formatCurrency(totalWithholding)}</TableCell>
                        <TableCell className="text-right text-red-600">{totalAddlWH > 0 ? formatCurrency(totalAddlWH) : '—'}</TableCell>
                        <TableCell className="text-right text-red-600">{formatCurrency(totalSS)}</TableCell>
                        <TableCell className="text-right text-red-600">{formatCurrency(totalMedicare)}</TableCell>
                        <TableCell className="text-right text-red-600">{formatCurrency(totalDeductions)}</TableCell>
                        <TableCell className="text-right text-green-600">{formatCurrency(totalNet)}</TableCell>
                        {(isCalculated || isCommitted) && <TableCell />}
                      </TableRow>
                    );
                  })()}
                </TableBody>
              </Table>
            </div>
          </Card>
          );
        })()}

        {/* Employer Tax Obligations (Calculated/Approved/Committed) */}
        {!isDraft && payrollItems.length > 0 && (
          <Card className="border-amber-200">
            <div className="p-4 border-b border-amber-200 bg-amber-50">
              <h3 className="font-semibold text-amber-900">Employer Tax Obligations</h3>
              <p className="text-sm text-amber-700 mt-1">
                Guam FIT deposit plus related FICA obligations for this pay period
              </p>
            </div>
            <div className="p-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* FIT Column */}
                <div>
                  <h4 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-3">Federal / Guam Income Tax</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee FIT Withheld</span>
                      <span className="font-medium">{formatCurrency(totalWithholding)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>FIT Subtotal</span>
                      <span>{formatCurrency(totalWithholding)}</span>
                    </div>
                    {fitDivergence && (
                      <div className="mt-2 rounded-md border border-orange-300 bg-orange-50 px-2.5 py-2 text-xs text-orange-900">
                        <div className="flex items-start gap-1.5">
                          <svg className="mt-0.5 h-3.5 w-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                          </svg>
                          <div>
                            <p className="font-semibold">FIT deposit overridden</p>
                            <p className="mt-0.5 leading-snug">
                              Calculated <span className="font-mono">{formatCurrency(fitDivergence.calculated)}</span>,{' '}
                              depositing <span className="font-mono">{formatCurrency(fitDivergence.deposited)}</span>{' '}
                              ({fitDivergence.delta > 0 ? '+' : ''}{formatCurrency(fitDivergence.delta)})
                            </p>
                          </div>
                        </div>
                      </div>
                    )}
                  </div>
                </div>
                {/* SS + Medicare Column */}
                <div>
                  <h4 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-3">Social Security & Medicare (FICA)</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalMedicare)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerMedicare)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>FICA Subtotal</span>
                      <span>{formatCurrency(totalSS + totalEmployerSS + totalMedicare + totalEmployerMedicare)}</span>
                    </div>
                  </div>
                </div>
              </div>
              {/* Grand total */}
              <div className="mt-6 flex flex-col gap-3 border-t-2 border-amber-300 pt-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="text-lg font-bold text-amber-900">Total DRT Deposit</p>
                  <p className="text-sm text-amber-700">Guam FIT withholding only</p>
                </div>
                <p className="wrap-break-word text-2xl font-bold text-amber-900">{formatCurrency(totalDRTDeposit)}</p>
              </div>
              {fitDivergence && (
                <p className="mt-3 text-xs text-orange-800">
                  ⚠ This total reflects the calculated FIT obligation. The FIT deposit check has been
                  overridden to <span className="font-mono font-semibold">{formatCurrency(fitDivergence.deposited)}</span>{' '}
                  — actual amount going to Treasurer of Guam differs from the total above by{' '}
                  <span className="font-mono font-semibold">{fitDivergence.delta > 0 ? '+' : ''}{formatCurrency(fitDivergence.delta)}</span>.
                  See the Non-Employee Checks section for edit history.
                </p>
              )}
            </div>
          </Card>
        )}

        {/* Empty state for draft */}
        {isDraft && payrollItems.length === 0 && employees.length === 0 && (
          <div className="p-12 text-center text-gray-500">
            No active employees found. Add employees first before running payroll.
          </div>
        )}

        {/* Linked Corrections — surfaces supplemental periods that
             corrected this period (one-off corrective paychecks). */}
        {isCommitted && payPeriod.cycle !== 'supplemental' && (supplementals.length > 0 || supplementalsLoading) && (
          <Card className="border-amber-200">
            <div className="p-4 border-b border-amber-200 bg-amber-50">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <h3 className="font-semibold text-amber-900">
                    Linked Corrections {supplementals.length > 0 && `(${supplementals.length})`}
                  </h3>
                  <p className="text-xs text-amber-800 mt-0.5">
                    Off-cycle supplemental periods that adjust this committed period.
                    YTDs, W-2s, reports, and configured downstream syncs include these corrections.
                  </p>
                </div>
              </div>
            </div>
            <div className="divide-y">
              {supplementals.map(sp => (
                <div key={sp.id} className="p-4 flex items-start justify-between gap-3">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-baseline gap-2">
                      <a
                        href={`/pay-periods/${sp.id}`}
                        className="text-sm font-semibold text-blue-700 hover:underline"
                      >
                        Supplemental period · pay date {sp.pay_date}
                      </a>
                      {sp.tax_sync_status && (
                        <span className="text-xs text-gray-500">
                          {sp.tax_sync_status === 'synced' ? 'tax-synced' : `tax-sync ${sp.tax_sync_status}`}
                        </span>
                      )}
                    </div>
                    {sp.payroll_items.map(it => (
                      <div key={it.id} className="mt-1.5 grid grid-cols-1 gap-x-4 gap-y-0.5 text-xs text-gray-700 sm:grid-cols-2">
                        <div>
                          <span className="font-medium text-gray-900">{it.employee_name}</span>
                          {it.check_number && (
                            <span className="text-gray-500"> · check #{it.check_number}</span>
                          )}
                        </div>
                        <div className="sm:text-right">
                          Δ gross {formatCurrency(it.gross_pay)} ·
                          Δ FIT {formatCurrency(it.withholding_tax)} ·
                          Δ net <strong>{formatCurrency(it.net_pay)}</strong>
                        </div>
                        {it.correction_reason && (
                          <div className="sm:col-span-2 italic text-gray-600">
                            “{it.correction_reason}”
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </Card>
        )}

        {/* When viewing a supplemental, link back to the original. */}
        {payPeriod.cycle === 'supplemental' && payPeriod.corrects_pay_period_id && (
          <Card className="border-blue-200">
            <div className="p-4 bg-blue-50">
              <p className="text-sm text-blue-900">
                This is a <strong>supplemental (corrective) pay period</strong>{' '}
                tied to{' '}
                <a
                  href={`/pay-periods/${payPeriod.corrects_pay_period_id}`}
                  className="font-semibold underline"
                >
                  the original committed period
                </a>
                . The figures here are <em>deltas</em> against that period;
                they're rolled into YTDs, W-2s, and reports automatically.
              </p>
            </div>
          </Card>
        )}

        {/* CPR-66: Checks Panel — only for committed pay periods */}
        {isCommitted && (
          <Card>
            <div className="p-4 border-b flex items-center justify-between">
              <h3 className="font-semibold text-gray-900">Checks</h3>
              <Link
                to="/check-settings"
                className="text-xs text-blue-600 hover:underline"
              >
                Check Settings ›
              </Link>
            </div>
            <div className="p-4">
              <ChecksPanel payPeriod={payPeriod} searchTerm={searchTerm} />
            </div>
          </Card>
        )}

        {/* Timecard OCR Panel — for draft pay periods */}
        {isDraft && (
          <TimecardOcrPanel
            payPeriodId={payPeriod.id}
            onPayrollUpdated={handlePayrollItemApplied}
          />
        )}

        {/* Non-Employee Checks — for committed pay periods */}
        {isCommitted && payPeriod.company_id && (
          <NonEmployeeChecksPanel
            payPeriodId={payPeriod.id}
            companyId={payPeriod.company_id}
            payPeriodStatus={payPeriod.status}
            payDate={payPeriod.pay_date}
            onChecksLoaded={setNonEmployeeChecks}
          />
        )}

        {/* Reports Download Panel — for calculated/approved/committed */}
        {!isDraft && payrollItems.length > 0 && (
          <ReportsDownloadPanel
            payPeriodId={payPeriod.id}
            payPeriodStatus={payPeriod.status}
            payDate={payPeriod.pay_date}
          />
        )}

        {/* Timecard History — read-only view for processed pay periods */}
        {!isDraft && (
          <TimecardHistoryPanel payPeriodId={payPeriod.id} />
        )}

        {/* CPR-71: Correction Panel — committed and voided periods */}
        {(isCommitted || isVoided || isCorrection) && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">Payroll Corrections</h3>
              <p className="text-sm text-gray-500 mt-0.5">
                Void this period, create a correction re-run, or review correction history.
              </p>
            </div>
            <div className="p-4">
              <CorrectionPanel
                payPeriod={payPeriod}
                onPayPeriodChange={(updated) => {
                  setPayPeriod(updated);
                  if (updated.payroll_items) {
                    setPayrollItems(updated.payroll_items);
                  }
                }}
              />
            </div>
          </Card>
        )}

        {payPeriod.notes && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">Notes</h3>
            </div>
            <div className="p-4 text-gray-600">{payPeriod.notes}</div>
          </Card>
        )}
      </div>

      {/* Import Modal */}
      <ImportModal
        open={importModalOpen}
        onOpenChange={setImportModalOpen}
        payPeriodId={payPeriod.id}
        onImportComplete={handleImportComplete}
      />

      <TimeTrackingImportModal
        open={timeTrackingImportOpen}
        onClose={() => setTimeTrackingImportOpen(false)}
        payPeriod={payPeriod}
        employees={employees}
        onImportComplete={() => loadPayPeriod(payPeriod.id, true)}
      />

      {/* Per-employee Corrective Paycheck Modal — only relevant on
          committed regular periods. */}
      {correctingItem && payPeriod && payPeriod.cycle !== 'supplemental' && (
        <CorrectivePaycheckModal
          open={correctingItem !== null}
          onOpenChange={(isOpen) => { if (!isOpen) setCorrectingItem(null); }}
          originalPayPeriod={payPeriod}
          originalItem={correctingItem}
          onIssued={() => {
            setCorrectingItem(null);
            // Refresh both the supplementals list and the parent period
            // (so totals/badges that depend on YTD or supplemental count
            // pick up the freshly committed corrective).
            loadSupplementals(payPeriod.id);
            loadPayPeriod(payPeriod.id, true);
          }}
        />
      )}

      {/* Replace Check (uncashed) Modal — used when the original check is
          in our possession (never distributed or returned uncashed) and
          the financial values need to change. Different from Correct
          (which leaves the original alone and adds a supplemental delta). */}
      {replacingItem && payPeriod && payPeriod.cycle !== 'supplemental' && (
        <ReplaceCheckModal
          open={replacingItem !== null}
          onOpenChange={(isOpen) => { if (!isOpen) setReplacingItem(null); }}
          payPeriod={payPeriod}
          payrollItem={replacingItem}
          onReplaced={() => {
            setReplacingItem(null);
            loadPayPeriod(payPeriod.id, true);
          }}
        />
      )}

      {/* Payroll Item Edit Modal */}
      <PayrollItemEditModal
        open={editingItem !== null}
        onOpenChange={(isOpen) => { if (!isOpen) setEditingItem(null); }}
        payPeriodId={payPeriod.id}
        item={editingItem}
        onSaved={handlePayrollItemSaved}
        onRemoved={(id) => {
          const removedItem = payrollItems.find((item) => item.id === id);
          setPayrollItems((prev) => prev.filter((item) => item.id !== id));
          if (removedItem) {
            setPayPeriod((prev) => prev ? {
              ...prev,
              excluded_employee_ids: Array.from(new Set([...(prev.excluded_employee_ids || []), removedItem.employee_id])),
            } : prev);
            const employeeKey = String(removedItem.employee_id);
            setHoursMap((prev) => {
              const next = { ...prev };
              delete next[employeeKey];
              return next;
            });
            setAdditionalEmployeeIds((prev) => {
              const next = new Set(prev);
              next.delete(removedItem.employee_id);
              return next;
            });
          }
          setEditingItem(null);
        }}
        contractorPayType={editingItem ? employeeLookup.get(editingItem.employee_id)?.contractor_pay_type as 'hourly' | 'flat_fee' | undefined : undefined}
        wageRates={editingItem ? (employeeLookup.get(editingItem.employee_id)?.wage_rates || []) : []}
      />

      <Dialog
        open={payDateCorrectionOpen}
        onOpenChange={(open) => {
          setPayDateCorrectionOpen(open);
          if (!open) {
            setPayDateCorrectionReason('');
            setPayDateCorrectionDate('');
          }
        }}
      >
        <DialogContent>
          <form onSubmit={handleCorrectPayDate}>
            <DialogHeader>
              <DialogTitle>Correct Committed Pay Date</DialogTitle>
              <DialogDescription>
                Use this only for a clerical pay date mistake after payroll was committed. Payroll amounts stay unchanged.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="committed_pay_date">Pay Date</Label>
                <Input
                  id="committed_pay_date"
                  type="date"
                  value={payDateCorrectionDate}
                  onChange={(event) => setPayDateCorrectionDate(event.target.value)}
                  required
                />
                <p className="text-xs text-gray-500">
                  This updates the committed pay period, matching check dates, pay stubs, reports, configured downstream sync payloads, and linked pay-period checks.
                </p>
              </div>
              <div className="space-y-2">
                <Label htmlFor="committed_pay_date_reason">Reason</Label>
                <Textarea
                  id="committed_pay_date_reason"
                  value={payDateCorrectionReason}
                  onChange={(event) => setPayDateCorrectionReason(event.target.value)}
                  placeholder="Example: Pay date was entered as April 15 but should be April 30."
                  required
                />
              </div>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setPayDateCorrectionOpen(false)}
                disabled={payDateCorrectionSubmitting}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={payDateCorrectionSubmitting}>
                {payDateCorrectionSubmitting ? 'Saving...' : 'Save Pay Date Correction'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
