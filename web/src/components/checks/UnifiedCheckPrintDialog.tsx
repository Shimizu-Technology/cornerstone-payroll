import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { ReactElement } from 'react';
import { CheckCircle2, Clock3, Download, FileLock2, Maximize2, Plus, Printer, Settings2, ShieldCheck, TriangleAlert } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { checksApi, printerProfilesApi, type PrinterProfile } from '@/services/api';
import type { CheckPrintGeneration, CheckPrintQueueItem, CheckPrintQueueResponse, CheckPrintRun } from '@/types';
import { formatCurrency } from '@/lib/utils';
import { CheckPrintWorkspaceSkeleton } from './CheckPrintWorkspaceSkeleton';
import { InlineCheckNumberField } from './InlineCheckNumberField';
import { OperationStatusPanel } from './OperationStatusPanel';
import { PdfPreviewPlaceholder } from './PdfPreviewPlaceholder';
import { PrinterProfileManagerDialog } from './PrinterProfileManagerDialog';
import { checkNumberValidationError } from './checkNumberDrafts';

interface UnifiedCheckPrintDialogProps {
  open: boolean;
  payPeriodId: number;
  onOpenChange: (open: boolean) => void;
  onConfirmed: () => void;
}

type SourceFilter = 'all' | 'employee' | 'non_employee';
type StatusFilter = 'all' | 'unprinted' | 'printed';
type BusyAction = 'profiles' | 'preview' | 'download' | 'confirm' | null;

function statusBadge(item: CheckPrintQueueItem): ReactElement {
  if (item.status === 'delivered') return <Badge variant="success">Delivered</Badge>;
  if (item.status === 'voided') return <Badge variant="danger">Voided</Badge>;
  if (item.status === 'printed') return <Badge variant="success">Printed ×{item.print_count}</Badge>;
  if (item.status === 'pending') return <Badge variant="warning">Needs number</Badge>;
  return <Badge variant="warning">Unprinted</Badge>;
}

function packageBadge(printRun: CheckPrintRun): ReactElement {
  if (printRun.confirmation_state === 'confirmed') return <Badge variant="success">Confirmed</Badge>;
  if (printRun.confirmation_state === 'outdated') return <Badge variant="danger">Outdated</Badge>;
  if (printRun.confirmation_state === 'verification_required') return <Badge variant="warning">Verify to use</Badge>;
  return <Badge variant="warning">Ready</Badge>;
}

function newIdempotencyKey(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  return `check-package-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function UnifiedCheckPrintDialog({ open, payPeriodId, onOpenChange, onConfirmed }: UnifiedCheckPrintDialogProps) {
  const [queue, setQueue] = useState<CheckPrintQueueResponse | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [sourceFilter, setSourceFilter] = useState<SourceFilter>('all');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('unprinted');
  const [startingSlot, setStartingSlot] = useState(1);
  const [run, setRun] = useState<CheckPrintRun | null>(null);
  const [runs, setRuns] = useState<CheckPrintRun[]>([]);
  const [generation, setGeneration] = useState<CheckPrintGeneration | null>(null);
  const [startingGeneration, setStartingGeneration] = useState(false);
  const [generationStartedAt, setGenerationStartedAt] = useState<number | null>(null);
  const [showLongRunningHint, setShowLongRunningHint] = useState(false);
  const [replacementMode, setReplacementMode] = useState(false);
  const [printerProfiles, setPrinterProfiles] = useState<PrinterProfile[]>([]);
  const [profileManagerOpen, setProfileManagerOpen] = useState(false);
  const [profileLoadError, setProfileLoadError] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewExpanded, setPreviewExpanded] = useState(false);
  const [artifactVerified, setArtifactVerified] = useState(false);
  const [initialLoading, setInitialLoading] = useState(false);
  const [busyAction, setBusyAction] = useState<BusyAction>(null);
  const [error, setError] = useState<string | null>(null);
  const [draftNumbers, setDraftNumbers] = useState<Record<string, string>>({});
  const [savingNumbers, setSavingNumbers] = useState(false);
  const compactPreviewRef = useRef<HTMLIFrameElement>(null);
  const expandedPreviewRef = useRef<HTMLIFrameElement>(null);
  const previewRequestRef = useRef(0);
  const workspaceRequestRef = useRef(0);
  const generationRequestRef = useRef(false);
  const pendingGenerationKeyRef = useRef<{ signature: string; key: string } | null>(null);

  const generationActive = generation?.status === 'queued' || generation?.status === 'processing';
  const activeGenerationId = generationActive ? generation?.id ?? null : null;
  const generationInProgress = generationActive || startingGeneration;
  const editingLocked = Boolean(run) || generationInProgress;
  const compatibleProfiles = useMemo(
    () => printerProfiles.filter((profile) => profile.check_stock_type === queue?.meta.check_stock_type),
    [printerProfiles, queue?.meta.check_stock_type]
  );

  const revokePreview = useCallback(() => {
    setPreviewUrl((url) => {
      if (url) URL.revokeObjectURL(url);
      return null;
    });
  }, []);

  const markRunVerified = useCallback((printRun: CheckPrintRun) => {
    if (printRun.confirmation_state !== 'verification_required') return;
    const verifiedRun: CheckPrintRun = {
      ...printRun,
      confirmation_state: 'ready',
      confirmation_issue: null,
    };
    setRun((current) => current?.id === printRun.id ? verifiedRun : current);
    setRuns((current) => current.map((savedRun) => savedRun.id === printRun.id ? verifiedRun : savedRun));
  }, []);

  const applyQueue = useCallback((data: CheckPrintQueueResponse, options?: { preserveSelection?: boolean; selectKeys?: string[] }) => {
    setQueue(data);
    setDraftNumbers(Object.fromEntries(data.items.map((item) => [item.key, item.check_number || ''])));
    setSelected((current) => {
      const eligible = new Set(data.items.filter((item) => item.eligible && item.status === 'unprinted').map((item) => item.key));
      if (options?.selectKeys) return new Set(options.selectKeys.filter((key) => eligible.has(key)));
      if (!options?.preserveSelection) return new Set(eligible);
      return new Set(Array.from(current).filter((key) => eligible.has(key)));
    });
  }, []);

  const loadQueue = useCallback(async (options?: { preserveSelection?: boolean; selectKeys?: string[] }) => {
    const data = await checksApi.printQueue(payPeriodId);
    applyQueue(data, options);
    return data;
  }, [applyQueue, payPeriodId]);

  const loadPrinterProfiles = useCallback(async () => {
    setProfileLoadError(null);
    try {
      const response = await printerProfilesApi.list();
      setPrinterProfiles(response.printer_profiles);
      return response.printer_profiles;
    } catch (err) {
      setProfileLoadError(err instanceof Error ? err.message : 'Could not load printer profiles.');
      throw err;
    }
  }, []);

  const loadPreview = useCallback(async (printRun: CheckPrintRun) => {
    const requestToken = ++previewRequestRef.current;
    setBusyAction('preview');
    setError(null);
    setArtifactVerified(false);
    revokePreview();
    try {
      const pdf = await checksApi.printRunPdf(printRun.id);
      if (requestToken !== previewRequestRef.current) return;
      setPreviewUrl(URL.createObjectURL(pdf.blob));
      setArtifactVerified(true);
      markRunVerified(printRun);
    } catch (err) {
      if (requestToken !== previewRequestRef.current) return;
      setError(err instanceof Error
        ? `The package was saved, but its preview could not be loaded: ${err.message}`
        : 'The package was saved, but its preview could not be loaded. Retry before confirming it as printed.');
    } finally {
      if (requestToken === previewRequestRef.current) setBusyAction(null);
    }
  }, [markRunVerified, revokePreview]);

  const openSavedRun = useCallback(async (printRun: CheckPrintRun) => {
    setRun(printRun);
    setGeneration(null);
    pendingGenerationKeyRef.current = null;
    setReplacementMode(false);
    setStartingSlot(printRun.starting_slot);
    setSelected(new Set(printRun.manifest.map((entry) => entry.key)));
    setPreviewExpanded(false);
    await loadPreview(printRun);
  }, [loadPreview]);

  const refreshRuns = useCallback(async (
    preferredRunId?: number | null,
    openLatest = false,
    workspaceToken = workspaceRequestRef.current
  ) => {
    const response = await checksApi.printRuns(payPeriodId);
    if (workspaceToken !== workspaceRequestRef.current) return [];
    setRuns(response.check_print_runs);
    const target = preferredRunId
      ? response.check_print_runs.find((savedRun) => savedRun.id === preferredRunId)
      : openLatest ? response.check_print_runs[0] : undefined;
    if (target) await openSavedRun(target);
    return response.check_print_runs;
  }, [openSavedRun, payPeriodId]);

  useEffect(() => () => {
    previewRequestRef.current += 1;
    revokePreview();
  }, [revokePreview]);

  useEffect(() => {
    if (!generationActive || generationStartedAt === null) {
      setShowLongRunningHint(false);
      return undefined;
    }
    const remaining = Math.max(0, 10_000 - (Date.now() - generationStartedAt));
    const timer = window.setTimeout(() => setShowLongRunningHint(true), remaining);
    return () => window.clearTimeout(timer);
  }, [generationActive, generationStartedAt]);

  useEffect(() => {
    if (!open) return;
    const requestToken = ++workspaceRequestRef.current;
    generationRequestRef.current = false;
    pendingGenerationKeyRef.current = null;
    previewRequestRef.current += 1;
    setInitialLoading(true);
    setError(null);
    setQueue(null);
    setRun(null);
    setRuns([]);
    setGeneration(null);
    setGenerationStartedAt(null);
    setStartingGeneration(false);
    setReplacementMode(false);
    setPrinterProfiles([]);
    setProfileLoadError(null);
    setArtifactVerified(false);
    setPreviewExpanded(false);
    revokePreview();

    void (async () => {
      try {
        const profileRequest = printerProfilesApi.list().catch((profileError: unknown) => {
          if (requestToken === workspaceRequestRef.current) {
            setProfileLoadError(profileError instanceof Error ? profileError.message : 'Could not load printer profiles.');
          }
          return null;
        });
        const [queueData, profileResponse, runResponse, generationResponse] = await Promise.all([
          checksApi.printQueue(payPeriodId),
          profileRequest,
          checksApi.printRuns(payPeriodId),
          checksApi.activePrintGeneration(payPeriodId),
        ]);
        if (requestToken !== workspaceRequestRef.current) return;
        applyQueue(queueData);
        setStatusFilter(queueData.meta.unprinted > 0 && runResponse.check_print_runs[0]?.confirmation_state !== 'confirmed' ? 'unprinted' : 'all');
        if (profileResponse) setPrinterProfiles(profileResponse.printer_profiles);
        setRuns(runResponse.check_print_runs);
        if (generationResponse.check_print_generation) {
          setGeneration(generationResponse.check_print_generation);
          setGenerationStartedAt(new Date(generationResponse.check_print_generation.created_at).getTime());
        } else if (runResponse.check_print_runs[0]) {
          await openSavedRun(runResponse.check_print_runs[0]);
        }
      } catch (err) {
        if (requestToken === workspaceRequestRef.current) {
          setError(err instanceof Error ? err.message : 'Could not load the check print workspace.');
        }
      } finally {
        if (requestToken === workspaceRequestRef.current) setInitialLoading(false);
      }
    })();

    return () => {
      workspaceRequestRef.current += 1;
      previewRequestRef.current += 1;
    };
  }, [applyQueue, open, openSavedRun, payPeriodId, revokePreview]);

  useEffect(() => {
    if (!open || activeGenerationId === null) return undefined;
    let cancelled = false;
    let timer: number | undefined;
    const workspaceToken = workspaceRequestRef.current;

    const poll = async (): Promise<void> => {
      try {
        const response = await checksApi.printGeneration(payPeriodId, activeGenerationId);
        if (cancelled) return;
        const next = response.check_print_generation;
        setGeneration(next);
        if (next.status === 'ready' && next.check_print_run_id) {
          await refreshRuns(next.check_print_run_id, false, workspaceToken);
          return;
        }
        if (next.status === 'failed') return;
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Could not refresh package progress.');
      }
      if (!cancelled) timer = window.setTimeout(() => void poll(), document.hidden ? 5000 : 1200);
    };

    timer = window.setTimeout(() => void poll(), 600);
    return () => {
      cancelled = true;
      if (timer) window.clearTimeout(timer);
    };
  }, [activeGenerationId, open, payPeriodId, refreshRuns]);

  const visibleItems = useMemo(() => (queue?.items || []).filter((item) => {
    if (sourceFilter !== 'all' && item.kind !== sourceFilter) return false;
    if (statusFilter === 'unprinted' && item.status !== 'unprinted' && item.status !== 'pending') return false;
    if (statusFilter === 'printed' && item.status !== 'printed') return false;
    return true;
  }), [queue, sourceFilter, statusFilter]);

  const selectedItems = useMemo(() => (queue?.items || []).filter((item) => selected.has(item.key)), [queue, selected]);
  const selectedPrintedItems = selectedItems.filter((item) => item.status === 'printed');
  const generationInputSignature = useMemo(() => JSON.stringify({
    payrollItemIds: selectedItems.filter((item) => item.source_type === 'payroll_item').map((item) => item.source_id),
    nonEmployeeCheckIds: selectedItems.filter((item) => item.source_type === 'non_employee_check').map((item) => item.source_id),
    startingSlot,
    printerProfileId: queue?.meta.printer_profile?.id ?? null,
    printerProfileLockVersion: queue?.meta.printer_profile?.lock_version ?? null,
  }), [queue?.meta.printer_profile?.id, queue?.meta.printer_profile?.lock_version, selectedItems, startingSlot]);

  useEffect(() => {
    pendingGenerationKeyRef.current = null;
  }, [generationInputSignature]);

  const selectedTotal = selectedItems.reduce((sum, item) => sum + Number(item.amount), 0);
  const packageTotal = run ? run.manifest.reduce((sum, item) => sum + Number(item.amount), 0) : selectedTotal;
  const packageRange = run && run.manifest.length > 0
    ? run.manifest.length === 1 ? `#${run.manifest[0].check_number}` : `#${run.manifest[0].check_number}–#${run.manifest.at(-1)?.check_number}`
    : null;
  const numberChanges = useMemo(() => (queue?.items || []).filter((item) =>
    (draftNumbers[item.key] ?? item.check_number ?? '').trim() !== (item.check_number || '').trim()
  ), [draftNumbers, queue]);
  const numberErrors = useMemo(() => {
    const errors: Record<string, string> = {};
    const numberOwners = new Map<string, string[]>();
    (queue?.items || []).forEach((item) => {
      const value = (draftNumbers[item.key] ?? item.check_number ?? '').trim();
      const validationError = checkNumberValidationError(value, item.source_type === 'non_employee_check');
      if (validationError) errors[item.key] = validationError;
      if (value) numberOwners.set(value, [...(numberOwners.get(value) || []), item.key]);
    });
    numberOwners.forEach((keys, number) => {
      if (keys.length > 1) keys.forEach((key) => { errors[key] = `Check #${number} is entered more than once.`; });
    });
    return errors;
  }, [draftNumbers, queue]);
  const hasUnsavedNumbers = numberChanges.length > 0;
  const hasNumberErrors = Object.keys(numberErrors).length > 0;
  const sheetCount = queue?.meta.check_stock_type === 'first_hawaiian_4up'
    ? Math.ceil((Math.max(1, startingSlot) - 1 + selectedItems.length) / 4)
    : selectedItems.length;

  const toggle = (item: CheckPrintQueueItem): void => {
    if (!item.eligible || editingLocked) return;
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(item.key)) next.delete(item.key); else next.add(item.key);
      return next;
    });
  };

  const discardNumberChanges = (): void => {
    setDraftNumbers(Object.fromEntries((queue?.items || []).map((item) => [item.key, item.check_number || ''])));
    setError(null);
  };

  const requestOpenSavedRun = (printRun: CheckPrintRun): void => {
    if (savingNumbers) return;
    if (hasUnsavedNumbers && !window.confirm('Discard the unsaved check-number changes and open this saved package?')) return;
    if (hasUnsavedNumbers) discardNumberChanges();
    void openSavedRun(printRun);
  };

  const saveNumberChanges = async (): Promise<void> => {
    if (!hasUnsavedNumbers || hasNumberErrors) return;
    setSavingNumbers(true);
    setError(null);
    try {
      await checksApi.updateCheckNumbers(payPeriodId, numberChanges.map((item) => ({
        source_type: item.source_type,
        source_id: item.source_id,
        check_number: (draftNumbers[item.key] || '').trim() || null,
      })), 'Saved from the unified check-print worksheet');
      previewRequestRef.current += 1;
      setRun(null);
      setGeneration(null);
      setArtifactVerified(false);
      setPreviewExpanded(false);
      revokePreview();
      await loadQueue({ preserveSelection: true });
      onConfirmed();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the check numbers. No changes were applied.');
    } finally {
      setSavingNumbers(false);
    }
  };

  const requestClose = (): void => {
    if (savingNumbers) return;
    if (hasUnsavedNumbers && !window.confirm('Discard the unsaved check-number changes?')) return;
    discardNumberChanges();
    onOpenChange(false);
  };

  const prepareNewPackage = useCallback(async (replacement: boolean) => {
    const preferredKeys = replacement && run ? run.manifest.map((entry) => entry.key) : undefined;
    previewRequestRef.current += 1;
    setRun(null);
    setGeneration(null);
    setGenerationStartedAt(null);
    setReplacementMode(replacement);
    setArtifactVerified(false);
    setPreviewExpanded(false);
    revokePreview();
    setStatusFilter(queue?.meta.unprinted ? 'unprinted' : 'all');
    setError(null);
    try {
      const refreshedQueue = await loadQueue({ selectKeys: preferredKeys });
      setStatusFilter(refreshedQueue.meta.unprinted > 0 ? 'unprinted' : 'all');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not refresh the current checks.');
    }
  }, [loadQueue, queue?.meta.unprinted, revokePreview, run]);

  const generate = async (): Promise<void> => {
    const printerProfile = queue?.meta.printer_profile;
    if (generationRequestRef.current || selectedItems.length === 0 || !printerProfile || hasUnsavedNumbers || hasNumberErrors || savingNumbers) return;
    if (selectedPrintedItems.length > 0 && !window.confirm(
      `Reprint ${selectedPrintedItems.length} previously printed check${selectedPrintedItems.length === 1 ? '' : 's'}? This creates a new package. If you confirm that package as printed, another print will be recorded for each check.`
    )) return;
    const workspaceToken = workspaceRequestRef.current;
    generationRequestRef.current = true;
    setStartingGeneration(true);
    setError(null);
    setGenerationStartedAt(Date.now());
    try {
      const pendingRequest = pendingGenerationKeyRef.current?.signature === generationInputSignature
        ? pendingGenerationKeyRef.current
        : { signature: generationInputSignature, key: newIdempotencyKey() };
      pendingGenerationKeyRef.current = pendingRequest;
      const response = await checksApi.createPrintGeneration(payPeriodId, {
        idempotencyKey: pendingRequest.key,
        payrollItemIds: selectedItems.filter((item) => item.source_type === 'payroll_item').map((item) => item.source_id),
        nonEmployeeCheckIds: selectedItems.filter((item) => item.source_type === 'non_employee_check').map((item) => item.source_id),
        startingSlot,
        printerProfileId: printerProfile.id,
        printerProfileLockVersion: printerProfile.lock_version,
      });
      if (workspaceToken !== workspaceRequestRef.current) return;
      setGeneration(response.check_print_generation);
      pendingGenerationKeyRef.current = null;
      if (response.check_print_generation.status === 'ready' && response.check_print_generation.check_print_run_id) {
        try {
          await refreshRuns(response.check_print_generation.check_print_run_id, false, workspaceToken);
        } catch (runError) {
          if (workspaceToken === workspaceRequestRef.current) {
            setError(runError instanceof Error
              ? `The package is ready, but its saved record could not be loaded: ${runError.message}`
              : 'The package is ready, but its saved record could not be loaded.');
          }
        }
      }
    } catch (err) {
      if (workspaceToken !== workspaceRequestRef.current) return;
      const active = await checksApi.activePrintGeneration(payPeriodId).catch(() => null);
      if (workspaceToken !== workspaceRequestRef.current) return;
      if (active?.check_print_generation) {
        setGeneration(active.check_print_generation);
        setGenerationStartedAt(new Date(active.check_print_generation.created_at).getTime());
        pendingGenerationKeyRef.current = null;
      } else {
        setGeneration(null);
        setError(err instanceof Error ? err.message : 'Could not start package generation. Your selection is unchanged.');
      }
    } finally {
      if (workspaceToken === workspaceRequestRef.current) {
        generationRequestRef.current = false;
        setStartingGeneration(false);
      }
    }
  };

  const selectPrinterProfile = async (profile: PrinterProfile): Promise<void> => {
    if (!queue || editingLocked) return;
    setBusyAction('profiles');
    setError(null);
    try {
      await printerProfilesApi.selectForMe(queue.meta.check_stock_type, profile.id);
      await loadQueue({ preserveSelection: true });
      await loadPrinterProfiles().catch(() => undefined);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not select the printer profile.');
      throw err;
    } finally {
      setBusyAction(null);
    }
  };

  const createdPrinterProfile = async (profile: PrinterProfile): Promise<void> => {
    setPrinterProfiles((current) => [...current, profile].sort((a, b) => a.name.localeCompare(b.name)));
    await selectPrinterProfile(profile);
  };

  const download = async (): Promise<void> => {
    if (!run) return;
    setBusyAction('download');
    setError(null);
    try {
      const result = await checksApi.printRunPdf(run.id, 'attachment');
      const url = URL.createObjectURL(result.blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = result.filename || run.filename;
      link.click();
      setArtifactVerified(true);
      markRunVerified(run);
      window.setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not download the check package.');
    } finally {
      setBusyAction(null);
    }
  };

  const print = (): void => {
    if (!run || !artifactVerified || !['ready', 'confirmed'].includes(run.confirmation_state)) return;
    const frame = previewExpanded ? expandedPreviewRef.current : compactPreviewRef.current;
    frame?.contentWindow?.print();
  };

  const confirm = async (): Promise<void> => {
    if (!run || run.confirmation_state !== 'ready' || !artifactVerified || !window.confirm(`Confirm that all ${run.selected_count} selected checks printed correctly?`)) return;
    setBusyAction('confirm');
    setError(null);
    try {
      const response = await checksApi.confirmPrintRun(run.id);
      onConfirmed();
      await loadQueue();
      setStatusFilter('all');
      setRun(response.check_print_run);
      setRuns((current) => current.map((savedRun) => savedRun.id === response.check_print_run.id ? response.check_print_run : savedRun));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not confirm the print run.');
    } finally {
      setBusyAction(null);
    }
  };

  return (
    <>
      <Dialog open={open} onOpenChange={(nextOpen) => nextOpen ? onOpenChange(true) : requestClose()} dismissOnEscape={!savingNumbers}>
        <DialogContent className="dialog-wide flex h-[94vh] max-h-[94vh] flex-col overflow-hidden p-0">
          <DialogHeader className="border-b border-slate-800 bg-slate-950 px-6 py-5 text-white">
            <div className="flex items-start justify-between gap-5 pr-8">
              <div>
                <DialogTitle className="text-xl text-white">Print checks</DialogTitle>
                <DialogDescription className="mt-1 max-w-3xl text-slate-300">Generate and save an exact package, print that saved snapshot, then confirm only after the paper is correct.</DialogDescription>
              </div>
              {queue && <div className="hidden shrink-0 font-mono text-xs text-slate-400 sm:block">{queue.meta.check_stock_type.replaceAll('_', ' ').toUpperCase()}</div>}
            </div>
          </DialogHeader>

          {initialLoading ? <CheckPrintWorkspaceSkeleton /> : (
            <div className="min-h-0 flex-1 overflow-y-auto">
              <div className="grid lg:grid-cols-[minmax(0,1fr)_390px]">
                <section className="border-r border-slate-200 p-5 lg:p-6">
                  <div className="mb-5 rounded-2xl border border-blue-200 bg-blue-50 px-4 py-3">
                    <div className="flex items-start gap-3">
                      <FileLock2 aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-blue-700" />
                      <div><p className="text-sm font-semibold text-blue-950">A generated package is a saved snapshot</p><p className="mt-1 text-xs leading-5 text-blue-800">It keeps the selected checks, amounts, payee details, and printer calibration from the moment it was generated. If any of those change, the package becomes outdated and you must generate a replacement.</p></div>
                    </div>
                  </div>

                  <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
                    <div className="flex flex-wrap gap-2">
                      {(['all', 'employee', 'non_employee'] as SourceFilter[]).map((value) => (
                        <Button key={value} size="sm" variant={sourceFilter === value ? 'default' : 'outline'} onClick={() => setSourceFilter(value)}>{value === 'all' ? 'All checks' : value === 'employee' ? 'Employees' : 'Non-employees'}</Button>
                      ))}
                      <select aria-label="Check status" className="min-h-9 rounded-full border border-slate-300 bg-white px-3 text-sm" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as StatusFilter)}><option value="unprinted">Unprinted</option><option value="printed">Printed</option><option value="all">All statuses</option></select>
                    </div>
                    <div className="flex gap-2 text-xs">
                      <button type="button" className="font-semibold text-blue-700 disabled:text-slate-400" disabled={editingLocked} onClick={() => setSelected((current) => { const next = new Set(current); visibleItems.filter((item) => item.eligible).forEach((item) => next.add(item.key)); return next; })}>Select visible</button>
                      <span className="text-slate-300">/</span>
                      <button type="button" className="font-semibold text-slate-600 disabled:text-slate-400" disabled={editingLocked} onClick={() => setSelected(new Set())}>Clear</button>
                    </div>
                  </div>

                  <p className="mb-3 text-xs text-slate-500">Edit check numbers first. The saved package will use exactly the reviewed values shown here.</p>
                  {run?.confirmation_state === 'confirmed' && <div className="mb-4 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-950">Package #{run.id} is confirmed. Its checks now show as printed in this list. The saved PDF remains available on the right.</div>}
                  {!run && queue && queue.meta.unprinted === 0 && queue.items.some((item) => item.status === 'printed' && item.eligible) && <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950">No unprinted checks remain. To create another package, select a printed check below. This is a reprint; confirming the new package records another print. To view the existing PDF, open it in Saved package history.</div>}
                  {hasUnsavedNumbers && (
                    <div className="mb-4 flex flex-col gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                      <div><p className="text-sm font-semibold text-amber-950">{numberChanges.length} unsaved check-number change{numberChanges.length === 1 ? '' : 's'}</p><p className="mt-0.5 text-xs text-amber-800">Save these changes before generating the snapshot.</p></div>
                      <div className="flex gap-2"><Button size="sm" variant="outline" onClick={discardNumberChanges} disabled={savingNumbers}>Discard</Button><Button size="sm" loading={savingNumbers} loadingLabel="Saving…" onClick={() => void saveNumberChanges()} disabled={hasNumberErrors}>Save check numbers</Button></div>
                    </div>
                  )}

                  <div className="overflow-x-auto rounded-2xl border border-slate-200">
                    <table className="w-full min-w-[680px] text-left text-sm">
                      <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="w-10 p-3"/><th className="p-3">Check</th><th className="p-3">Payee</th><th className="p-3">Type</th><th className="p-3">Status</th><th className="p-3 text-right">Amount</th></tr></thead>
                      <tbody className="divide-y divide-slate-100">
                        {visibleItems.map((item) => (
                          <tr key={item.key} className={selected.has(item.key) ? 'bg-blue-50/70' : 'bg-white'}>
                            <td className="p-3"><input type="checkbox" checked={selected.has(item.key)} disabled={!item.eligible || editingLocked} onChange={() => toggle(item)} aria-label={`Select check ${item.check_number}`} /></td>
                            <td className="p-3 text-slate-900"><InlineCheckNumberField value={draftNumbers[item.key] ?? item.check_number ?? ''} ariaLabel={`Check number for ${item.payee}`} disabled={editingLocked || item.status === 'voided' || savingNumbers} allowBlank={item.source_type === 'non_employee_check'} dirty={numberChanges.some((changed) => changed.key === item.key)} error={numberErrors[item.key]} onChange={(value) => setDraftNumbers((current) => ({ ...current, [item.key]: value }))} onReset={() => setDraftNumbers((current) => ({ ...current, [item.key]: item.check_number || '' }))} /></td>
                            <td className="p-3"><div className="font-medium text-slate-900">{item.payee}</div>{item.disabled_reason && <div className="text-xs text-red-600">{item.disabled_reason}</div>}</td>
                            <td className="p-3 text-slate-600">{item.kind_label}</td><td className="p-3">{statusBadge(item)}</td><td className="p-3 text-right font-mono font-semibold">{formatCurrency(item.amount)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    {visibleItems.length === 0 && <div className="p-10 text-center text-sm text-slate-500">{statusFilter === 'unprinted' && queue?.meta.unprinted === 0 ? 'No unprinted checks remain. Choose Printed or All statuses to view previous checks.' : 'No checks match these filters.'}</div>}
                  </div>
                </section>

                <aside className="space-y-4 bg-slate-50 p-5 lg:sticky lg:top-0 lg:self-start">
                  {generation && <OperationStatusPanel generation={generation} showLongRunningHint={showLongRunningHint} onRetry={() => void generate()} retryDisabled={hasUnsavedNumbers || hasNumberErrors || savingNumbers} />}

                  <section className="rounded-2xl border border-slate-200 bg-white p-4">
                    <div className="flex items-center justify-between gap-3"><div className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Printer profile</div>{!run && <Button size="sm" variant="ghost" className="gap-1.5 px-2" onClick={() => setProfileManagerOpen(true)} disabled={!queue || generationInProgress}><Settings2 className="h-3.5 w-3.5" /> Manage</Button>}</div>
                    {run ? (
                      <div className="mt-2"><p className="font-semibold text-slate-950">{run.printer_profile_name || 'Legacy company calibration'}</p><p className="mt-1 text-xs leading-5 text-slate-500">Package snapshot{run.printer_profile_lock_version !== null ? ` · profile version ${run.printer_profile_lock_version}` : ''}. Later profile edits do not change this PDF.</p></div>
                    ) : (
                      <>
                        <select aria-label="Printer profile" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm font-medium text-slate-900" value={queue?.meta.printer_profile?.id ?? ''} onChange={(event) => { const profile = compatibleProfiles.find((candidate) => candidate.id === Number(event.target.value)); if (profile) void selectPrinterProfile(profile); }} disabled={!queue || generationInProgress || busyAction === 'profiles'}>
                          <option value="" disabled>Select a calibrated printer…</option>{compatibleProfiles.map((profile) => <option key={profile.id} value={profile.id}>{profile.name}</option>)}
                        </select>
                        <p className="mt-2 text-xs leading-5 text-slate-500">Profiles are shared by the organization. This selection applies only to you.</p>
                        {profileLoadError && <div className="mt-3 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-900"><p>{profileLoadError}</p><Button className="mt-2" size="sm" variant="outline" loading={busyAction === 'profiles'} loadingLabel="Retrying…" onClick={() => { setBusyAction('profiles'); void loadPrinterProfiles().catch(() => undefined).finally(() => setBusyAction(null)); }}>Retry printer profiles</Button></div>}
                        {!queue?.meta.printer_profile && <button type="button" onClick={() => setProfileManagerOpen(true)} className="mt-3 w-full rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-left text-xs font-medium text-amber-900">Choose or create a printer profile before generating.</button>}
                      </>
                    )}
                  </section>

                  <section className="rounded-2xl border border-slate-200 bg-white p-4">
                    <div className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Package summary</div>
                    <div className="mt-4 grid grid-cols-2 gap-3"><div><div className="text-xs text-slate-500">{run ? 'Checks in package' : 'Selected'}</div><div className="text-2xl font-bold text-slate-950">{run?.selected_count ?? selectedItems.length}</div></div><div><div className="text-xs text-slate-500">Total value</div><div className="text-xl font-bold text-slate-950">{formatCurrency(packageTotal)}</div></div></div>
                    {replacementMode && !run && <p className="mt-3 rounded-lg bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">Review the current checks and printer profile. Generating will save a new replacement; the outdated package stays in history.</p>}
                    {queue?.meta.check_stock_type === 'first_hawaiian_4up' && !run && <div className="mt-5 border-t border-slate-100 pt-4"><div className="mb-2 text-sm font-semibold text-slate-800">First sheet starts at slot</div><div className="grid grid-cols-4 gap-2">{[1, 2, 3, 4].map((slot) => <button type="button" key={slot} disabled={generationInProgress} onClick={() => setStartingSlot(slot)} className={`rounded-lg border py-3 font-mono font-bold ${startingSlot === slot ? 'border-blue-700 bg-blue-700 text-white' : 'border-slate-200 bg-white text-slate-700'}`}>{slot}</button>)}</div><p className="mt-2 text-xs text-slate-500">Estimated stock: {sheetCount} sheet{sheetCount === 1 ? '' : 's'}.</p></div>}
                  </section>

                  {run && (
                    <section className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div className="border-b border-slate-100 p-4">
                        <div className="flex items-start justify-between gap-3"><div><div className="font-semibold text-slate-950">Package #{run.id}</div><div className="mt-1 text-xs text-slate-500">Generated {new Date(run.generated_at).toLocaleString()} {run.created_by_name ? `by ${run.created_by_name}` : ''}</div></div>{packageBadge(run)}</div>
                        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-xs"><div><dt className="text-slate-500">Checks</dt><dd className="mt-0.5 font-semibold text-slate-900">{run.selected_count} · {packageRange}</dd></div><div><dt className="text-slate-500">Total</dt><dd className="mt-0.5 font-semibold text-slate-900">{formatCurrency(packageTotal)}</dd></div><div className="col-span-2"><dt className="text-slate-500">Printer snapshot</dt><dd className="mt-0.5 font-semibold text-slate-900">{run.printer_profile_name || 'Legacy calibration'}{run.printer_profile_lock_version !== null ? ` · version ${run.printer_profile_lock_version}` : ''}</dd></div></dl>
                      </div>
                      {previewUrl ? <div className="relative"><iframe ref={compactPreviewRef} title="Check package preview" src={previewUrl} className="h-72 w-full bg-slate-900" /><Button size="sm" variant="secondary" onClick={() => setPreviewExpanded(true)} className="absolute right-3 top-3 gap-1.5"><Maximize2 className="h-3.5 w-3.5" /> Enlarge</Button></div> : <div><PdfPreviewPlaceholder loading={busyAction === 'preview'} />{busyAction !== 'preview' && <div className="border-b border-slate-100 p-3 text-center"><Button size="sm" variant="outline" onClick={() => void loadPreview(run)}>Retry preview</Button></div>}</div>}
                      <div className="border-t border-blue-100 bg-blue-50 px-4 py-3 text-xs leading-5 text-blue-950"><span className="font-semibold">Printer setup:</span> Letter paper, Actual Size / 100% scale, headers and footers off. Never use Fit or Shrink.</div>
                      <div className="grid grid-cols-2 gap-2 p-4"><Button variant="outline" onClick={print} disabled={!previewUrl || !artifactVerified || !['ready', 'confirmed'].includes(run.confirmation_state)}>Print saved PDF</Button><Button variant="outline" loading={busyAction === 'download'} loadingLabel="Preparing…" onClick={() => void download()}>Download</Button></div>
                      {run.confirmation_state === 'outdated' && <div className="border-t border-amber-200 bg-amber-50 px-4 py-3 text-xs leading-5 text-amber-950"><div className="flex items-start gap-2"><TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" /><span><strong>This package is outdated.</strong> {run.confirmation_issue} It remains available for audit history, but it cannot be printed or confirmed. Generate a replacement from current data.</span></div></div>}
                      <details className="border-t border-slate-100 px-4 py-3 text-xs text-slate-600"><summary className="cursor-pointer font-semibold text-slate-700">Audit details</summary><div className="mt-2 space-y-1 break-all font-mono"><p>File: {run.filename}</p><p>SHA-256: {run.sha256}</p><p>Bytes: {run.byte_size.toLocaleString()}</p></div></details>
                    </section>
                  )}

                  {error && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</div>}
                  {run?.requires_distinct_confirmer && !run.can_current_user_confirm && run.confirmation_state === 'ready' && <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-5 text-warning-900">This client requires a second person to confirm printing. Ask another authorized payroll operator to open this package.</div>}

                  {runs.length > 0 && (
                    <section className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div className="border-b border-slate-100 px-4 py-3"><div className="flex items-center gap-2 text-sm font-semibold text-slate-900"><Clock3 className="h-4 w-4" />Saved package history</div><p className="mt-1 text-xs text-slate-500">Every package is retained as an immutable payroll record.</p></div>
                      <div className="divide-y divide-slate-100">{runs.map((savedRun) => <button key={savedRun.id} type="button" onClick={() => requestOpenSavedRun(savedRun)} disabled={busyAction === 'preview' || savingNumbers} className={`flex w-full items-center justify-between gap-2 px-4 py-4 text-left transition-colors hover:bg-slate-50 ${run?.id === savedRun.id ? 'bg-blue-50' : ''}`}><span><span className="block text-sm font-semibold text-slate-900">Package #{savedRun.id} · {savedRun.selected_count} checks</span><span className="mt-1 block text-xs text-slate-500">{new Date(savedRun.generated_at).toLocaleString()}</span></span>{packageBadge(savedRun)}</button>)}</div>
                    </section>
                  )}
                </aside>
              </div>
            </div>
          )}

          <DialogFooter className="border-t border-slate-200 bg-white px-6 py-4">
            {generationActive && <p className="mr-auto self-center text-xs text-slate-500">Safe to close — generation will continue in the background.</p>}
            <Button variant="outline" onClick={requestClose}>Close</Button>
            {!run && !generationActive && <Button loading={startingGeneration} loadingLabel="Starting generation…" onClick={() => void generate()} disabled={selectedItems.length === 0 || !queue?.meta.printer_profile || savingNumbers || hasUnsavedNumbers}>{replacementMode ? 'Generate replacement package' : 'Generate and save package'}</Button>}
            {generationActive && <Button loading loadingLabel="Generating package…">Generating package…</Button>}
            {run && run.confirmation_state !== 'outdated' && <Button variant="outline" onClick={() => void prepareNewPackage(false)} className="gap-2"><Plus className="h-4 w-4" />Create another package</Button>}
            {run?.confirmation_state === 'outdated' && <Button onClick={() => void prepareNewPackage(true)}>Generate replacement package</Button>}
            {run?.confirmation_state === 'ready' && <Button loading={busyAction === 'confirm'} loadingLabel="Recording confirmation…" onClick={() => void confirm()} disabled={!artifactVerified || !run.can_current_user_confirm}>Confirm printed correctly</Button>}
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {queue && <PrinterProfileManagerDialog open={profileManagerOpen} stockType={queue.meta.check_stock_type} profiles={compatibleProfiles} selectedProfileId={queue.meta.printer_profile?.id ?? null} onOpenChange={setProfileManagerOpen} onSelected={selectPrinterProfile} onCreated={createdPrinterProfile} />}

      <Dialog open={previewExpanded && Boolean(previewUrl)} onOpenChange={setPreviewExpanded} dismissOnEscape={busyAction !== 'download'}>
        <DialogContent className="dialog-wide flex h-[94vh] max-h-[94vh] flex-col overflow-hidden p-0">
          <DialogHeader className="border-b border-slate-800 bg-slate-950 px-6 py-4 text-white"><div className="flex items-center justify-between gap-6 pr-8"><div className="min-w-0"><DialogTitle className="text-lg text-white">Inspect package #{run?.id}</DialogTitle><DialogDescription className="mt-1 flex items-center gap-1.5 text-slate-300"><ShieldCheck className="h-3.5 w-3.5 text-emerald-400" />Integrity verified · Review every check before confirming.</DialogDescription></div><div className="hidden shrink-0 items-center gap-2 text-xs text-slate-400 sm:flex"><CheckCircle2 className="h-4 w-4 text-emerald-400" />{run?.selected_count} CHECK{run?.selected_count === 1 ? '' : 'S'}</div></div></DialogHeader>
          {previewUrl && <iframe ref={expandedPreviewRef} title="Expanded check package preview" src={previewUrl} className="min-h-0 w-full flex-1 bg-slate-900" />}
          <DialogFooter className="border-t border-slate-200 bg-white px-6 py-4"><Button variant="outline" onClick={() => setPreviewExpanded(false)}>Return to package</Button><Button variant="outline" onClick={print} disabled={!previewUrl || !artifactVerified || !run || !['ready', 'confirmed'].includes(run.confirmation_state)} className="gap-2"><Printer className="h-4 w-4" />Print saved PDF</Button><Button variant="outline" loading={busyAction === 'download'} loadingLabel="Preparing…" onClick={() => void download()} className="gap-2"><Download className="h-4 w-4" />Download</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
