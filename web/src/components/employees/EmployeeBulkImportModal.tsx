import { useState, useRef, useCallback, useMemo } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { employeeBulkImportApi } from '@/services/api';
import type { BulkImportEmployeeData, BulkImportPreviewResult, BulkImportApplyResult } from '@/services/api';
import {
  Upload, FileSpreadsheet, CheckCircle2, AlertCircle, AlertTriangle,
  X, Download, Loader2, ChevronDown, ChevronRight, Plus, Info, Pencil,
} from 'lucide-react';

type Step = 'upload' | 'preview' | 'importing' | 'done';

interface EditableRow {
  id: string;
  data: BulkImportEmployeeData;
  included: boolean;
  errors: string[];
  duplicate: boolean;
  new_department: boolean;
  isNew: boolean;
}

const EMPTY_EMPLOYEE: BulkImportEmployeeData = {
  first_name: '', last_name: '', middle_name: null, email: null, ssn: null,
  date_of_birth: null, hire_date: null, employment_type: 'hourly', pay_rate: '',
  pay_frequency: 'biweekly', filing_status: 'single', allowances: '0',
  additional_withholding: '0', w4_dependent_credit: '0', w4_step2_multiple_jobs: 'false',
  w4_step4a_other_income: '0', w4_step4b_deductions: '0', retirement_rate: '0',
  roth_retirement_rate: '0', department: null, address_line1: null, address_line2: null,
  city: null, state: 'GU', zip: null, phone: null, contractor_type: null,
  contractor_pay_type: null, business_name: null, contractor_ein: null, w9_on_file: null,
};

interface Props {
  open: boolean;
  onClose: () => void;
  onComplete: () => void;
}

export function EmployeeBulkImportModal({ open, onClose, onComplete }: Props) {
  const [step, setStep] = useState<Step>('upload');
  const [file, setFile] = useState<File | null>(null);
  const [rows, setRows] = useState<EditableRow[]>([]);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [newDepartments, setNewDepartments] = useState<string[]>([]);
  const [result, setResult] = useState<BulkImportApplyResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const reset = useCallback(() => {
    setStep('upload');
    setFile(null);
    setRows([]);
    setExpandedId(null);
    setNewDepartments([]);
    setResult(null);
    setError(null);
    setLoading(false);
  }, []);

  const handleClose = () => {
    if (step === 'done') onComplete();
    reset();
    onClose();
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (f) { setFile(f); setError(null); }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    const f = e.dataTransfer.files?.[0];
    if (f) {
      const ext = f.name.split('.').pop()?.toLowerCase();
      if (['csv', 'xlsx', 'xls'].includes(ext || '')) {
        setFile(f); setError(null);
      } else {
        setError('Please upload a CSV or Excel (.xlsx) file');
      }
    }
  };

  const handlePreview = async () => {
    if (!file) return;
    setLoading(true);
    setError(null);
    try {
      const data: BulkImportPreviewResult = await employeeBulkImportApi.preview(file);
      const editableRows: EditableRow[] = data.rows.map((r) => ({
        id: `row-${r.row_number}`,
        data: { ...r.data },
        included: r.valid,
        errors: [...r.errors],
        duplicate: r.duplicate,
        new_department: r.new_department,
        isNew: false,
      }));
      setRows(editableRows);
      setNewDepartments(data.summary.new_departments || []);
      setStep('preview');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to parse file');
    } finally {
      setLoading(false);
    }
  };

  const updateRow = useCallback((id: string, updates: Partial<EditableRow>) => {
    setRows(prev => prev.map(r => r.id === id ? { ...r, ...updates } : r));
  }, []);

  const updateRowData = useCallback((id: string, field: keyof BulkImportEmployeeData, value: string | null) => {
    setRows(prev => prev.map(r => {
      if (r.id !== id) return r;
      const newData = { ...r.data, [field]: value };
      const errors = validateRowData(newData);
      return { ...r, data: newData, errors, included: errors.length === 0 ? r.included : false };
    }));
  }, []);

  const addEmployee = useCallback(() => {
    const id = `new-${Date.now()}`;
    const newRow: EditableRow = {
      id,
      data: { ...EMPTY_EMPLOYEE },
      included: true,
      errors: ['first_name is required', 'last_name is required', 'pay_rate is required'],
      duplicate: false,
      new_department: false,
      isNew: true,
    };
    setRows(prev => [...prev, newRow]);
    setExpandedId(id);
  }, []);

  const removeRow = useCallback((id: string) => {
    setRows(prev => prev.filter(r => r.id !== id));
    if (expandedId === id) setExpandedId(null);
  }, [expandedId]);

  const allDepartments = useMemo(() => {
    const depts = new Set<string>();
    rows.forEach(r => { if (r.data.department) depts.add(r.data.department); });
    return Array.from(depts).sort();
  }, [rows]);

  const includedCount = useMemo(() =>
    rows.filter(r => r.included && r.errors.length === 0).length,
  [rows]);

  const invalidCount = useMemo(() =>
    rows.filter(r => r.errors.length > 0).length,
  [rows]);

  const handleApply = async () => {
    const toImport = rows.filter(r => r.included && r.errors.length === 0);
    if (toImport.length === 0) return;

    setStep('importing');
    setError(null);
    try {
      const employees = toImport.map(r => {
        const d = r.data;
        const attrs: Record<string, unknown> = {
          first_name: d.first_name,
          last_name: d.last_name,
          middle_name: d.middle_name || undefined,
          email: d.email || undefined,
          employment_type: d.employment_type || 'hourly',
          pay_rate: d.pay_rate,
          pay_frequency: d.pay_frequency || 'biweekly',
          status: 'active',
          address_line1: d.address_line1 || undefined,
          address_line2: d.address_line2 || undefined,
          city: d.city || undefined,
          state: d.state || undefined,
          zip: d.zip || undefined,
          phone: d.phone || undefined,
        };

        if (d.ssn) attrs.ssn = d.ssn;
        if (d.date_of_birth) attrs.date_of_birth = d.date_of_birth;
        if (d.hire_date) attrs.hire_date = d.hire_date;
        if (d.department) attrs._department_name = d.department;

        if (d.employment_type !== 'contractor') {
          attrs.filing_status = d.filing_status || 'single';
          attrs.allowances = d.allowances || '0';
          attrs.additional_withholding = d.additional_withholding || '0';
          attrs.w4_dependent_credit = d.w4_dependent_credit || '0';
          attrs.w4_step2_multiple_jobs = d.w4_step2_multiple_jobs || 'false';
          attrs.w4_step4a_other_income = d.w4_step4a_other_income || '0';
          attrs.w4_step4b_deductions = d.w4_step4b_deductions || '0';
          attrs.retirement_rate = d.retirement_rate || '0';
          attrs.roth_retirement_rate = d.roth_retirement_rate || '0';
        } else {
          attrs.contractor_type = d.contractor_type || 'individual';
          attrs.contractor_pay_type = d.contractor_pay_type || 'flat_fee';
          if (d.business_name) attrs.business_name = d.business_name;
          if (d.contractor_ein) attrs.contractor_ein = d.contractor_ein;
          if (d.w9_on_file) attrs.w9_on_file = d.w9_on_file === 'true';
        }

        return attrs;
      });

      const res = await employeeBulkImportApi.applyJson(employees);
      setResult(res);
      setStep('done');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to import employees');
      setStep('preview');
    }
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={step !== 'importing' ? handleClose : undefined} />
      <div className="relative z-50 bg-white rounded-xl shadow-2xl w-full max-w-6xl max-h-[92vh] flex flex-col mx-4">
        {/* Header */}
        <div className="flex items-center justify-between border-b px-6 py-4 shrink-0">
          <div>
            <h3 className="text-lg font-semibold text-gray-900">Bulk Import Employees</h3>
            <p className="text-sm text-gray-500 mt-0.5">
              {step === 'upload' && 'Upload a CSV or Excel file with employee data'}
              {step === 'preview' && 'Review and edit employees before importing'}
              {step === 'importing' && 'Creating employees...'}
              {step === 'done' && 'Import complete'}
            </p>
          </div>
          {step !== 'importing' && (
            <button onClick={handleClose} className="text-gray-400 hover:text-gray-600 p-1">
              <X className="w-5 h-5" />
            </button>
          )}
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-6 py-5">
          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg flex items-start gap-2">
              <AlertCircle className="w-4 h-4 text-red-600 mt-0.5 shrink-0" />
              <p className="text-sm text-red-700">{error}</p>
            </div>
          )}

          {step === 'upload' && (
            <div className="space-y-6">
              <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 flex items-start gap-3">
                <FileSpreadsheet className="w-5 h-5 text-blue-600 mt-0.5 shrink-0" />
                <div>
                  <p className="text-sm font-medium text-blue-800">Start with the template</p>
                  <p className="text-sm text-blue-700 mt-0.5">
                    Download the CSV template, fill in your employee data, then upload it here.
                  </p>
                  <button
                    onClick={() => employeeBulkImportApi.downloadTemplate()}
                    className="inline-flex items-center gap-1.5 mt-2 text-sm font-medium text-blue-700 hover:text-blue-900"
                  >
                    <Download className="w-3.5 h-3.5" />
                    Download Template (CSV)
                  </button>
                </div>
              </div>

              <div
                className={`border-2 border-dashed rounded-xl p-10 text-center transition-colors ${
                  file ? 'border-green-300 bg-green-50' : 'border-gray-300 hover:border-blue-400 hover:bg-blue-50/30'
                }`}
                onDragOver={e => e.preventDefault()}
                onDrop={handleDrop}
              >
                {file ? (
                  <div className="flex flex-col items-center gap-3">
                    <CheckCircle2 className="w-10 h-10 text-green-500" />
                    <div>
                      <p className="font-medium text-gray-900">{file.name}</p>
                      <p className="text-sm text-gray-500">{(file.size / 1024).toFixed(1)} KB</p>
                    </div>
                    <Button variant="outline" size="sm" onClick={() => { setFile(null); if (fileInputRef.current) fileInputRef.current.value = ''; }}>
                      Choose Different File
                    </Button>
                  </div>
                ) : (
                  <div className="flex flex-col items-center gap-3">
                    <Upload className="w-10 h-10 text-gray-400" />
                    <div>
                      <p className="font-medium text-gray-700">Drop your file here, or click to browse</p>
                      <p className="text-sm text-gray-500 mt-1">Supports CSV and Excel (.xlsx, .xls) files</p>
                    </div>
                    <Button variant="outline" size="sm" onClick={() => fileInputRef.current?.click()}>
                      Browse Files
                    </Button>
                  </div>
                )}
                <input
                  ref={fileInputRef}
                  type="file"
                  accept=".csv,.xlsx,.xls"
                  onChange={handleFileSelect}
                  className="hidden"
                />
              </div>
            </div>
          )}

          {step === 'preview' && (
            <div className="space-y-4">
              {/* Summary badges */}
              <div className="flex items-center gap-3 flex-wrap">
                <Badge className="bg-gray-100 text-gray-700 text-xs px-2.5 py-1">
                  {rows.length} total
                </Badge>
                <Badge className="bg-green-100 text-green-700 text-xs px-2.5 py-1">
                  {includedCount} to import
                </Badge>
                {invalidCount > 0 && (
                  <Badge className="bg-red-100 text-red-700 text-xs px-2.5 py-1">
                    {invalidCount} need fixes
                  </Badge>
                )}
              </div>

              {/* New departments notice */}
              {newDepartments.length > 0 && (
                <div className="px-3 py-2 bg-blue-50 border border-blue-200 rounded-lg flex items-start gap-2 text-sm">
                  <Info className="w-4 h-4 text-blue-600 mt-0.5 shrink-0" />
                  <span className="text-blue-800">
                    <strong>New departments will be created:</strong>{' '}
                    {newDepartments.join(', ')}
                  </span>
                </div>
              )}

              {/* Employee rows */}
              <div className="border rounded-lg overflow-hidden divide-y">
                {rows.map(row => (
                  <EmployeeRowEditor
                    key={row.id}
                    row={row}
                    expanded={expandedId === row.id}
                    onToggleExpand={() => setExpandedId(expandedId === row.id ? null : row.id)}
                    onToggleInclude={() => updateRow(row.id, { included: !row.included })}
                    onUpdateField={(field, value) => updateRowData(row.id, field, value)}
                    onRemove={row.isNew ? () => removeRow(row.id) : undefined}
                    allDepartments={allDepartments}
                  />
                ))}
              </div>

              {/* Add employee button */}
              <button
                onClick={addEmployee}
                className="w-full py-3 border-2 border-dashed border-gray-300 rounded-lg text-sm text-gray-500 hover:border-blue-400 hover:text-blue-600 hover:bg-blue-50/30 transition-colors flex items-center justify-center gap-2"
              >
                <Plus className="w-4 h-4" />
                Add Employee
              </button>
            </div>
          )}

          {step === 'importing' && (
            <div className="flex flex-col items-center justify-center py-16 gap-4">
              <Loader2 className="w-10 h-10 animate-spin text-blue-600" />
              <p className="text-gray-600 font-medium">Creating {includedCount} employees...</p>
              <p className="text-sm text-gray-500">This may take a moment</p>
            </div>
          )}

          {step === 'done' && result && (
            <div className="space-y-6">
              <div className="flex flex-col items-center py-8 gap-3">
                <CheckCircle2 className="w-14 h-14 text-green-500" />
                <h4 className="text-xl font-semibold text-gray-900">Import Complete</h4>
                <p className="text-gray-600">
                  Successfully created <span className="font-semibold text-green-700">{result.created}</span> employee{result.created !== 1 ? 's' : ''}
                  {result.failed > 0 && (
                    <>, <span className="font-semibold text-red-600">{result.failed}</span> failed</>
                  )}
                </p>
              </div>
              {result.errors.length > 0 && (
                <div className="bg-red-50 border border-red-200 rounded-lg p-4">
                  <p className="text-sm font-medium text-red-800 mb-2">Failed rows:</p>
                  <ul className="space-y-1">
                    {result.errors.map((e, idx) => (
                      <li key={idx} className="text-sm text-red-700">
                        Row {e.row}: {e.messages.join(', ')}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="border-t px-6 py-4 flex items-center justify-between shrink-0 bg-gray-50 rounded-b-xl">
          <div>
            {step === 'preview' && (
              <Button variant="outline" onClick={() => { setStep('upload'); setRows([]); setNewDepartments([]); }}>
                Back
              </Button>
            )}
          </div>
          <div className="flex items-center gap-3">
            {step !== 'importing' && (
              <Button variant="outline" onClick={handleClose}>
                {step === 'done' ? 'Close' : 'Cancel'}
              </Button>
            )}
            {step === 'upload' && (
              <Button onClick={handlePreview} disabled={!file || loading}>
                {loading ? (
                  <span className="flex items-center gap-2">
                    <Loader2 className="w-4 h-4 animate-spin" />
                    Parsing...
                  </span>
                ) : (
                  'Upload & Preview'
                )}
              </Button>
            )}
            {step === 'preview' && (
              <Button onClick={handleApply} disabled={includedCount === 0}>
                Import {includedCount} Employee{includedCount !== 1 ? 's' : ''}
              </Button>
            )}
            {step === 'done' && (
              <Button onClick={() => { onComplete(); reset(); onClose(); }}>
                Go to Employees
              </Button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

// --- Validation (client-side mirror of backend) ---

function validateRowData(data: BulkImportEmployeeData): string[] {
  const errors: string[] = [];
  if (!data.first_name?.trim()) errors.push('first_name is required');
  if (!data.last_name?.trim()) errors.push('last_name is required');
  if (!data.employment_type?.trim()) errors.push('employment_type is required');
  if (!data.pay_rate?.trim()) errors.push('pay_rate is required');
  else {
    const rate = parseFloat(data.pay_rate);
    if (isNaN(rate) || rate < 0) errors.push('pay_rate must be a non-negative number');
  }
  if (data.employment_type && !['hourly', 'salary', 'contractor'].includes(data.employment_type)) {
    errors.push('employment_type must be hourly, salary, or contractor');
  }
  if (data.ssn) {
    const digits = data.ssn.replace(/\D/g, '');
    if (digits.length !== 9 && digits.length !== 0) errors.push('ssn must be exactly 9 digits');
  }
  return errors;
}

// --- Expandable Row Editor ---

interface RowEditorProps {
  row: EditableRow;
  expanded: boolean;
  onToggleExpand: () => void;
  onToggleInclude: () => void;
  onUpdateField: (field: keyof BulkImportEmployeeData, value: string | null) => void;
  onRemove?: () => void;
  allDepartments: string[];
}

function EmployeeRowEditor({ row, expanded, onToggleExpand, onToggleInclude, onUpdateField, onRemove, allDepartments }: RowEditorProps) {
  const hasErrors = row.errors.length > 0;
  const bgClass = hasErrors
    ? 'bg-red-50/50'
    : row.duplicate
    ? 'bg-amber-50/50'
    : !row.included
    ? 'bg-gray-50/50 opacity-60'
    : '';

  return (
    <div className={bgClass}>
      {/* Summary row */}
      <div
        className="flex items-center gap-2 px-3 py-2.5 cursor-pointer hover:bg-gray-50/80 transition-colors"
        onClick={onToggleExpand}
      >
        <input
          type="checkbox"
          checked={row.included && !hasErrors}
          disabled={hasErrors}
          onChange={(e) => { e.stopPropagation(); onToggleInclude(); }}
          onClick={(e) => e.stopPropagation()}
          className="rounded border-gray-300 shrink-0"
        />
        <button className="shrink-0 text-gray-400">
          {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
        </button>
        <div className="flex-1 grid grid-cols-[1fr_80px_80px_80px_70px_80px_auto] gap-2 items-center text-sm min-w-0">
          <span className="font-medium text-gray-900 truncate">
            {row.data.first_name || <span className="text-gray-400 italic">First</span>}{' '}
            {row.data.last_name || <span className="text-gray-400 italic">Last</span>}
            {row.isNew && <Badge className="ml-2 bg-blue-100 text-blue-700 text-[10px] px-1.5 py-0">New</Badge>}
          </span>
          <Badge variant="outline" className="text-[11px] justify-center">
            {row.data.employment_type || 'hourly'}
          </Badge>
          <span className="text-gray-700 text-xs text-right">
            {row.data.pay_rate ? `$${Number(row.data.pay_rate).toFixed(2)}` : '—'}
          </span>
          <span className="text-gray-500 text-xs">{row.data.pay_frequency || '—'}</span>
          <span className="text-gray-500 text-xs">{row.data.filing_status || '—'}</span>
          <span className="text-gray-500 text-xs truncate">{row.data.department || '—'}</span>
          <div className="flex items-center gap-1 justify-end">
            {hasErrors ? (
              <div className="flex items-center gap-1" title={row.errors.join('; ')}>
                <AlertCircle className="w-3.5 h-3.5 text-red-500 shrink-0" />
                <span className="text-[11px] text-red-600">{row.errors.length} issue{row.errors.length > 1 ? 's' : ''}</span>
              </div>
            ) : row.duplicate ? (
              <div className="flex items-center gap-1">
                <AlertTriangle className="w-3.5 h-3.5 text-amber-500 shrink-0" />
                <span className="text-[11px] text-amber-600">Duplicate</span>
              </div>
            ) : (
              <div className="flex items-center gap-1">
                <CheckCircle2 className="w-3.5 h-3.5 text-green-500 shrink-0" />
                <span className="text-[11px] text-green-600">Valid</span>
              </div>
            )}
            {!expanded && (
              <Pencil className="w-3 h-3 text-gray-400 ml-1" />
            )}
          </div>
        </div>
      </div>

      {/* Expanded detail panel */}
      {expanded && (
        <div className="px-4 pb-4 pt-1 border-t bg-white">
          {hasErrors && (
            <div className="mb-3 p-2 bg-red-50 border border-red-200 rounded text-xs text-red-700">
              {row.errors.map((e, i) => <div key={i}>• {e}</div>)}
            </div>
          )}

          {/* Personal Information */}
          <FieldSection title="Personal Information">
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <Field label="First Name *" value={row.data.first_name} onChange={v => onUpdateField('first_name', v)} />
              <Field label="Middle Name" value={row.data.middle_name} onChange={v => onUpdateField('middle_name', v)} />
              <Field label="Last Name *" value={row.data.last_name} onChange={v => onUpdateField('last_name', v)} />
              <Field label="Email" value={row.data.email} onChange={v => onUpdateField('email', v)} />
              <Field label="SSN" value={row.data.ssn} onChange={v => onUpdateField('ssn', v)} placeholder="123-45-6789" />
              <Field label="Date of Birth" value={row.data.date_of_birth} onChange={v => onUpdateField('date_of_birth', v)} type="date" />
              <Field label="Hire Date" value={row.data.hire_date} onChange={v => onUpdateField('hire_date', v)} type="date" />
              <Field label="Phone" value={row.data.phone} onChange={v => onUpdateField('phone', v)} />
            </div>
          </FieldSection>

          {/* Employment */}
          <FieldSection title="Employment">
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <SelectField
                label="Employment Type *"
                value={row.data.employment_type}
                onChange={v => onUpdateField('employment_type', v)}
                options={[
                  { value: 'hourly', label: 'Hourly' },
                  { value: 'salary', label: 'Salary' },
                  { value: 'contractor', label: 'Contractor' },
                ]}
              />
              <Field label="Pay Rate *" value={row.data.pay_rate} onChange={v => onUpdateField('pay_rate', v)} prefix="$" />
              <SelectField
                label="Pay Frequency"
                value={row.data.pay_frequency}
                onChange={v => onUpdateField('pay_frequency', v)}
                options={[
                  { value: 'biweekly', label: 'Biweekly' },
                  { value: 'weekly', label: 'Weekly' },
                  { value: 'semimonthly', label: 'Semi-monthly' },
                  { value: 'monthly', label: 'Monthly' },
                ]}
              />
              <DepartmentField
                value={row.data.department}
                onChange={v => onUpdateField('department', v)}
                departments={allDepartments}
              />
            </div>
          </FieldSection>

          {/* W-4 / Tax (only for non-contractors) */}
          {row.data.employment_type !== 'contractor' && (
            <FieldSection title="W-4 / Tax Withholding">
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                <SelectField
                  label="Filing Status"
                  value={row.data.filing_status}
                  onChange={v => onUpdateField('filing_status', v)}
                  options={[
                    { value: 'single', label: 'Single' },
                    { value: 'married', label: 'Married' },
                    { value: 'married_separate', label: 'Married Filing Separately' },
                    { value: 'head_of_household', label: 'Head of Household' },
                  ]}
                />
                <Field label="Allowances" value={row.data.allowances} onChange={v => onUpdateField('allowances', v)} />
                <Field label="Additional Withholding" value={row.data.additional_withholding} onChange={v => onUpdateField('additional_withholding', v)} prefix="$" />
                <Field label="Step 3: Dependent Credit" value={row.data.w4_dependent_credit} onChange={v => onUpdateField('w4_dependent_credit', v)} prefix="$" />
                <SelectField
                  label="Step 2: Multiple Jobs"
                  value={row.data.w4_step2_multiple_jobs}
                  onChange={v => onUpdateField('w4_step2_multiple_jobs', v)}
                  options={[{ value: 'false', label: 'No' }, { value: 'true', label: 'Yes' }]}
                />
                <Field label="Step 4a: Other Income" value={row.data.w4_step4a_other_income} onChange={v => onUpdateField('w4_step4a_other_income', v)} prefix="$" />
                <Field label="Step 4b: Deductions" value={row.data.w4_step4b_deductions} onChange={v => onUpdateField('w4_step4b_deductions', v)} prefix="$" />
              </div>
            </FieldSection>
          )}

          {/* Retirement (only for non-contractors) */}
          {row.data.employment_type !== 'contractor' && (
            <FieldSection title="Retirement">
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                <Field label="Retirement Rate" value={row.data.retirement_rate} onChange={v => onUpdateField('retirement_rate', v)} placeholder="0.05 = 5%" />
                <Field label="Roth Retirement Rate" value={row.data.roth_retirement_rate} onChange={v => onUpdateField('roth_retirement_rate', v)} placeholder="0.03 = 3%" />
              </div>
            </FieldSection>
          )}

          {/* Contractor fields */}
          {row.data.employment_type === 'contractor' && (
            <FieldSection title="Contractor Details">
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                <SelectField
                  label="Contractor Type"
                  value={row.data.contractor_type}
                  onChange={v => onUpdateField('contractor_type', v)}
                  options={[
                    { value: 'individual', label: 'Individual' },
                    { value: 'business', label: 'Business' },
                  ]}
                />
                <SelectField
                  label="Pay Type"
                  value={row.data.contractor_pay_type}
                  onChange={v => onUpdateField('contractor_pay_type', v)}
                  options={[
                    { value: 'hourly', label: 'Hourly' },
                    { value: 'flat_fee', label: 'Flat Fee' },
                  ]}
                />
                <Field label="Business Name" value={row.data.business_name} onChange={v => onUpdateField('business_name', v)} />
                <Field label="EIN" value={row.data.contractor_ein} onChange={v => onUpdateField('contractor_ein', v)} />
                <SelectField
                  label="W-9 On File"
                  value={row.data.w9_on_file}
                  onChange={v => onUpdateField('w9_on_file', v)}
                  options={[{ value: 'false', label: 'No' }, { value: 'true', label: 'Yes' }]}
                />
              </div>
            </FieldSection>
          )}

          {/* Address */}
          <FieldSection title="Address">
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <div className="sm:col-span-2">
                <Field label="Address Line 1" value={row.data.address_line1} onChange={v => onUpdateField('address_line1', v)} />
              </div>
              <div className="sm:col-span-2">
                <Field label="Address Line 2" value={row.data.address_line2} onChange={v => onUpdateField('address_line2', v)} />
              </div>
              <Field label="City" value={row.data.city} onChange={v => onUpdateField('city', v)} />
              <Field label="State" value={row.data.state} onChange={v => onUpdateField('state', v)} />
              <Field label="ZIP" value={row.data.zip} onChange={v => onUpdateField('zip', v)} />
            </div>
          </FieldSection>

          {onRemove && (
            <div className="mt-3 flex justify-end">
              <Button variant="outline" size="sm" className="text-red-600 hover:text-red-700 hover:bg-red-50" onClick={onRemove}>
                Remove Employee
              </Button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// --- Reusable form components ---

function FieldSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mt-3 first:mt-0">
      <h5 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2">{title}</h5>
      {children}
    </div>
  );
}

function Field({
  label, value, onChange, type = 'text', placeholder, prefix,
}: {
  label: string;
  value: string | null;
  onChange: (v: string | null) => void;
  type?: string;
  placeholder?: string;
  prefix?: string;
}) {
  return (
    <div>
      <label className="block text-[11px] font-medium text-gray-500 mb-0.5">{label}</label>
      <div className={`flex items-center ${prefix ? 'relative' : ''}`}>
        {prefix && (
          <span className="absolute left-2 text-xs text-gray-400 pointer-events-none">{prefix}</span>
        )}
        <input
          type={type}
          value={value ?? ''}
          onChange={e => onChange(e.target.value || null)}
          placeholder={placeholder}
          className={`w-full border border-gray-200 rounded px-2 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-blue-400 focus:border-blue-400 ${
            prefix ? 'pl-5' : ''
          }`}
        />
      </div>
    </div>
  );
}

function SelectField({
  label, value, onChange, options,
}: {
  label: string;
  value: string | null;
  onChange: (v: string) => void;
  options: { value: string; label: string }[];
}) {
  return (
    <div>
      <label className="block text-[11px] font-medium text-gray-500 mb-0.5">{label}</label>
      <select
        value={value ?? ''}
        onChange={e => onChange(e.target.value)}
        className="w-full border border-gray-200 rounded px-2 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-blue-400 focus:border-blue-400 bg-white"
      >
        <option value="">—</option>
        {options.map(o => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </select>
    </div>
  );
}

function DepartmentField({
  value, onChange, departments,
}: {
  value: string | null;
  onChange: (v: string | null) => void;
  departments: string[];
}) {
  const [custom, setCustom] = useState(false);

  if (custom || (value && !departments.includes(value))) {
    return (
      <div>
        <label className="block text-[11px] font-medium text-gray-500 mb-0.5">Department</label>
        <div className="flex gap-1">
          <input
            type="text"
            value={value ?? ''}
            onChange={e => onChange(e.target.value || null)}
            placeholder="New department name"
            className="flex-1 border border-gray-200 rounded px-2 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-blue-400 focus:border-blue-400"
          />
          {departments.length > 0 && (
            <button
              onClick={() => setCustom(false)}
              className="text-xs text-blue-600 hover:text-blue-800 px-1 shrink-0"
              title="Choose from existing"
            >
              List
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <div>
      <label className="block text-[11px] font-medium text-gray-500 mb-0.5">Department</label>
      <div className="flex gap-1">
        <select
          value={value ?? ''}
          onChange={e => onChange(e.target.value || null)}
          className="flex-1 border border-gray-200 rounded px-2 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-blue-400 focus:border-blue-400 bg-white"
        >
          <option value="">—</option>
          {departments.map(d => (
            <option key={d} value={d}>{d}</option>
          ))}
        </select>
        <button
          onClick={() => setCustom(true)}
          className="text-xs text-blue-600 hover:text-blue-800 px-1 shrink-0"
          title="Type a new department"
        >
          <Plus className="w-3.5 h-3.5" />
        </button>
      </div>
    </div>
  );
}
