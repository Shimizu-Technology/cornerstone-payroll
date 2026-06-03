import { useState, useCallback, useEffect } from 'react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { reportsApi, transmittalApi } from '@/services/api';
import type { BlobDownload, TransmittalOptions, TransmittalPreview, SavedTransmittal, TransmittalCustomEntry } from '@/services/api';
import { Loader2 } from 'lucide-react';
import { DRT } from '@/lib/constants';
import { Form500EditorModal } from '@/components/form500/Form500EditorModal';

interface ReportsDownloadPanelProps {
  payPeriodId: number;
  payPeriodStatus: string;
  payDate: string;
}

type ReportKey =
  | 'payrollRegister'
  | 'payrollSummaryByEmployee'
  | 'deductionsContributions'
  | 'paycheckHistory'
  | 'retirementPlans'
  | 'transmittalLog'
  | 'installmentLoans'
  | 'fullPrintPackage';

type ReportAction = 'preview' | 'download' | 'spreadsheet';

const REPORTS: { key: ReportKey; label: string; description: string }[] = [
  { key: 'payrollRegister', label: 'Payroll Register', description: 'Full payroll register with all employee details' },
  { key: 'payrollSummaryByEmployee', label: 'Payroll Summary by Employee', description: 'Detailed breakdown of earnings, deductions, and taxes per employee' },
  { key: 'deductionsContributions', label: 'Deductions & Contributions', description: 'All employee deductions and employer contributions' },
  { key: 'paycheckHistory', label: 'Paycheck History', description: 'Check numbers, amounts, and status for all paychecks' },
  { key: 'retirementPlans', label: 'Retirement Plans Report', description: '401(k) and retirement contributions summary' },
  { key: 'transmittalLog', label: 'Transmittal Log', description: 'Cover document listing all items delivered to client' },
  { key: 'installmentLoans', label: 'Employee Installment Loans', description: 'Loan balances and transaction history' },
  { key: 'fullPrintPackage', label: 'Full Print Package', description: 'All reports combined into a single PDF' },
];

const DEFAULT_REPORT_LIST = [
  'Payroll Summary by Employee',
  'Deductions and Contributions Report',
  'Paycheck History',
  'Retirement Plans Report',
  'Employee Installment Loan Report',
];

const DEFAULT_NOTES = [
  'EFTPS payment to be done by client',
  '401K upload to be submitted by client',
];

function fmt(val: number) {
  return `$${val.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`;
}

function SignoffEditorModal({
  open,
  onClose,
  onGenerate,
  payPeriodId,
}: {
  open: boolean;
  onClose: () => void;
  onGenerate: (entries: { name: string; check_number: string }[], notes: string[]) => void;
  payPeriodId: number;
}) {
  const [entries, setEntries] = useState<{ name: string; check_number: string; included: boolean }[]>([]);
  const [notes, setNotes] = useState<string[]>([]);
  const [newNote, setNewNote] = useState('');
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [initialized, setInitialized] = useState(false);
  const [savedState, setSavedState] = useState<{ generated_at?: string } | null>(null);
  const [companyName, setCompanyName] = useState('');
  const [periodDesc, setPeriodDesc] = useState('');

  useEffect(() => {
    if (!open) {
      const resetTimer = window.setTimeout(() => setInitialized(false), 0);
      return () => window.clearTimeout(resetTimer);
    }

    const handleEsc = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [open, onClose]);

  useEffect(() => {
    if (!open || initialized) return;
    let cancelled = false;
    const requestTimer = window.setTimeout(() => {
      setLoadingPreview(true);
      setNewNote('');
      reportsApi.checkSignoffPreview(payPeriodId).then((data) => {
        if (cancelled) return;

        setCompanyName(data.company_name);
        if (data.period_start && data.period_end) {
          const [sY, sM, sD] = data.period_start.split('-').map(Number);
          const [eY, eM, eD] = data.period_end.split('-').map(Number);
          const months = ['','January','February','March','April','May','June','July','August','September','October','November','December'];
          setPeriodDesc(sM === eM && sY === eY
            ? `${months[sM]} ${sD}-${eD}, ${eY}`
            : `${months[sM]} ${sD} - ${months[eM]} ${eD}, ${eY}`);
        }

        const saved = data.saved_signoff;
        if (saved) {
          setSavedState({ generated_at: saved.generated_at });
          const savedNames = new Set(saved.entries.map((e: { name: string }) => e.name));
          const mergedEntries = saved.entries.map((e: { name: string; check_number: string }) => ({
            name: e.name, check_number: e.check_number, included: true
          }));
          data.entries.forEach(e => {
            if (!savedNames.has(e.name)) {
              mergedEntries.push({ name: e.name, check_number: e.check_number, included: false });
            }
          });
          setEntries(mergedEntries);
          setNotes(saved.notes?.length ? [...saved.notes] : []);
        } else {
          setSavedState(null);
          setEntries(data.entries.map(e => ({
            name: e.name, check_number: e.check_number, included: true
          })));
          setNotes([]);
        }
        setInitialized(true);
      }).catch(() => {
        if (!cancelled) setInitialized(true);
      }).finally(() => {
        if (!cancelled) setLoadingPreview(false);
      });
    }, 0);

    return () => {
      cancelled = true;
      window.clearTimeout(requestTimer);
    };
  }, [open, payPeriodId, initialized]);

  if (!open) return null;

  const includedCount = entries.filter(e => e.included).length;

  const handleGenerate = () => {
    const included = entries.filter(e => e.included).map(e => ({ name: e.name, check_number: e.check_number }));
    onGenerate(included, notes);
  };

  const handleResetToPayroll = () => {
    setInitialized(false);
    setSavedState(null);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={onClose} />
      <div className="relative z-50 bg-white rounded-lg shadow-xl w-full max-w-3xl max-h-[90vh] overflow-y-auto mx-4">
        <div className="sticky top-0 bg-white border-b px-6 py-4 flex items-center justify-between rounded-t-lg z-10">
          <h3 className="text-lg font-semibold text-gray-900">Edit Check Sign-Off Sheet</h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600 p-1">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {loadingPreview ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
            <span className="ml-2 text-sm text-gray-500">Loading sign-off data...</span>
          </div>
        ) : (<>
          {savedState?.generated_at && (
            <div className="mx-6 mt-4 px-3 py-2 bg-green-50 border border-green-200 rounded-lg flex items-center gap-2 text-sm">
              <svg className="w-4 h-4 text-green-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-green-800">
                Last generated: {new Date(savedState.generated_at).toLocaleDateString('en-US', {
                  month: 'short', day: 'numeric', year: 'numeric',
                  hour: 'numeric', minute: '2-digit'
                })}
              </span>
            </div>
          )}

          <div className="px-6 py-4 space-y-6">
            {/* Company / period header */}
            {companyName && (
              <div className="bg-gray-50 border rounded-lg p-3">
                <p className="font-semibold text-sm text-gray-900">{companyName}</p>
                {periodDesc && <p className="text-xs text-gray-500 mt-0.5">Pay Period: {periodDesc}</p>}
              </div>
            )}

            {/* Employee Selection */}
            <div>
              <div className="flex items-center justify-between mb-2">
                <label className="text-sm font-medium text-gray-700">
                  Employees ({includedCount} of {entries.length} selected)
                </label>
                <div className="flex gap-2">
                  <button
                    onClick={() => setEntries(entries.map(e => ({ ...e, included: true })))}
                    className="text-xs text-blue-600 hover:text-blue-800"
                  >Select All</button>
                  <span className="text-gray-300">|</span>
                  <button
                    onClick={() => setEntries(entries.map(e => ({ ...e, included: false })))}
                    className="text-xs text-blue-600 hover:text-blue-800"
                  >Deselect All</button>
                  <span className="text-gray-300">|</span>
                  <button
                    onClick={handleResetToPayroll}
                    className="text-xs text-blue-600 hover:text-blue-800"
                  >Reset</button>
                </div>
              </div>

              <div className="border rounded-lg overflow-hidden max-h-[400px] overflow-y-auto">
                <table className="w-full text-sm">
                  <thead className="sticky top-0">
                    <tr className="bg-gray-50 border-b">
                      <th className="px-3 py-2 w-10"></th>
                      <th className="text-left px-3 py-2 font-medium text-gray-600 w-8">#</th>
                      <th className="text-left px-3 py-2 font-medium text-gray-600">Employee Name</th>
                      <th className="text-left px-3 py-2 font-medium text-gray-600 w-36">Check No.</th>
                      <th className="px-3 py-2 w-10"></th>
                    </tr>
                  </thead>
                  <tbody>
                    {entries.map((entry, i) => (
                      <tr key={i} className={`border-b last:border-b-0 ${entry.included ? 'bg-white' : 'bg-gray-50 opacity-60'}`}>
                        <td className="px-3 py-1.5 text-center">
                          <input
                            type="checkbox"
                            checked={entry.included}
                            onChange={() => {
                              const updated = [...entries];
                              updated[i] = { ...updated[i], included: !updated[i].included };
                              setEntries(updated);
                            }}
                            className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
                          />
                        </td>
                        <td className="px-3 py-1.5 text-gray-400 text-xs">{i + 1}</td>
                        <td className="px-3 py-1.5">
                          <input
                            type="text"
                            value={entry.name}
                            onChange={e => {
                              const updated = [...entries];
                              updated[i] = { ...updated[i], name: e.target.value };
                              setEntries(updated);
                            }}
                            className="w-full text-sm border rounded px-2 py-1 focus:outline-none focus:ring-1 focus:ring-blue-500"
                            placeholder="Last, First"
                          />
                        </td>
                        <td className="px-3 py-1.5">
                          <input
                            type="text"
                            value={entry.check_number}
                            onChange={e => {
                              const updated = [...entries];
                              updated[i] = { ...updated[i], check_number: e.target.value };
                              setEntries(updated);
                            }}
                            className="w-full text-sm border rounded px-2 py-1 text-center focus:outline-none focus:ring-1 focus:ring-blue-500"
                            placeholder="—"
                          />
                        </td>
                        <td className="px-3 py-1.5 text-center">
                          <button
                            onClick={() => setEntries(entries.filter((_, idx) => idx !== i))}
                            className="text-red-400 hover:text-red-600 p-0.5"
                            title="Remove"
                          >
                            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                            </svg>
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <button
                onClick={() => setEntries([...entries, { name: '', check_number: '', included: true }])}
                className="mt-2 text-xs text-blue-600 hover:text-blue-800 flex items-center gap-1"
              >
                <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
                </svg>
                Add Row
              </button>
            </div>

            {/* Notes */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Notes <span className="font-normal text-gray-400">(printed at bottom of sheet)</span>
              </label>
              {notes.map((note, i) => (
                <div key={i} className="flex items-start gap-2 mb-2">
                  <textarea
                    value={note}
                    onChange={e => {
                      const updated = [...notes];
                      updated[i] = e.target.value;
                      setNotes(updated);
                    }}
                    rows={2}
                    className="flex-1 text-sm border rounded px-2 py-1 resize-none"
                  />
                  <button
                    onClick={() => setNotes(notes.filter((_, idx) => idx !== i))}
                    className="text-red-500 hover:text-red-700 text-xs mt-1"
                  >Remove</button>
                </div>
              ))}
              <div className="flex gap-2">
                <input
                  type="text"
                  placeholder="Add a note..."
                  value={newNote}
                  onChange={e => setNewNote(e.target.value)}
                  onKeyDown={e => {
                    if (e.key === 'Enter' && newNote.trim()) {
                      setNotes([...notes, newNote.trim()]);
                      setNewNote('');
                    }
                  }}
                  className="flex-1 text-sm border rounded px-2 py-1"
                />
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => { if (newNote.trim()) { setNotes([...notes, newNote.trim()]); setNewNote(''); } }}
                  className="text-xs"
                >Add</Button>
              </div>
            </div>
          </div>

          {/* Footer */}
          <div className="sticky bottom-0 bg-white border-t px-6 py-4 flex items-center justify-end gap-3 rounded-b-lg">
            <Button variant="outline" size="sm" onClick={onClose}>Cancel</Button>
            <Button size="sm" onClick={handleGenerate} disabled={includedCount === 0}>
              Generate Sign-Off Sheet
            </Button>
          </div>
        </>)}
      </div>
    </div>
  );
}

function TransmittalEditorModal({
  open,
  onClose,
  onGenerate,
  targetLabel,
  payPeriodId,
  onOpenForm500,
}: {
  open: boolean;
  onClose: () => void;
  onGenerate: (options: TransmittalOptions) => void;
  targetLabel: string;
  payPeriodId: number;
  onOpenForm500: () => void;
}) {
  const [preparerName, setPreparerName] = useState('Cornerstone Tax Services');
  const [notes, setNotes] = useState<string[]>([]);
  const [reportList, setReportList] = useState<string[]>(DEFAULT_REPORT_LIST);
  const [newNote, setNewNote] = useState('');
  const [newReport, setNewReport] = useState('');
  const localDateString = () => {
    const date = new Date();
    const yyyy = date.getFullYear();
    const mm = String(date.getMonth() + 1).padStart(2, '0');
    const dd = String(date.getDate()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd}`;
  };
  const [preview, setPreview] = useState<TransmittalPreview | null>(null);
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [initialized, setInitialized] = useState(false);
  const [transmittalDate, setTransmittalDate] = useState(localDateString);
  const [checkFirst, setCheckFirst] = useState('');
  const [checkLast, setCheckLast] = useState('');
  const [payrollCheckNumbers, setPayrollCheckNumbers] = useState<string[]>([]);
  const [neCheckNumbers, setNeCheckNumbers] = useState<Record<number, string>>({});
  const [customEntries, setCustomEntries] = useState<TransmittalCustomEntry[]>([]);
  const [savedState, setSavedState] = useState<SavedTransmittal | null>(null);

  useEffect(() => {
    if (!open) {
      const resetTimer = window.setTimeout(() => setInitialized(false), 0);
      return () => window.clearTimeout(resetTimer);
    }
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [open, onClose]);

  useEffect(() => {
    if (!open || initialized) return;
    let cancelled = false;
    const requestTimer = window.setTimeout(() => {
      setLoadingPreview(true);
      setNewNote('');
      setNewReport('');
      transmittalApi.preview(payPeriodId).then((data) => {
        if (cancelled) return;

        setPreview(data);
        setSavedState(data.saved_transmittal);

        const saved = data.saved_transmittal;
        if (saved) {
          setPreparerName(saved.preparer_name || 'Cornerstone Tax Services');
          setTransmittalDate(saved.transmittal_date || localDateString());
          setNotes(saved.notes?.length ? [...saved.notes] : [...DEFAULT_NOTES]);
          setReportList(saved.report_list?.length ? [...saved.report_list] : [...DEFAULT_REPORT_LIST]);
          setCheckFirst(data.payroll_checks.first || saved.check_number_first || '');
          setCheckLast(data.payroll_checks.last || saved.check_number_last || '');
          setPayrollCheckNumbers(saved.payroll_check_numbers?.length ? [...saved.payroll_check_numbers] : [...(data.payroll_checks.numbers || [])]);
          const neNums: Record<number, string> = {};
          data.non_employee_checks.forEach(c => {
            const savedNum = saved.non_employee_check_numbers?.[String(c.id)];
            neNums[c.id] = c.check_number || savedNum || '';
          });
          setNeCheckNumbers(neNums);
          setCustomEntries(saved.custom_entries?.length ? saved.custom_entries.map(e => ({ ...e })) : []);
        } else {
          setPreparerName('Cornerstone Tax Services');
          setTransmittalDate(localDateString());
          setReportList([...DEFAULT_REPORT_LIST]);
          setCheckFirst(data.payroll_checks.first || '');
          setCheckLast(data.payroll_checks.last || '');
          setPayrollCheckNumbers([...(data.payroll_checks.numbers || [])]);
          const neNums: Record<number, string> = {};
          data.non_employee_checks.forEach(c => { neNums[c.id] = c.check_number || ''; });
          setNeCheckNumbers(neNums);
          setCustomEntries([]);
          const autoNotes: string[] = [];
          if (data.tax_totals.total_fica > 0) {
            autoNotes.push(`FICA Obligation (Social Security & Medicare): ${fmt(data.tax_totals.total_fica)}`);
          }
          if (data.tax_totals.fit > 0) {
            autoNotes.push(`FIT Deposit Total: ${fmt(data.tax_totals.fit)} — check to Treasurer of Guam for DRT`);
          }
          autoNotes.push(...DEFAULT_NOTES);
          setNotes(autoNotes);
        }
        setInitialized(true);
      }).catch(() => {
        if (cancelled) return;

        setPreparerName('Cornerstone Tax Services');
        setReportList([...DEFAULT_REPORT_LIST]);
        setNotes([...DEFAULT_NOTES]);
        setInitialized(true);
      }).finally(() => {
        if (!cancelled) setLoadingPreview(false);
      });
    }, 0);

    return () => {
      cancelled = true;
      window.clearTimeout(requestTimer);
    };
  }, [open, payPeriodId, initialized]);

  if (!open) return null;

  const formatCheckRanges = (numbers: string[]) => {
    const clean = numbers.map(n => n.trim()).filter(Boolean);
    const numeric = Array.from(new Set(clean.filter(n => /^\d+$/.test(n)).map(Number))).sort((a, b) => a - b);
    const ranges: string[] = [];
    let index = 0;
    while (index < numeric.length) {
      const start = numeric[index];
      let end = start;
      while (index + 1 < numeric.length && numeric[index + 1] === end + 1) {
        index += 1;
        end = numeric[index];
      }
      ranges.push(start === end ? `${start}` : `${start}-${end}`);
      index += 1;
    }
    const nonNumeric = Array.from(new Set(clean.filter(n => !/^\d+$/.test(n)))).sort();
    return [...ranges, ...nonNumeric].join(', ');
  };

  const updatePayrollCheckNumber = (index: number, value: string) => {
    setPayrollCheckNumbers(prev => prev.map((number, idx) => idx === index ? value : number));
  };

  const addPayrollCheckNumber = () => setPayrollCheckNumbers(prev => [...prev, '']);

  const removePayrollCheckNumber = (index: number) => {
    setPayrollCheckNumbers(prev => prev.filter((_, idx) => idx !== index));
  };

  const displayCheckType = (type?: string | null) => {
    if (!type) return '';
    if (type.toLowerCase() === 'grt') return 'GRT';

    return type
      .replace(/_/g, ' ')
      .replace(/\w\S*/g, (word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase());
  };

  const handleAddNote = () => {
    const trimmed = newNote.trim();
    if (trimmed) {
      setNotes(prev => [...prev, trimmed]);
      setNewNote('');
    }
  };

  const handleRemoveNote = (idx: number) => {
    setNotes(prev => prev.filter((_, i) => i !== idx));
  };

  const handleAddReport = () => {
    const trimmed = newReport.trim();
    if (trimmed) {
      setReportList(prev => [...prev, trimmed]);
      setNewReport('');
    }
  };

  const handleRemoveReport = (idx: number) => {
    setReportList(prev => prev.filter((_, i) => i !== idx));
  };

  const handleGenerate = () => {
    const hasNeOverrides = Object.values(neCheckNumbers).some(v => v.trim());
    const validEntries = customEntries.filter(e => e.title.trim());
    onGenerate({
      preparerName: preparerName.trim() || undefined,
      transmittalDate: transmittalDate || undefined,
      notes: notes.length > 0 ? notes : undefined,
      reportList: reportList,
      checkNumberFirst: checkFirst.trim() || undefined,
      checkNumberLast: checkLast.trim() || undefined,
      payrollCheckNumbers: payrollCheckNumbers.map(n => n.trim()).filter(Boolean),
      nonEmployeeCheckNumbers: hasNeOverrides ? neCheckNumbers : undefined,
      customEntries: validEntries.length > 0 ? validEntries : undefined,
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={onClose} />
      <div className="relative z-50 bg-white rounded-lg shadow-xl w-full max-w-3xl max-h-[90vh] overflow-y-auto mx-4">
        <div className="sticky top-0 bg-white border-b px-6 py-4 flex items-center justify-between rounded-t-lg z-10">
          <h3 className="text-lg font-semibold text-gray-900">Edit {targetLabel}</h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600 p-1">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {loadingPreview ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
            <span className="ml-2 text-sm text-gray-500">Loading transmittal data...</span>
          </div>
        ) : (<>
          {savedState?.generated_at && (
            <div className="mx-6 mt-4 px-3 py-2 bg-green-50 border border-green-200 rounded-lg flex items-center gap-2 text-sm">
              <svg className="w-4 h-4 text-green-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-green-800">
                Last generated: {new Date(savedState.generated_at).toLocaleDateString('en-US', {
                  month: 'short', day: 'numeric', year: 'numeric',
                  hour: 'numeric', minute: '2-digit'
                })}
              </span>
            </div>
          )}
          <div className="px-6 py-4 space-y-6">
            {/* Preparer Name */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Preparer Name</label>
              <input
                type="text"
                value={preparerName}
                onChange={(e) => setPreparerName(e.target.value)}
                placeholder="e.g. Cornerstone Tax Services"
                className="w-full border rounded-md px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Transmittal Date</label>
              <input
                type="date"
                value={transmittalDate}
                onChange={(e) => setTransmittalDate(e.target.value)}
                className="w-full border rounded-md px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              />
              <p className="mt-1 text-xs text-gray-500">Defaults to today; change it if the package will be delivered on a different date.</p>
            </div>

            {/* Documents Provided Preview */}
            {preview && (
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">Documents Provided to Client</label>
                <div className="bg-gray-50 border rounded-lg p-4 space-y-4 text-sm">
                  {/* Payroll Checks */}
                  {preview.payroll_checks.count > 0 && (
                    <div>
                      <p className="font-medium text-gray-900">1) Payroll Checks</p>
                      <div className="ml-6 text-gray-600 space-y-1.5 mt-1">
                        <p>Number of Checks: <span className="font-medium text-gray-900">{payrollCheckNumbers.filter(n => n.trim()).length}</span></p>
                        <div>
                          <span>Checks #: </span>
                          <span className="font-medium text-gray-900">
                            {formatCheckRanges(payrollCheckNumbers) || preview.payroll_checks.ranges || '—'}
                          </span>
                        </div>
                        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 pt-1">
                          {payrollCheckNumbers.map((number, idx) => (
                            <div key={idx} className="flex items-center gap-1">
                              <input
                                type="text"
                                value={number}
                                onChange={(e) => updatePayrollCheckNumber(idx, e.target.value)}
                                className="w-full border rounded px-2 py-1 text-sm font-medium text-gray-900 text-center"
                                aria-label={`Payroll check number ${idx + 1}`}
                              />
                              <button
                                type="button"
                                onClick={() => removePayrollCheckNumber(idx)}
                                className="text-xs text-gray-400 hover:text-red-600 px-1"
                                aria-label={`Remove payroll check number ${idx + 1}`}
                              >
                                ×
                              </button>
                            </div>
                          ))}
                        </div>
                        <button type="button" onClick={addPayrollCheckNumber} className="text-xs text-blue-600 hover:text-blue-800">
                          + Add payroll check #
                        </button>
                      </div>
                    </div>
                  )}

                  {/* Non-Employee Checks */}
                  {preview.non_employee_checks.map((check, idx) => (
                    <div key={check.id}>
                      <p className="font-medium text-gray-900">
                        {(preview.payroll_checks.count > 0 ? 2 : 1) + idx}) {check.payable_to} — {displayCheckType(check.check_type)}
                      </p>
                      <div className="ml-6 text-gray-600 space-y-1 mt-1">
                        <div className="flex items-center gap-2">
                          <span>Check #:</span>
                          <input
                            type="text"
                            value={neCheckNumbers[check.id] || ''}
                            onChange={(e) => setNeCheckNumbers(prev => ({ ...prev, [check.id]: e.target.value }))}
                            className="w-24 border rounded px-2 py-0.5 text-sm font-medium text-gray-900 text-center"
                            placeholder="____"
                          />
                        </div>
                        <p>Amount: <span className="font-medium text-gray-900">{fmt(check.amount)}</span></p>
                        <p>Payable to: <span className="font-medium text-gray-900">{check.payable_to}</span></p>
                        {check.memo && <p>For: {displayCheckType(check.check_type)} — {check.memo}</p>}
                        {check.description && <p>Description/Memo: {check.description}</p>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Custom / Manual Entries */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Additional Documents / Manual Entries</label>
              <p className="text-xs text-gray-500 mb-2">Add manually written checks, extra documents, or other items to the transmittal</p>
              <div className="space-y-3">
                {customEntries.map((entry, idx) => (
                  <div key={idx} className="border rounded-lg p-3 bg-gray-50 space-y-2 group relative">
                    <div className="flex items-center gap-2">
                      <input
                        type="text"
                        value={entry.title}
                        onChange={(e) => {
                          const updated = [...customEntries];
                          updated[idx] = { ...updated[idx], title: e.target.value };
                          setCustomEntries(updated);
                        }}
                        placeholder="e.g. Manual Check for John Doe"
                        className="flex-1 border rounded-md px-3 py-1.5 text-sm font-medium"
                      />
                      <button
                        onClick={() => setCustomEntries(customEntries.filter((_, i) => i !== idx))}
                        className="text-red-400 hover:text-red-600 p-1"
                        title="Remove entry"
                      >
                        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                        </svg>
                      </button>
                    </div>
                    {entry.details.map((detail, dIdx) => (
                      <div key={dIdx} className="flex items-center gap-2 ml-4">
                        <input
                          type="text"
                          value={detail}
                          onChange={(e) => {
                            const updated = [...customEntries];
                            const details = [...updated[idx].details];
                            details[dIdx] = e.target.value;
                            updated[idx] = { ...updated[idx], details };
                            setCustomEntries(updated);
                          }}
                          placeholder="Detail line..."
                          className="flex-1 border rounded-md px-3 py-1 text-sm"
                        />
                        <button
                          onClick={() => {
                            const updated = [...customEntries];
                            updated[idx] = { ...updated[idx], details: updated[idx].details.filter((_, i) => i !== dIdx) };
                            setCustomEntries(updated);
                          }}
                          className="text-red-300 hover:text-red-500 p-0.5"
                        >
                          <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                          </svg>
                        </button>
                      </div>
                    ))}
                    <button
                      onClick={() => {
                        const updated = [...customEntries];
                        updated[idx] = { ...updated[idx], details: [...updated[idx].details, ''] };
                        setCustomEntries(updated);
                      }}
                      className="text-blue-600 hover:text-blue-800 text-xs font-medium ml-4"
                    >
                      + Add detail line
                    </button>
                  </div>
                ))}
                <button
                  onClick={() => setCustomEntries([...customEntries, { title: '', details: [] }])}
                  className="text-blue-600 hover:text-blue-800 text-sm font-medium flex items-center gap-1"
                >
                  <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
                  </svg>
                  Add Custom Entry
                </button>
              </div>
            </div>

            {/* Employer Tax Obligations */}
            {preview && preview.tax_totals.total_drt_deposit > 0 && (
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">Employer Tax Obligations</label>
                <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 text-sm">
                  <div className="grid grid-cols-2 gap-x-8 gap-y-1">
                    <div>
                      <p className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-1">Federal / Guam Income Tax</p>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employee FIT Withheld</span>
                        <span className="font-medium">{fmt(preview.tax_totals.fit)}</span>
                      </div>
                      <div className="flex justify-between border-t mt-1 pt-1 font-semibold">
                        <span>FIT Subtotal</span>
                        <span>{fmt(preview.tax_totals.fit)}</span>
                      </div>
                    </div>
                    <div>
                      <p className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-1">Social Security & Medicare (FICA)</p>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employee SS (6.2%)</span>
                        <span>{fmt(preview.tax_totals.employee_ss)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employer SS (6.2%)</span>
                        <span>{fmt(preview.tax_totals.employer_ss)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employee Medicare (1.45%)</span>
                        <span>{fmt(preview.tax_totals.employee_medicare)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employer Medicare (1.45%)</span>
                        <span>{fmt(preview.tax_totals.employer_medicare)}</span>
                      </div>
                      <div className="flex justify-between border-t mt-1 pt-1 font-semibold">
                        <span>FICA Subtotal</span>
                        <span>{fmt(preview.tax_totals.total_fica)}</span>
                      </div>
                    </div>
                  </div>
                  <div className="mt-3 pt-3 border-t border-amber-300 flex justify-between text-base font-bold text-amber-800">
                    <span>Total DRT Deposit (FIT only)</span>
                    <span>{fmt(preview.tax_totals.total_drt_deposit)}</span>
                  </div>
                </div>
              </div>
            )}

            {/* Guam DRT Resources */}
            {preview && preview.tax_totals.fit > 0 && (
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">Guam DRT Resources</label>
                <div className="bg-blue-50 border border-blue-200 rounded-lg p-3 flex items-start gap-3">
                  <svg className="w-5 h-5 text-blue-600 mt-0.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                  </svg>
                  <div className="text-sm">
                    <p className="font-medium text-blue-800">FIT deposit requires Form 500</p>
                    <p className="text-blue-700 mt-0.5">
                      <button
                        type="button"
                        onClick={onOpenForm500}
                        className="font-medium underline hover:text-blue-900"
                      >
                        Open saved Form 500
                      </button>
                      {' · '}
                      <a href={DRT.FORMS_PAGE} target="_blank" rel="noopener noreferrer" className="underline hover:text-blue-900">
                        All DRT Forms
                      </a>
                    </p>
                  </div>
                </div>
              </div>
            )}

            {/* Notes */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Notes</label>
              <p className="text-xs text-gray-500 mb-2">Instructions or reminders for the client — auto-populated with tax totals</p>
              <div className="space-y-2">
                {notes.map((note, idx) => (
                  <div key={idx} className="flex items-center gap-2 group">
                    <input
                      type="text"
                      value={note}
                      onChange={(e) => {
                        const updated = [...notes];
                        updated[idx] = e.target.value;
                        setNotes(updated);
                      }}
                      className="flex-1 border rounded-md px-3 py-1.5 text-sm"
                    />
                    <button
                      onClick={() => handleRemoveNote(idx)}
                      className="text-red-400 hover:text-red-600 opacity-0 group-hover:opacity-100 transition-opacity p-1"
                      title="Remove"
                    >
                      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                ))}
                <div className="flex items-center gap-2">
                  <input
                    type="text"
                    value={newNote}
                    onChange={(e) => setNewNote(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter') handleAddNote(); }}
                    placeholder="Add a note..."
                    className="flex-1 border border-dashed rounded-md px-3 py-1.5 text-sm text-gray-500"
                  />
                  <button
                    onClick={handleAddNote}
                    disabled={!newNote.trim()}
                    className="text-blue-600 hover:text-blue-800 disabled:text-gray-300 text-sm font-medium px-2"
                  >
                    + Add
                  </button>
                </div>
              </div>
            </div>

            {/* Report List */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Reports Included</label>
              <p className="text-xs text-gray-500 mb-2">Listed on the transmittal as documents provided to client</p>
              <div className="space-y-2">
                {reportList.map((report, idx) => (
                  <div key={idx} className="flex items-center gap-2 group">
                    <span className="text-sm text-gray-500 w-6 text-right">{idx + 1}.</span>
                    <input
                      type="text"
                      value={report}
                      onChange={(e) => {
                        const updated = [...reportList];
                        updated[idx] = e.target.value;
                        setReportList(updated);
                      }}
                      className="flex-1 border rounded-md px-3 py-1.5 text-sm"
                    />
                    <button
                      onClick={() => handleRemoveReport(idx)}
                      className="text-red-400 hover:text-red-600 opacity-0 group-hover:opacity-100 transition-opacity p-1"
                      title="Remove"
                    >
                      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                ))}
                <div className="flex items-center gap-2">
                  <span className="text-sm text-gray-400 w-6 text-right">{reportList.length + 1}.</span>
                  <input
                    type="text"
                    value={newReport}
                    onChange={(e) => setNewReport(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter') handleAddReport(); }}
                    placeholder="Add a report..."
                    className="flex-1 border border-dashed rounded-md px-3 py-1.5 text-sm text-gray-500"
                  />
                  <button
                    onClick={handleAddReport}
                    disabled={!newReport.trim()}
                    className="text-blue-600 hover:text-blue-800 disabled:text-gray-300 text-sm font-medium px-2"
                  >
                    + Add
                  </button>
                </div>
              </div>
            </div>
          </div>
        </>)}

        <div className="sticky bottom-0 bg-gray-50 border-t px-6 py-4 flex justify-end gap-3 rounded-b-lg">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={handleGenerate} disabled={loadingPreview}>
            {savedState?.generated_at ? 'Regenerate' : 'Generate'} {targetLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}

function downloadBlob(blobData: BlobDownload, fallbackName: string) {
  const url = URL.createObjectURL(blobData.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = blobData.filename || fallbackName;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

async function fetchReport(
  reportKey: ReportKey,
  payPeriodId: number,
  payPeriodPayDate?: string,
  transmittalOptions?: TransmittalOptions
): Promise<BlobDownload> {
  switch (reportKey) {
    case 'payrollRegister':
      return reportsApi.payrollRegisterPdf(payPeriodId);
    case 'payrollSummaryByEmployee':
      return reportsApi.payrollSummaryByEmployeePdf(payPeriodId);
    case 'deductionsContributions':
      return reportsApi.deductionsContributionsPdf(payPeriodId);
    case 'paycheckHistory':
      return reportsApi.paycheckHistoryPdf(payPeriodId);
    case 'retirementPlans':
      return reportsApi.retirementPlansPdf(payPeriodId);
    case 'transmittalLog':
      return reportsApi.transmittalLogPdf(payPeriodId, transmittalOptions);
    case 'installmentLoans':
      return reportsApi.installmentLoansPdf(payPeriodPayDate);
    case 'fullPrintPackage':
      return reportsApi.fullPrintPackagePdf(payPeriodId, transmittalOptions);
  }
}

async function fetchSpreadsheet(reportKey: ReportKey, payPeriodId: number, payPeriodPayDate?: string): Promise<BlobDownload | null> {
  switch (reportKey) {
    case 'payrollRegister':
      return reportsApi.payrollRegisterXlsx(payPeriodId);
    case 'payrollSummaryByEmployee':
      return reportsApi.payrollSummaryByEmployeeXlsx(payPeriodId);
    case 'deductionsContributions':
      return reportsApi.deductionsContributionsXlsx(payPeriodId);
    case 'paycheckHistory':
      return reportsApi.paycheckHistoryXlsx(payPeriodId);
    case 'retirementPlans':
      return reportsApi.retirementPlansXlsx(payPeriodId);
    case 'installmentLoans':
      return reportsApi.installmentLoansXlsx(payPeriodPayDate);
    default:
      return null;
  }
}

function PdfPreviewModal({
  open,
  onClose,
  pdfUrl,
  title,
  onDownload,
  onPrint,
}: {
  open: boolean;
  onClose: () => void;
  pdfUrl: string | null;
  title: string;
  onDownload: () => void;
  onPrint: () => void;
}) {
  useEffect(() => {
    if (!open) return;
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex flex-col">
      <div className="fixed inset-0 bg-black/60" onClick={onClose} />

      <div className="relative z-50 flex flex-col h-full m-3 sm:m-6">
        {/* Header */}
        <div className="flex items-center justify-between bg-gray-900 text-white px-4 py-3 rounded-t-lg shrink-0">
          <h3 className="font-semibold text-sm sm:text-base truncate mr-4">{title}</h3>
          <div className="flex items-center gap-2 shrink-0">
            <button
              onClick={onPrint}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium bg-white/10 hover:bg-white/20 rounded transition-colors"
              title="Print"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M17 17h2a2 2 0 002-2v-4a2 2 0 00-2-2H5a2 2 0 00-2 2v4a2 2 0 002 2h2m2 4h6a2 2 0 002-2v-4a2 2 0 00-2-2H9a2 2 0 00-2 2v4a2 2 0 002 2zm8-12V5a2 2 0 00-2-2H9a2 2 0 00-2 2v4h10z" />
              </svg>
              Print
            </button>
            <button
              onClick={onDownload}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium bg-white/10 hover:bg-white/20 rounded transition-colors"
              title="Download"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
              </svg>
              Download
            </button>
            <button
              onClick={onClose}
              className="ml-2 p-1.5 hover:bg-white/20 rounded transition-colors"
              title="Close (Esc)"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </div>

        {/* PDF Content */}
        <div className="flex-1 bg-gray-200 rounded-b-lg overflow-hidden min-h-0">
          {pdfUrl ? (
            <iframe
              src={pdfUrl}
              className="w-full h-full border-0"
              title={title}
            />
          ) : (
            <div className="flex items-center justify-center h-full">
              <div className="flex flex-col items-center gap-3 text-gray-500">
                <svg className="animate-spin h-8 w-8" viewBox="0 0 24 24">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                </svg>
                <p className="text-sm font-medium">Generating report...</p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export function ReportsDownloadPanel({ payPeriodId, payPeriodStatus, payDate }: ReportsDownloadPanelProps) {
  const [loading, setLoading] = useState<Record<string, boolean>>({});
  const [error, setError] = useState<string | null>(null);
  const [previewState, setPreviewState] = useState<{
    open: boolean;
    key: ReportKey | null;
    label: string;
    pdfUrl: string | null;
    blobData: BlobDownload | null;
  }>({ open: false, key: null, label: '', pdfUrl: null, blobData: null });
  const [transmittalEditor, setTransmittalEditor] = useState<{
    open: boolean;
    key: ReportKey | null;
    label: string;
    mode: 'preview' | 'download';
  }>({ open: false, key: null, label: '', mode: 'preview' });
  const [form500Open, setForm500Open] = useState(false);
  const [savedTransmittal, setSavedTransmittal] = useState<SavedTransmittal | null>(null);
  const [signoffEditor, setSignoffEditor] = useState<{
    open: boolean;
    mode: 'view' | 'download';
  }>({ open: false, mode: 'view' });
  const [signoffSavedAt, setSignoffSavedAt] = useState<string | null>(null);
  const [signoffPdfPreview, setSignoffPdfPreview] = useState<{
    open: boolean;
    pdfUrl: string | null;
    blobData: BlobDownload | null;
  }>({ open: false, pdfUrl: null, blobData: null });
  const [signoffLoading, setSignoffLoading] = useState(false);

  const isReady = payPeriodStatus !== 'draft';
  const loadingKey = (reportKey: ReportKey, action: ReportAction) => `${reportKey}:${action}`;
  const isReportLoading = (reportKey: ReportKey, action: ReportAction) => Boolean(loading[loadingKey(reportKey, action)]);

  useEffect(() => {
    if (!isReady) return;
    transmittalApi.preview(payPeriodId).then((data) => {
      setSavedTransmittal(data.saved_transmittal);
    }).catch(() => { /* ignore */ });
  }, [payPeriodId, isReady]);

  const needsTransmittalEditor = (key: ReportKey) => key === 'transmittalLog' || key === 'fullPrintPackage';

  const cleanupPreview = useCallback(() => {
    if (previewState.pdfUrl) {
      URL.revokeObjectURL(previewState.pdfUrl);
    }
    setPreviewState({ open: false, key: null, label: '', pdfUrl: null, blobData: null });
  }, [previewState.pdfUrl]);

  const handlePreview = async (reportKey: ReportKey, label: string, transmittalOpts?: TransmittalOptions) => {
    if (needsTransmittalEditor(reportKey) && !transmittalOpts) {
      setTransmittalEditor({ open: true, key: reportKey, label, mode: 'preview' });
      return;
    }

    const key = loadingKey(reportKey, 'preview');
    setLoading(prev => ({ ...prev, [key]: true }));
    setError(null);
    setPreviewState({ open: true, key: reportKey, label, pdfUrl: null, blobData: null });

    try {
      const blobData = await fetchReport(reportKey, payPeriodId, payDate, transmittalOpts);
      const url = URL.createObjectURL(blobData.blob);
      setPreviewState(prev => ({ ...prev, pdfUrl: url, blobData }));
    } catch (err) {
      setPreviewState(prev => ({ ...prev, open: false }));
      setError(err instanceof Error ? err.message : 'Failed to generate report');
    } finally {
      setLoading(prev => ({ ...prev, [key]: false }));
    }
  };

  const handleDownload = async (reportKey: ReportKey, transmittalOpts?: TransmittalOptions) => {
    if (needsTransmittalEditor(reportKey) && !transmittalOpts) {
      setTransmittalEditor({ open: true, key: reportKey, label: REPORTS.find(r => r.key === reportKey)?.label || '', mode: 'download' });
      return;
    }

    const key = loadingKey(reportKey, 'download');
    setLoading(prev => ({ ...prev, [key]: true }));
    setError(null);

    try {
      const blobData = await fetchReport(reportKey, payPeriodId, payDate, transmittalOpts);
      downloadBlob(blobData, `${reportKey}.pdf`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download report');
    } finally {
      setLoading(prev => ({ ...prev, [key]: false }));
    }
  };

  const handleSpreadsheetDownload = async (reportKey: ReportKey) => {
    const key = loadingKey(reportKey, 'spreadsheet');
    setLoading(prev => ({ ...prev, [key]: true }));
    setError(null);

    try {
      const blobData = await fetchSpreadsheet(reportKey, payPeriodId, payDate);
      if (!blobData) return;
      downloadBlob(blobData, `${reportKey}.xlsx`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download spreadsheet');
    } finally {
      setLoading(prev => ({ ...prev, [key]: false }));
    }
  };

  const savedToOptions = (saved: SavedTransmittal, preview?: TransmittalPreview): TransmittalOptions => {
    const liveNonEmployeeNumbers = preview?.non_employee_checks.reduce<Record<number, string>>((acc, check) => {
      const savedNum = saved.non_employee_check_numbers?.[String(check.id)];
      const number = check.check_number || savedNum;
      if (number) acc[check.id] = number;
      return acc;
    }, {});

    return {
      preparerName: saved.preparer_name || undefined,
      transmittalDate: saved.transmittal_date || undefined,
      notes: saved.notes?.length ? saved.notes : undefined,
      reportList: saved.report_list || [],
      checkNumberFirst: preview?.payroll_checks.first || saved.check_number_first || undefined,
      checkNumberLast: preview?.payroll_checks.last || saved.check_number_last || undefined,
      payrollCheckNumbers: saved.payroll_check_numbers?.length ? saved.payroll_check_numbers : preview?.payroll_checks.numbers,
      nonEmployeeCheckNumbers: liveNonEmployeeNumbers && Object.keys(liveNonEmployeeNumbers).length > 0
        ? liveNonEmployeeNumbers
        : saved.non_employee_check_numbers
        ? Object.fromEntries(Object.entries(saved.non_employee_check_numbers).map(([k, v]) => [Number(k), v]))
        : undefined,
    };
  };

  const handleReprint = async (reportKey: ReportKey, label: string) => {
    if (!savedTransmittal) return;
    try {
      const preview = await transmittalApi.preview(payPeriodId);
      setSavedTransmittal(preview.saved_transmittal);
      const saved = preview.saved_transmittal || savedTransmittal;
      await handlePreview(reportKey, label, savedToOptions(saved, preview));
      refreshSavedState();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to refresh transmittal data');
    }
  };

  const refreshSavedState = () => {
    transmittalApi.preview(payPeriodId).then((data) => {
      setSavedTransmittal(data.saved_transmittal);
    }).catch(() => {});
  };

  const handleTransmittalGenerate = async (options: TransmittalOptions) => {
    const { key, mode } = transmittalEditor;
    setTransmittalEditor({ open: false, key: null, label: '', mode: 'preview' });
    if (!key) return;

    if (mode === 'preview') {
      await handlePreview(key, REPORTS.find(r => r.key === key)?.label || '', options);
    } else {
      await handleDownload(key, options);
    }
    refreshSavedState();
  };

  const handlePreviewDownload = () => {
    if (previewState.blobData) {
      downloadBlob(previewState.blobData, `${previewState.key || 'report'}.pdf`);
    }
  };

  const handlePreviewPrint = () => {
    if (previewState.pdfUrl) {
      const printWindow = window.open(previewState.pdfUrl, '_blank');
      if (printWindow) {
        printWindow.addEventListener('load', () => {
          printWindow.print();
        });
      }
    }
  };

  useEffect(() => {
    if (!isReady) return;
    reportsApi.checkSignoffPreview(payPeriodId).then((data) => {
      if (data.saved_signoff?.generated_at) {
        setSignoffSavedAt(data.saved_signoff.generated_at);
      }
    }).catch(() => {});
  }, [payPeriodId, isReady]);

  const handleSignoffGenerate = async (entries: { name: string; check_number: string }[], notes: string[]) => {
    const { mode } = signoffEditor;
    setSignoffEditor({ open: false, mode: 'view' });

    setSignoffLoading(true);
    setError(null);

    try {
      if (mode === 'view') {
        setSignoffPdfPreview({ open: true, pdfUrl: null, blobData: null });
        const blobData = await reportsApi.checkSignoffPdf(payPeriodId, notes.length > 0 ? notes : undefined, entries);
        const url = URL.createObjectURL(blobData.blob);
        setSignoffPdfPreview({ open: true, pdfUrl: url, blobData });
      } else {
        const blobData = await reportsApi.checkSignoffSheet(payPeriodId, notes.length > 0 ? notes : undefined, entries);
        downloadBlob(blobData, 'check_signoff_sheet.xlsx');
      }
      setSignoffSavedAt(new Date().toISOString());
    } catch (err) {
      setSignoffPdfPreview({ open: false, pdfUrl: null, blobData: null });
      setError(err instanceof Error ? err.message : 'Failed to generate sign-off sheet');
    } finally {
      setSignoffLoading(false);
    }
  };

  const handleSignoffView = async () => {
    if (!signoffSavedAt) {
      setSignoffEditor({ open: true, mode: 'view' });
      return;
    }
    setSignoffLoading(true);
    setError(null);
    setSignoffPdfPreview({ open: true, pdfUrl: null, blobData: null });
    try {
      const blobData = await reportsApi.checkSignoffPdf(payPeriodId);
      const url = URL.createObjectURL(blobData.blob);
      setSignoffPdfPreview({ open: true, pdfUrl: url, blobData });
    } catch (err) {
      setSignoffPdfPreview({ open: false, pdfUrl: null, blobData: null });
      setError(err instanceof Error ? err.message : 'Failed to generate sign-off PDF');
    } finally {
      setSignoffLoading(false);
    }
  };

  const handleSignoffDownload = async () => {
    if (!signoffSavedAt) {
      setSignoffEditor({ open: true, mode: 'download' });
      return;
    }
    setSignoffLoading(true);
    setError(null);
    try {
      const blobData = await reportsApi.checkSignoffSheet(payPeriodId);
      downloadBlob(blobData, 'check_signoff_sheet.xlsx');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download sign-off sheet');
    } finally {
      setSignoffLoading(false);
    }
  };

  const cleanupSignoffPreview = useCallback(() => {
    if (signoffPdfPreview.pdfUrl) {
      URL.revokeObjectURL(signoffPdfPreview.pdfUrl);
    }
    setSignoffPdfPreview({ open: false, pdfUrl: null, blobData: null });
  }, [signoffPdfPreview.pdfUrl]);

  if (!isReady) return null;

  return (
    <>
      <Card>
        <div className="p-4 border-b bg-gray-50">
          <h3 className="font-semibold text-gray-900">Reports & Documents</h3>
          <p className="text-sm text-gray-500 mt-1">
            View, download, or print reports for this pay period
          </p>
        </div>
        <div className="p-4">
          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded text-sm text-red-700">
              {error}
            </div>
          )}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            {REPORTS.map(report => {
              const hasSaved = savedTransmittal && needsTransmittalEditor(report.key);
              const previewLoading = isReportLoading(report.key, 'preview');
              const downloadLoading = isReportLoading(report.key, 'download');
              const spreadsheetLoading = isReportLoading(report.key, 'spreadsheet');
              const canDownloadSpreadsheet = !['transmittalLog', 'fullPrintPackage'].includes(report.key);
              return (
                <div key={report.key} className="flex items-center justify-between p-3 border rounded-lg hover:bg-gray-50 transition-colors">
                  <div className="mr-3 min-w-0">
                    <p className="font-medium text-sm text-gray-900">{report.label}</p>
                    <p className="text-xs text-gray-500 truncate">
                      {report.description}
                      {hasSaved && savedTransmittal?.generated_at && (
                        <span className="text-green-600 ml-1">
                          · Last: {new Date(savedTransmittal.generated_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
                        </span>
                      )}
                    </p>
                  </div>
                  <div className="flex items-center gap-1.5 shrink-0">
                    {hasSaved && (
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => handlePreview(report.key, report.label)}
                        disabled={previewLoading}
                        className="text-xs"
                        title="Edit transmittal settings before generating"
                      >
                        <svg className="w-3.5 h-3.5 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                        </svg>
                        Edit
                      </Button>
                    )}
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => hasSaved ? handleReprint(report.key, report.label) : handlePreview(report.key, report.label)}
                      disabled={previewLoading}
                      className="text-xs"
                    >
                      {previewLoading ? (
                        <span className="flex items-center gap-1">
                          <svg className="animate-spin h-3 w-3" viewBox="0 0 24 24">
                            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                          </svg>
                          Loading...
                        </span>
                      ) : (
                        <>
                          <svg className="w-3.5 h-3.5 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                            <path strokeLinecap="round" strokeLinejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
                          </svg>
                          View
                        </>
                      )}
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleDownload(report.key)}
                      disabled={downloadLoading}
                      className="text-xs"
                      title="Download PDF"
                    >
                      {downloadLoading ? (
                        <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      ) : (
                        <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                        </svg>
                      )}
                    </Button>
                    {canDownloadSpreadsheet && (
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => handleSpreadsheetDownload(report.key)}
                        disabled={spreadsheetLoading}
                        className="text-xs"
                        title="Download Excel"
                      >
                        {spreadsheetLoading ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        ) : (
                          <span className="text-[11px] font-semibold">XLS</span>
                        )}
                      </Button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </Card>

      {/* Check Sign-Off Sheet */}
      <Card className="mt-4">
        <div className="p-4 bg-gray-50 flex items-center justify-between">
          <div className="mr-3 min-w-0">
            <h3 className="font-semibold text-gray-900">Check Sign-Off Sheet</h3>
            <p className="text-sm text-gray-500 mt-0.5 truncate">
              Employee sign-off sheet for check pickup
              {signoffSavedAt && (
                <span className="text-green-600 ml-1">
                  · Last: {new Date(signoffSavedAt).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
                </span>
              )}
            </p>
          </div>
          <div className="flex items-center gap-1.5 shrink-0">
            {signoffSavedAt && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => setSignoffEditor({ open: true, mode: 'view' })}
                className="text-xs"
              >
                <svg className="w-3.5 h-3.5 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                </svg>
                Edit
              </Button>
            )}
            <Button
              variant="outline"
              size="sm"
              onClick={handleSignoffView}
              disabled={signoffLoading}
              className="text-xs"
            >
              {signoffLoading && signoffPdfPreview.open ? (
                <Loader2 className="h-3 w-3 animate-spin mr-1" />
              ) : (
                <svg className="w-3.5 h-3.5 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                  <path strokeLinecap="round" strokeLinejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
                </svg>
              )}
              View
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={handleSignoffDownload}
              disabled={signoffLoading}
              className="text-xs"
            >
              {signoffLoading && !signoffPdfPreview.open ? (
                <Loader2 className="h-3 w-3 animate-spin mr-1" />
              ) : (
                <svg className="w-3.5 h-3.5 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                </svg>
              )}
              Download
            </Button>
          </div>
        </div>
      </Card>

      <PdfPreviewModal
        open={previewState.open}
        onClose={cleanupPreview}
        pdfUrl={previewState.pdfUrl}
        title={previewState.label}
        onDownload={handlePreviewDownload}
        onPrint={handlePreviewPrint}
      />

      <TransmittalEditorModal
        open={transmittalEditor.open}
        onClose={() => setTransmittalEditor({ open: false, key: null, label: '', mode: 'preview' })}
        onGenerate={handleTransmittalGenerate}
        targetLabel={transmittalEditor.label}
        payPeriodId={payPeriodId}
        onOpenForm500={() => setForm500Open(true)}
      />

      <SignoffEditorModal
        open={signoffEditor.open}
        onClose={() => setSignoffEditor({ open: false, mode: 'view' })}
        onGenerate={handleSignoffGenerate}
        payPeriodId={payPeriodId}
      />

      <Form500EditorModal open={form500Open} onClose={() => setForm500Open(false)} payPeriodId={payPeriodId} />

      <PdfPreviewModal
        open={signoffPdfPreview.open}
        onClose={cleanupSignoffPreview}
        pdfUrl={signoffPdfPreview.pdfUrl}
        title="Check Sign-Off Sheet"
        onDownload={() => {
          if (signoffPdfPreview.blobData) {
            downloadBlob(signoffPdfPreview.blobData, 'check_signoff_sheet.pdf');
          }
        }}
        onPrint={() => {
          if (signoffPdfPreview.pdfUrl) {
            const printWindow = window.open(signoffPdfPreview.pdfUrl, '_blank');
            if (printWindow) {
              printWindow.addEventListener('load', () => {
                printWindow.print();
              });
            }
          }
        }}
      />
    </>
  );
}
