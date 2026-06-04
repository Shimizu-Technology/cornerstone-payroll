/**
 * CPR-66: Check Settings Page
 * Operator-level configuration for check printing: offsets, stock type, next check number.
 */
import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { createPortal } from 'react-dom';
import { Download } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { NumericInput } from '@/components/ui/numeric-input';
import { Textarea } from '@/components/ui/textarea';
import { Card, CardContent } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { CheckLayoutEditor } from '@/components/checks/CheckLayoutEditor';
import { checksApi, printerProfilesApi } from '@/services/api';
import type { PrinterProfile } from '@/services/api';
import type { CheckLayoutResponse, CheckSettings as CheckSettingsType, CheckStockType } from '@/types';

type TestCheckType = 'payroll' | 'fit' | 'grt' | 'vendor';

function checkSettingsSnapshot(values: {
  stockType: CheckStockType;
  offsetX: string;
  offsetY: string;
  bankName: string;
  bankAddress: string;
  layoutOverridesJson: string;
  memoTemplate: string;
  autoCreateFitCheck: boolean;
}) {
  return JSON.stringify(values);
}

function parseOffsetInput(value: string): number {
  const trimmed = value.trim();
  if (trimmed === '') return 0;
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed)) throw new Error('X and Y offsets must be numbers.');
  return parsed;
}

function comparableOffset(value: string): string | null {
  try {
    return parseOffsetInput(value).toFixed(3);
  } catch {
    return null;
  }
}

function stableLayoutJson(value: unknown): string {
  if (!value || typeof value !== 'object') return '{}';
  const normalize = (input: unknown): unknown => {
    if (Array.isArray(input)) return input.map(normalize);
    if (!input || typeof input !== 'object') return input;

    return Object.keys(input as Record<string, unknown>)
      .sort()
      .reduce<Record<string, unknown>>((acc, key) => {
        acc[key] = normalize((input as Record<string, unknown>)[key]);
        return acc;
      }, {});
  };
  return JSON.stringify(normalize(value));
}

export function CheckSettingsPage() {
  const skipNextLayoutEffectRef = useRef(false);
  const [settings, setSettings] = useState<CheckSettingsType | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  // Editable form state
  const [stockType, setStockType] = useState<CheckStockType>('top_check');
  const [offsetX, setOffsetX] = useState('0.000');
  const [offsetY, setOffsetY] = useState('0.000');
  const [bankName, setBankName] = useState('');
  const [bankAddress, setBankAddress] = useState('');
  const [layoutOverridesJson, setLayoutOverridesJson] = useState('{}');
  const [memoTemplate, setMemoTemplate] = useState('');
  const [autoCreateFitCheck, setAutoCreateFitCheck] = useState(false);
  const [nextCheckNumber, setNextCheckNumber] = useState('');
  const [nextCheckNumberSaving, setNextCheckNumberSaving] = useState(false);
  const [downloadingAlignment, setDownloadingAlignment] = useState(false);
  const [checkLayout, setCheckLayout] = useState<CheckLayoutResponse | null>(null);
  const [savedSettingsSnapshot, setSavedSettingsSnapshot] = useState<string | null>(null);
  const [testCheckType, setTestCheckType] = useState<TestCheckType>('payroll');
  const [generatingTestCheck, setGeneratingTestCheck] = useState(false);
  const [testCheckPreviewUrl, setTestCheckPreviewUrl] = useState<string | null>(null);
  const [testCheckPreviewFilename, setTestCheckPreviewFilename] = useState('test_check.pdf');
  const [activePrinterProfileId, setActivePrinterProfileId] = useState<number | null>(null);
  const [activePrinterProfileName, setActivePrinterProfileName] = useState<string | null>(null);

  // Printer profiles
  const [profiles, setProfiles] = useState<PrinterProfile[]>([]);
  const [showAddProfile, setShowAddProfile] = useState(false);
  const [newProfileName, setNewProfileName] = useState('');
  const [newProfileDescription, setNewProfileDescription] = useState('');
  const [newProfileNotes, setNewProfileNotes] = useState('');
  const [editingProfileId, setEditingProfileId] = useState<number | null>(null);
  const [editProfileName, setEditProfileName] = useState('');
  const [editProfileDescription, setEditProfileDescription] = useState('');
  const [editProfileNotes, setEditProfileNotes] = useState('');
  const [profileSaving, setProfileSaving] = useState(false);
  const [profileApplyingAllId, setProfileApplyingAllId] = useState<number | null>(null);

  const currentSettingsSnapshot = useMemo(() => checkSettingsSnapshot({
    stockType,
    offsetX,
    offsetY,
    bankName,
    bankAddress,
    layoutOverridesJson,
    memoTemplate,
    autoCreateFitCheck,
  }), [stockType, offsetX, offsetY, bankName, bankAddress, layoutOverridesJson, memoTemplate, autoCreateFitCheck]);

  const hasUnsavedCheckSettings = savedSettingsSnapshot !== null && currentSettingsSnapshot !== savedSettingsSnapshot;

  const applySettingsToForm = useCallback((s: CheckSettingsType) => {
    const normalizedOffsetX = typeof s.check_offset_x === 'number'
      ? s.check_offset_x
      : Number(s.check_offset_x || 0);
    const normalizedOffsetY = typeof s.check_offset_y === 'number'
      ? s.check_offset_y
      : Number(s.check_offset_y || 0);
    const nextOffsetX = normalizedOffsetX.toFixed(3);
    const nextOffsetY = normalizedOffsetY.toFixed(3);
    const nextBankName = s.bank_name ?? '';
    const nextBankAddress = s.bank_address ?? '';
    const nextLayoutOverridesJson = JSON.stringify(s.check_layout_config ?? {}, null, 2);
    const nextMemoTemplate = s.check_memo_template ?? '';
    const nextAutoCreateFitCheck = s.auto_create_fit_check ?? false;

    setSettings(s);
    setStockType(s.check_stock_type);
    setOffsetX(nextOffsetX);
    setOffsetY(nextOffsetY);
    setBankName(nextBankName);
    setBankAddress(nextBankAddress);
    setLayoutOverridesJson(nextLayoutOverridesJson);
    setMemoTemplate(nextMemoTemplate);
    setAutoCreateFitCheck(nextAutoCreateFitCheck);
    setNextCheckNumber(String(s.next_check_number));
    setActivePrinterProfileId(s.active_printer_profile_id ?? null);
    setActivePrinterProfileName(s.active_printer_profile_name ?? null);
    setSavedSettingsSnapshot(checkSettingsSnapshot({
      stockType: s.check_stock_type,
      offsetX: nextOffsetX,
      offsetY: nextOffsetY,
      bankName: nextBankName,
      bankAddress: nextBankAddress,
      layoutOverridesJson: nextLayoutOverridesJson,
      memoTemplate: nextMemoTemplate,
      autoCreateFitCheck: nextAutoCreateFitCheck,
    }));
  }, []);

  useEffect(() => {
    if (!hasUnsavedCheckSettings) return;

    const handleBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = '';
    };

    window.addEventListener('beforeunload', handleBeforeUnload);
    return () => window.removeEventListener('beforeunload', handleBeforeUnload);
  }, [hasUnsavedCheckSettings]);

  useEffect(() => {
    if (!activePrinterProfileId) {
      setActivePrinterProfileName(null);
      return;
    }

    const activeProfile = profiles.find((profile) => profile.id === activePrinterProfileId);
    if (activeProfile) setActivePrinterProfileName(activeProfile.name);
  }, [activePrinterProfileId, profiles]);

  useEffect(() => {
    if (!hasUnsavedCheckSettings) return;

    const handleDocumentClick = (event: MouseEvent) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const target = event.target instanceof Element ? event.target : null;
      const anchor = target?.closest('a[href]') as HTMLAnchorElement | null;
      if (!anchor || (anchor.target && anchor.target !== '_self')) return;

      const nextUrl = new URL(anchor.href, window.location.href);
      if (nextUrl.origin !== window.location.origin) return;
      if (
        nextUrl.pathname === window.location.pathname &&
        nextUrl.search === window.location.search &&
        nextUrl.hash === window.location.hash
      ) return;

      if (!window.confirm('You have unsaved check setting changes. Leave this page and discard them?')) {
        event.preventDefault();
        event.stopPropagation();
      }
    };

    document.addEventListener('click', handleDocumentClick, true);
    return () => document.removeEventListener('click', handleDocumentClick, true);
  }, [hasUnsavedCheckSettings]);

  useEffect(() => {
    return () => {
      if (testCheckPreviewUrl) URL.revokeObjectURL(testCheckPreviewUrl);
    };
  }, [testCheckPreviewUrl]);

  const confirmDiscardUnsavedChanges = useCallback((message: string) => {
    return !hasUnsavedCheckSettings || window.confirm(message);
  }, [hasUnsavedCheckSettings]);

  const loadProfiles = useCallback(async () => {
    try {
      const data = await printerProfilesApi.list();
      setProfiles(data.printer_profiles);
      setActivePrinterProfileId(data.active_printer_profile_id ?? null);
    } catch {
      // Non-critical — profiles section just stays empty
    }
  }, []);

  const loadCheckLayout = useCallback(async (selectedStockType = stockType) => {
    try {
      const data = await checksApi.getLayout(selectedStockType);
      setCheckLayout(data.check_layout);
    } catch {
      setCheckLayout(null);
    }
  }, [stockType]);

  useEffect(() => {
    (async () => {
      try {
        const data = await checksApi.getSettings();
        applySettingsToForm(data.check_settings);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load settings');
      } finally {
        setLoading(false);
      }
      loadProfiles();
    })();
  }, [applySettingsToForm, loadProfiles]);

  useEffect(() => {
    if (!loading) {
      if (skipNextLayoutEffectRef.current) {
        skipNextLayoutEffectRef.current = false;
        return;
      }
      loadCheckLayout(stockType);
    }
  }, [stockType, loading, loadCheckLayout]);

  const activeProfile = useMemo(
    () => profiles.find((profile) => profile.id === activePrinterProfileId) || null,
    [activePrinterProfileId, profiles]
  );

  const parsedLayoutOverrides = useMemo(() => {
    try {
      const parsed = JSON.parse(layoutOverridesJson || '{}');
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
        ? parsed as Record<string, unknown>
        : null;
    } catch {
      return null;
    }
  }, [layoutOverridesJson]);

  const handleVisualLayoutChange = useCallback((config: Record<string, unknown>) => {
    setLayoutOverridesJson(JSON.stringify(config, null, 2));
    setError(null);
    setSuccess(null);
  }, []);

  const handleVisualOffsetChange = useCallback((axis: 'x' | 'y', value: string) => {
    if (axis === 'x') {
      setOffsetX(value);
    } else {
      setOffsetY(value);
    }
    setSuccess(null);
  }, []);

  const handleSaveSettings = async () => {
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      let parsedLayoutOverrides: Record<string, unknown> = {};
      try {
        const parsed = JSON.parse(layoutOverridesJson || '{}');
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          throw new Error('Advanced layout overrides must be a JSON object.');
        }
        parsedLayoutOverrides = parsed as Record<string, unknown>;
      } catch (parseError) {
        setError(parseError instanceof Error ? parseError.message : 'Invalid JSON in advanced layout overrides.');
        setSaving(false);
        return;
      }

      const data = await checksApi.updateSettings({
        check_stock_type: stockType,
        check_offset_x: parseOffsetInput(offsetX),
        check_offset_y: parseOffsetInput(offsetY),
        bank_name: bankName.trim() || null,
        bank_address: bankAddress.trim() || null,
        check_memo_template: memoTemplate.trim() || null,
        auto_create_fit_check: autoCreateFitCheck,
        check_layout_config: parsedLayoutOverrides,
      });
      applySettingsToForm(data.check_settings);
      await loadCheckLayout(stockType);
      setSuccess(data.check_settings.active_printer_profile_id ? 'Settings saved for this client.' : 'Custom check settings saved for this client.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save settings');
    } finally {
      setSaving(false);
    }
  };

  const handleUpdateNextCheckNumber = async () => {
    const num = parseInt(nextCheckNumber, 10);
    if (!num || num < 1) {
      setError('Next check number must be a positive integer.');
      return;
    }
    if (!window.confirm(`Set the next check number to ${num}? This is only allowed when no checks have been issued this calendar year.`)) return;
    setNextCheckNumberSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const data = await checksApi.updateNextCheckNumber(num);
      setSettings(data.check_settings);
      setNextCheckNumber(String(data.check_settings.next_check_number));
      setSuccess('Starting check number updated.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update check number');
    } finally {
      setNextCheckNumberSaving(false);
    }
  };

  const handleAlignmentTest = async () => {
    setError(null);
    setDownloadingAlignment(true);
    try {
      const blob = await checksApi.alignmentTestPdf();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'alignment_test.pdf';
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download alignment test PDF');
    } finally {
      setDownloadingAlignment(false);
    }
  };

  const parseLayoutOverridesForAction = () => {
    const parsed = JSON.parse(layoutOverridesJson || '{}');
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('Advanced layout overrides must be a JSON object.');
    }
    return parsed as Record<string, unknown>;
  };

  const currentDraftCheckSettings = (layoutConfig: Record<string, unknown>) => ({
    check_stock_type: stockType,
    check_offset_x: parseOffsetInput(offsetX),
    check_offset_y: parseOffsetInput(offsetY),
    bank_name: bankName.trim() || null,
    bank_address: bankAddress.trim() || null,
    check_memo_template: memoTemplate.trim() || null,
    check_layout_config: layoutConfig,
  });

  const handleTestCheckPdf = async () => {
    setError(null);
    setSuccess(null);
    try {
      const layoutConfig = parseLayoutOverridesForAction();
      setGeneratingTestCheck(true);
      const { blob, filename } = await checksApi.testCheckPdf({
        sample_type: testCheckType,
        check_settings: currentDraftCheckSettings(layoutConfig),
      });
      if (testCheckPreviewUrl) URL.revokeObjectURL(testCheckPreviewUrl);
      setTestCheckPreviewUrl(URL.createObjectURL(blob));
      setTestCheckPreviewFilename(filename || `test_check_${testCheckType}.pdf`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate test check PDF');
    } finally {
      setGeneratingTestCheck(false);
    }
  };

  const handleCloseTestCheckPreview = () => {
    if (testCheckPreviewUrl) URL.revokeObjectURL(testCheckPreviewUrl);
    setTestCheckPreviewUrl(null);
  };

  const handleDownloadTestCheckPreview = () => {
    if (!testCheckPreviewUrl) return;
    const a = document.createElement('a');
    a.href = testCheckPreviewUrl;
    a.download = testCheckPreviewFilename;
    a.click();
  };

  const handlePrintTestCheckPreview = () => {
    if (!testCheckPreviewUrl) return;
    const printWindow = window.open(testCheckPreviewUrl);
    if (printWindow) {
      printWindow.addEventListener('load', () => {
        printWindow.print();
      });
    } else {
      setError('Pop-up blocked. Please allow pop-ups for this site to print checks.');
    }
  };

  const handleSaveCurrentAsProfile = async () => {
    if (!newProfileName.trim()) { setError('Profile name is required.'); return; }
    setProfileSaving(true);
    setError(null);
    let layoutConfig: Record<string, unknown>;
    try {
      layoutConfig = JSON.parse(layoutOverridesJson || '{}');
    } catch {
      setError('Invalid JSON in advanced layout overrides. Please fix it before saving.');
      setProfileSaving(false);
      return;
    }
    try {
      await printerProfilesApi.create({
        name: newProfileName.trim(),
        description: newProfileDescription.trim() || null,
        notes: newProfileNotes.trim() || null,
        check_stock_type: stockType,
        check_offset_x: parseOffsetInput(offsetX),
        check_offset_y: parseOffsetInput(offsetY),
        check_layout_config: layoutConfig,
      });
      setNewProfileName('');
      setNewProfileDescription('');
      setNewProfileNotes('');
      setShowAddProfile(false);
      setSuccess('Printer profile saved.');
      loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save profile');
    } finally {
      setProfileSaving(false);
    }
  };

  const handleApplyProfile = async (profile: PrinterProfile) => {
    if (!confirmDiscardUnsavedChanges(`You have unsaved check setting changes. Applying "${profile.name}" will replace them with that printer profile. Continue?`)) return;

    setError(null);
    try {
      await printerProfilesApi.apply(profile.id);
      const data = await checksApi.getSettings();
      if (data.check_settings.check_stock_type !== stockType) {
        skipNextLayoutEffectRef.current = true;
      }
      applySettingsToForm(data.check_settings);
      await loadCheckLayout(data.check_settings.check_stock_type);
      setSuccess(`Applied profile "${profile.name}". Settings are now active.`);
      await loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply profile');
    }
  };

  const handleApplyProfileToAllCompanies = async (profile: PrinterProfile) => {
    const message = `Use "${profile.name}" for every client in this organization? This updates each client's check stock, alignment, and active printer profile.`;
    if (!window.confirm(message)) return;

    setError(null);
    setSuccess(null);
    setProfileApplyingAllId(profile.id);
    try {
      const result = await printerProfilesApi.applyToAllCompanies(profile.id);
      const data = await checksApi.getSettings();
      if (data.check_settings.check_stock_type !== stockType) {
        skipNextLayoutEffectRef.current = true;
      }
      applySettingsToForm(data.check_settings);
      await loadCheckLayout(data.check_settings.check_stock_type);
      setSuccess(`Applied "${profile.name}" to ${result.applied_count} client${result.applied_count === 1 ? '' : 's'}.`);
      await loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply printer profile to all clients');
    } finally {
      setProfileApplyingAllId(null);
    }
  };

  const handleClearActiveProfile = async () => {
    if (!window.confirm('Stop using a saved printer profile for this client? Current check settings will stay as-is.')) return;
    setError(null);
    setSuccess(null);
    try {
      const data = await printerProfilesApi.clearActive();
      setActivePrinterProfileId(null);
      setActivePrinterProfileName(null);
      setSettings((current) => current ? { ...current, ...data.check_settings } : current);
      setSuccess('No printer profile is selected for this client. Current check settings were kept.');
      await loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to clear active printer profile');
    }
  };

  const handleUpdateProfile = async (id: number) => {
    if (!editProfileName.trim()) { setError('Profile name is required.'); return; }
    setProfileSaving(true);
    setError(null);
    try {
      await printerProfilesApi.update(id, {
        name: editProfileName.trim(),
        description: editProfileDescription.trim() || null,
        notes: editProfileNotes.trim() || null,
      });
      setEditingProfileId(null);
      setSuccess('Profile updated.');
      loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update profile');
    } finally {
      setProfileSaving(false);
    }
  };

  const handleDeleteProfile = async (id: number, name: string) => {
    if (!window.confirm(`Delete printer profile "${name}"?`)) return;
    try {
      await printerProfilesApi.delete(id);
      setSuccess('Profile deleted.');
      loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete profile');
    }
  };

  const handleOverwriteProfile = async (profile: PrinterProfile) => {
    if (!window.confirm(`Overwrite "${profile.name}" with current settings?`)) return;
    setError(null);
    let layoutConfig: Record<string, unknown>;
    try {
      layoutConfig = JSON.parse(layoutOverridesJson || '{}');
    } catch {
      setError('Invalid JSON in advanced layout overrides. Please fix it before overwriting.');
      return;
    }
    try {
      await printerProfilesApi.update(profile.id, {
        check_stock_type: stockType,
        check_offset_x: parseOffsetInput(offsetX),
        check_offset_y: parseOffsetInput(offsetY),
        check_layout_config: layoutConfig,
      });
      setSuccess(`Profile "${profile.name}" updated with current settings.`);
      loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update profile');
    }
  };

  const handleResetAdvancedOverrides = () => {
    setLayoutOverridesJson('{}');
    setSuccess(null);
    setError(null);
  };

  const handleClearProfileCalibration = () => {
    setOffsetX('0.000');
    setOffsetY('0.000');
    setLayoutOverridesJson('{}');
    setActivePrinterProfileId(null);
    setActivePrinterProfileName(null);
    setSuccess('Calibration draft reset to defaults. Click Save Settings to save this custom setup for the active client.');
    setError(null);
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Header title="Check Settings" />
        <div className="p-8 text-center text-gray-500">Loading…</div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      <Header title="Check Printing Settings" />

      <div className="mx-auto max-w-6xl space-y-6 p-4 sm:p-6 lg:p-8">

        {/* Feedback */}
        {error && (
          <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-800">{error}</div>
        )}
        {success && (
          <div className="p-3 bg-green-50 border border-green-200 rounded-lg text-sm text-green-800">{success}</div>
        )}
        {hasUnsavedCheckSettings && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
            You have unsaved check setting changes. They are only in this browser until you click <strong>Save Settings</strong>.
          </div>
        )}

        <Card className="overflow-hidden border-slate-200 bg-white">
          <div className="border-b bg-gradient-to-r from-slate-900 to-slate-700 px-5 py-4 text-white">
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-300">Current printer source</p>
            <h2 className="mt-1 text-lg font-semibold">
              {activeProfile ? activeProfile.name : 'Custom settings for this client'}
            </h2>
            <p className="mt-1 max-w-3xl text-sm text-slate-200">
              {activeProfile
                ? 'This client is using a shared organization printer profile. Use “Use for all clients” if this same office printer should follow you across every client.'
                : 'No shared printer profile is selected. Save works as a client-specific custom override until you choose or create a printer profile.'}
            </p>
          </div>
          <CardContent className="grid gap-3 p-4 text-sm md:grid-cols-3">
            <div className="rounded-xl border border-slate-200 bg-slate-50 px-4 py-3">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Stock</p>
              <p className="mt-1 font-semibold text-slate-900">{stockType === 'first_hawaiian_4up' ? 'First Hawaiian 4-Up' : stockType === 'top_check' ? 'Top Check' : 'Bottom Check'}</p>
            </div>
            <div className="rounded-xl border border-slate-200 bg-slate-50 px-4 py-3">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Alignment</p>
              <p className="mt-1 font-mono font-semibold text-slate-900">X {offsetX || '0.000'} / Y {offsetY || '0.000'}</p>
            </div>
            <div className="rounded-xl border border-slate-200 bg-slate-50 px-4 py-3">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Save button</p>
              <p className="mt-1 font-semibold text-slate-900">Saves this client’s active settings</p>
            </div>
          </CardContent>
        </Card>

        {/* Printer Profiles */}
        <Card>
          <div className="flex flex-col gap-4 border-b p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 className="font-semibold text-gray-900">Printer Profiles</h2>
              <p className="text-sm text-gray-500 mt-0.5">
                Save and switch between alignment settings for different printers.
              </p>
              <p className="text-xs text-blue-700 mt-1">
                These profiles are shared with everyone in your organization &mdash; calibrate
                an office printer once and reuse it across clients. <span className="font-medium">Use for this client</span>
                {' '}updates only the active client; <span className="font-medium">Use for all clients</span> applies the same printer everywhere.
              </p>
              <p className="mt-2 text-sm">
                {activePrinterProfileId ? (
                  <span className="inline-flex items-center rounded-md border border-green-200 bg-green-50 px-2 py-1 font-medium text-green-800">
                    Active printer: {activePrinterProfileName || activeProfile?.name || 'Selected profile'}
                  </span>
                ) : (
                  <span className="inline-flex items-center rounded-md border border-slate-200 bg-slate-50 px-2 py-1 font-medium text-slate-700">
                    No saved printer profile selected
                  </span>
                )}
              </p>
            </div>
            <div className="grid grid-cols-1 gap-2 sm:flex sm:flex-wrap sm:justify-end [&>button]:w-full sm:[&>button]:w-auto">
              <Button variant="outline" size="sm" onClick={handleClearActiveProfile} disabled={!activePrinterProfileId}>
                Use No Printer Profile
              </Button>
              <Button variant="outline" size="sm" onClick={handleClearProfileCalibration}>
                Reset Calibration Draft
              </Button>
              <Button variant="outline" size="sm" onClick={() => setShowAddProfile(!showAddProfile)}>
                {showAddProfile ? 'Cancel' : '+ Save Current as Profile'}
              </Button>
            </div>
          </div>
          <CardContent className="p-4 space-y-3">
            {showAddProfile && (
              <div className="rounded-lg border border-blue-200 bg-blue-50 p-3 space-y-2">
                <p className="text-sm font-medium text-blue-900">Save current settings as a new printer profile</p>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <div>
                    <Label className="text-xs">Profile Name *</Label>
                    <Input
                      value={newProfileName}
                      onChange={(e) => setNewProfileName(e.target.value)}
                      placeholder="e.g., Office HP LaserJet"
                    />
                  </div>
                  <div>
                    <Label className="text-xs">Description</Label>
                    <Input
                      value={newProfileDescription}
                      onChange={(e) => setNewProfileDescription(e.target.value)}
                      placeholder="e.g., Main office printer"
                    />
                  </div>
                </div>
                <div>
                  <Label className="text-xs">Notes / Print Instructions</Label>
                  <Textarea
                    value={newProfileNotes}
                    onChange={(e) => setNewProfileNotes(e.target.value)}
                    placeholder="e.g., Set browser print to 'Fit to page', use tray 2 for check stock"
                    className="min-h-[60px] text-sm"
                  />
                </div>
                <div className="flex justify-end">
                  <Button size="sm" onClick={handleSaveCurrentAsProfile} disabled={profileSaving}>
                    {profileSaving ? 'Saving...' : 'Save Profile'}
                  </Button>
                </div>
              </div>
            )}

            {profiles.length === 0 && !showAddProfile && (
              <p className="text-sm text-gray-400 italic">No printer profiles saved yet. Save your current settings as a profile to get started.</p>
            )}

            {profiles.map((profile) => {
              const currentOffsetX = comparableOffset(offsetX);
              const currentOffsetY = comparableOffset(offsetY);
              const profileValuesMatchCurrent =
                profile.check_stock_type === stockType &&
                currentOffsetX !== null &&
                currentOffsetY !== null &&
                Number(profile.check_offset_x).toFixed(3) === currentOffsetX &&
                Number(profile.check_offset_y).toFixed(3) === currentOffsetY &&
                stableLayoutJson(profile.check_layout_config || {}) === stableLayoutJson(parsedLayoutOverrides || {});
              const profileMatchesCurrent = activePrinterProfileId === profile.id;
              const hasCustomLayout = stableLayoutJson(profile.check_layout_config || {}) !== '{}';
              return (
              <div key={profile.id} className={`rounded-lg border p-3 transition-colors ${profileMatchesCurrent ? 'border-blue-300 bg-blue-50/50' : 'hover:bg-gray-50'}`}>
                {editingProfileId === profile.id ? (
                  <div className="space-y-2">
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                      <div>
                        <Label className="text-xs">Name</Label>
                        <Input value={editProfileName} onChange={(e) => setEditProfileName(e.target.value)} />
                      </div>
                      <div>
                        <Label className="text-xs">Description</Label>
                        <Input value={editProfileDescription} onChange={(e) => setEditProfileDescription(e.target.value)} />
                      </div>
                    </div>
                    <div>
                      <Label className="text-xs">Notes</Label>
                      <Textarea value={editProfileNotes} onChange={(e) => setEditProfileNotes(e.target.value)} className="min-h-[60px] text-sm" />
                    </div>
                    <div className="flex gap-2 justify-end">
                      <Button variant="outline" size="sm" onClick={() => setEditingProfileId(null)}>Cancel</Button>
                      <Button size="sm" onClick={() => handleUpdateProfile(profile.id)} disabled={profileSaving}>Save</Button>
                    </div>
                  </div>
                ) : (
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="font-medium text-gray-900">{profile.name}</span>
                        {profile.is_default && (
                          <span className="text-xs bg-blue-100 text-blue-700 px-1.5 py-0.5 rounded">Default</span>
                        )}
                        {profileMatchesCurrent && (
                          <span className="text-xs bg-green-100 text-green-700 px-1.5 py-0.5 rounded">Active for this client</span>
                        )}
                        {!profileMatchesCurrent && profileValuesMatchCurrent && (
                          <span className="text-xs bg-slate-100 text-slate-600 px-1.5 py-0.5 rounded">Matches current settings</span>
                        )}
                      </div>
                      {profile.description && (
                        <p className="text-sm text-gray-500 mt-0.5">{profile.description}</p>
                      )}
                      <p className="text-xs text-gray-400 mt-1 font-mono">
                        X: {Number(profile.check_offset_x).toFixed(3)} &nbsp; Y: {Number(profile.check_offset_y).toFixed(3)} &nbsp; Stock: {profile.check_stock_type === 'first_hawaiian_4up' ? 'FHB 4-Up' : profile.check_stock_type === 'top_check' ? 'Top' : 'Bottom'}
                      </p>
                      <p className="text-xs text-gray-500 mt-1">
                        Layout: {hasCustomLayout ? 'Customized check face' : 'Default check face'}
                      </p>
                      {profile.notes && (
                        <div className="mt-2 rounded bg-amber-50 border border-amber-200 px-2 py-1.5">
                          <p className="text-xs font-medium text-amber-800">Print Notes:</p>
                          <p className="text-xs text-amber-700 whitespace-pre-wrap">{profile.notes}</p>
                        </div>
                      )}
                    </div>
                    <div className="grid shrink-0 grid-cols-1 gap-2 sm:flex sm:flex-col sm:gap-1 [&>button]:w-full sm:[&>button]:w-auto">
                      <Button size="sm" onClick={() => handleApplyProfile(profile)}>
                        {profileMatchesCurrent ? 'Using for This Client' : 'Use for This Client'}
                      </Button>
                      <Button variant="outline" size="sm" onClick={() => handleApplyProfileToAllCompanies(profile)} disabled={profileApplyingAllId === profile.id}>
                        {profileApplyingAllId === profile.id ? 'Applying...' : 'Use for All Clients'}
                      </Button>
                      <Button variant="outline" size="sm" onClick={() => handleOverwriteProfile(profile)}>
                        Save Draft to Profile
                      </Button>
                      <div className="grid grid-cols-2 gap-1 sm:flex">
                        <Button
                          variant="ghost"
                          size="sm"
                          className="text-xs"
                          onClick={() => {
                            setEditingProfileId(profile.id);
                            setEditProfileName(profile.name);
                            setEditProfileDescription(profile.description || '');
                            setEditProfileNotes(profile.notes || '');
                          }}
                        >
                          Edit
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="text-xs text-red-600 hover:text-red-700"
                          onClick={() => handleDeleteProfile(profile.id, profile.name)}
                        >
                          Delete
                        </Button>
                      </div>
                    </div>
                  </div>
                )}
              </div>
              );
            })}
          </CardContent>
        </Card>

        {/* Check Stock Settings */}
        <Card>
          <div className="p-4 border-b">
            <h2 className="font-semibold text-gray-900">Check Stock Configuration</h2>
            <p className="text-sm text-gray-500 mt-0.5">
              Use the simple controls below to line the PDF up with your check stock. Most people should not need the advanced section.
            </p>
          </div>
          <CardContent className="p-4 space-y-4">
            <div className="rounded-lg border bg-blue-50 px-4 py-3 text-sm text-blue-900">
              <p className="font-medium">Recommended workflow</p>
              <ol className="mt-2 list-decimal space-y-1 pl-5 text-xs sm:text-sm">
                <li>Download the alignment test PDF.</li>
                <li>Print it on plain paper or a photocopy of real check stock.</li>
                <li>Hold it behind your real check stock and see what is off.</li>
                <li>Use X and Y offset for small overall shifts.</li>
                <li>Only open Advanced Calibration if one specific area still needs fine tuning.</li>
              </ol>
            </div>

            {/* Stock Type */}
            <div className="space-y-1">
              <Label htmlFor="stock-type">Stock Type</Label>
              <Select
                id="stock-type"
                value={stockType}
                onChange={(e) => setStockType(e.target.value as CheckStockType)}
                className="w-64"
              >
                <option value="top_check">Top Check</option>
                <option value="bottom_check">Bottom Check</option>
                <option value="first_hawaiian_4up">First Hawaiian 4-Up</option>
              </Select>
              <p className="text-xs text-gray-500">
                Top/bottom check: QuickBooks-style voucher stock with payroll stubs. First Hawaiian 4-Up: four checks per sheet with separate pay stubs.
              </p>
            </div>

            {/* Offset calibration */}
            <div className="space-y-3">
              <div>
                <h3 className="text-sm font-semibold text-gray-900">Visual Calibration</h3>
                <p className="mt-0.5 text-xs text-gray-500">
                  Drag a field or use the nudge buttons. Nothing is saved until you click Save Settings.
                </p>
              </div>
              <CheckLayoutEditor
                stockType={stockType}
                offsetX={offsetX}
                offsetY={offsetY}
                layoutConfig={parsedLayoutOverrides ?? {}}
                layout={checkLayout}
                disabled={!parsedLayoutOverrides}
                onLayoutConfigChange={handleVisualLayoutChange}
                onOffsetChange={handleVisualOffsetChange}
              />
              {!parsedLayoutOverrides && (
                <p className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
                  Fix the advanced JSON before using visual calibration.
                </p>
              )}
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <Label htmlFor="offset-x">X Offset (inches)</Label>
                <Input
                  id="offset-x"
                  type="text"
                  inputMode="decimal"
                  value={offsetX}
                  onChange={(e) => setOffsetX(e.target.value)}
                  className="w-32 font-mono"
                />
                <p className="text-xs text-gray-500">Positive = shift right</p>
              </div>
              <div className="space-y-1">
                <Label htmlFor="offset-y">Y Offset (inches)</Label>
                <Input
                  id="offset-y"
                  type="text"
                  inputMode="decimal"
                  value={offsetY}
                  onChange={(e) => setOffsetY(e.target.value)}
                  className="w-32 font-mono"
                />
                <p className="text-xs text-gray-500">Positive = shift up</p>
              </div>
            </div>

            {/* Bank info */}
            <div className="space-y-1">
              <Label htmlFor="bank-name">Bank Name (printed on check face)</Label>
              <Input
                id="bank-name"
                value={bankName}
                onChange={(e) => setBankName(e.target.value)}
                placeholder="e.g., Bank of Guam"
                className="max-w-xs"
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bank-address">Bank Address</Label>
              <Input
                id="bank-address"
                value={bankAddress}
                onChange={(e) => setBankAddress(e.target.value)}
                placeholder="e.g., 111 W Marine Corps Dr, Tamuning, GU 96913"
                className="max-w-md"
              />
            </div>

            {/* Memo template */}
            <div className="space-y-1">
              <Label htmlFor="memo-template">Check Memo Text</Label>
              <Input
                id="memo-template"
                value={memoTemplate}
                onChange={(e) => setMemoTemplate(e.target.value)}
                placeholder="Leave blank for default: Payroll {period_start} - {period_end}"
                className="max-w-lg"
              />
              <p className="text-xs text-gray-500">
                Available placeholders: <span className="font-mono">{'{employee_name}'}</span>,{' '}
                <span className="font-mono">{'{employee_first_name}'}</span>,{' '}
                <span className="font-mono">{'{employee_last_name}'}</span>,{' '}
                <span className="font-mono">{'{period_start}'}</span>,{' '}
                <span className="font-mono">{'{period_end}'}</span>,{' '}
                <span className="font-mono">{'{pay_date}'}</span>,{' '}
                <span className="font-mono">{'{check_number}'}</span>,{' '}
                <span className="font-mono">{'{company_name}'}</span>
              </p>
            </div>

            {/* Alignment test */}
            <div className="pt-2 border-t space-y-3">
              <div className="rounded-lg border border-blue-100 bg-blue-50 px-4 py-3">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
                  <div>
                    <Label htmlFor="test-check-type">Test Print</Label>
                    <p className="mt-1 text-xs text-blue-900">
                      Generate a preview from the current draft settings, then print from the browser just like a real check.
                    </p>
                  </div>
                  <div className="flex flex-wrap items-end gap-2">
                    <Select
                      id="test-check-type"
                      value={testCheckType}
                      onChange={(e) => setTestCheckType(e.target.value as TestCheckType)}
                      className="w-56 bg-white"
                    >
                      <option value="payroll">Payroll check</option>
                      <option value="fit">FIT tax check</option>
                      <option value="grt">GRT check</option>
                      <option value="vendor">Vendor check</option>
                    </Select>
                    <Button variant="outline" onClick={handleTestCheckPdf} type="button" disabled={generatingTestCheck}>
                      {generatingTestCheck ? (
                        <><div className="w-4 h-4 mr-2 animate-spin rounded-full border-2 border-gray-300 border-t-gray-600" /> Generating...</>
                      ) : (
                        <><Download className="w-4 h-4 mr-2" /> Preview Test Check</>
                      )}
                    </Button>
                  </div>
                </div>
              </div>
              <Button variant="outline" onClick={handleAlignmentTest} type="button" disabled={downloadingAlignment}>
                {downloadingAlignment ? (
                  <><div className="w-4 h-4 mr-2 animate-spin rounded-full border-2 border-gray-300 border-t-gray-600" /> Downloading...</>
                ) : (
                  <><Download className="w-4 h-4 mr-2" /> Download Alignment Test PDF</>
                )}
              </Button>
              <p className="text-xs text-gray-500">
                The alignment test now marks the configured check-face anchors and stub row baselines.
                Print on plain paper or a photocopy of real check stock, confirm alignment, then print on live check stock.
              </p>
            </div>

            {/* Advanced layout tuning */}
            <details className="rounded-lg border border-dashed border-gray-300 bg-gray-50 px-4 py-3">
              <summary className="cursor-pointer text-sm font-medium text-gray-900">
                Advanced Calibration
              </summary>
              <div className="mt-3 space-y-2">
                <div>
                  <Label htmlFor="layout-overrides">Exact Layout Overrides (JSON)</Label>
                  <p className="text-xs text-gray-500 mt-1">
                    This is only for unusual printers or stock. Leave it as <span className="font-mono">{'{}'}</span> unless you know a specific field needs adjustment.
                  </p>
                </div>
                <Textarea
                  id="layout-overrides"
                  value={layoutOverridesJson}
                  onChange={(e) => setLayoutOverridesJson(e.target.value)}
                  className="min-h-[260px] font-mono text-xs"
                  spellCheck={false}
                />
                <div className="flex flex-wrap items-center gap-3">
                  <Button variant="outline" type="button" onClick={handleResetAdvancedOverrides}>
                    Reset Advanced Overrides
                  </Button>
                  <p className="text-xs text-gray-500">
                    Example keys: <span className="font-mono">check_face.date.x</span>,
                    <span className="font-mono"> check_face.payee.y</span>,
                    <span className="font-mono"> stub.row1_y</span>,
                    <span className="font-mono"> stub.summary_y_offset</span>,
                    <span className="font-mono"> stub.table_padding_x</span>.
                  </p>
                </div>
              </div>
            </details>

            <div className="flex justify-end pt-2">
              <Button onClick={handleSaveSettings} disabled={saving}>
                {saving ? 'Saving…' : 'Save Settings'}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Payroll Automation */}
        <Card>
          <div className="p-4 border-b">
            <h2 className="font-semibold text-gray-900">Payroll Automation</h2>
            <p className="text-sm text-gray-500 mt-0.5">
              Configure automatic actions that happen when payroll is committed.
            </p>
          </div>
          <CardContent className="p-4 space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <Label className="text-sm font-medium text-gray-900">Auto-Create FIT Tax Deposit Check</Label>
                <p className="text-xs text-gray-500 mt-0.5">
                  When enabled, committing payroll automatically creates a non-employee check
                  for the total Federal Income Tax withheld, payable to &quot;Treasurer of Guam&quot;
                  (remit via Guam DRT Form 500).
                </p>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={autoCreateFitCheck}
                onClick={() => setAutoCreateFitCheck(!autoCreateFitCheck)}
                className={`relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 ${
                  autoCreateFitCheck ? 'bg-blue-600' : 'bg-gray-200'
                }`}
              >
                <span
                  className={`pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out ${
                    autoCreateFitCheck ? 'translate-x-5' : 'translate-x-0'
                  }`}
                />
              </button>
            </div>
            <div className="flex justify-end pt-2">
              <Button onClick={handleSaveSettings} disabled={saving}>
                {saving ? 'Saving…' : 'Save Settings'}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Check Number Sequencing */}
        <Card>
          <div className="p-4 border-b">
            <h2 className="font-semibold text-gray-900">Check Number Sequencing</h2>
            <p className="text-sm text-gray-500 mt-0.5">
              The next check number is automatically assigned at payroll commit and increments sequentially.
            </p>
          </div>
          <CardContent className="p-4 space-y-4">
            <div className="flex items-end gap-3">
              <div className="space-y-1">
                <Label htmlFor="next-check-number">Next Check Number</Label>
                <NumericInput
                  id="next-check-number"
                  min={1}
                  fixedDecimalsOnBlur={0}
                  inputMode="numeric"
                  value={nextCheckNumber === '' ? null : Number(nextCheckNumber)}
                  onValueChange={(value) =>
                    setNextCheckNumber(value == null ? '' : String(Math.max(1, Math.round(value))))
                  }
                  className="w-32 font-mono"
                />
              </div>
              <Button
                variant="outline"
                onClick={handleUpdateNextCheckNumber}
                disabled={nextCheckNumberSaving}
              >
                {nextCheckNumberSaving ? 'Updating…' : 'Update Next Number'}
              </Button>
            </div>
            <div className="text-xs text-gray-500 space-y-1">
              <p>This is the next blank check number the app will assign, not the last used check number.</p>
              <p>You can move this forward for the next pay period. It cannot be set to a number that has already been issued.</p>
              <p>Current next number: <span className="font-mono font-medium">{settings?.next_check_number}</span></p>
            </div>
          </CardContent>
        </Card>

        {/* How it works */}
        <Card>
          <div className="p-4 border-b">
            <h2 className="font-semibold text-gray-900">How Check Printing Works</h2>
          </div>
          <CardContent className="p-4">
            <ol className="text-sm text-gray-700 space-y-2 list-decimal list-inside">
              <li>Run and commit a payroll — check numbers are automatically assigned.</li>
              <li>Go to the Pay Period detail page and scroll to the <strong>Checks</strong> section.</li>
              <li>Click <strong>Download All Checks PDF</strong> to get a single PDF with all checks.</li>
              <li>Load your pre-printed check stock into the printer and print.</li>
              <li>Click <strong>Mark All Printed</strong> after printing to record in the audit trail.</li>
              <li>If a check is damaged, use <strong>Reprint</strong> — a new check number is issued.</li>
              <li>If a check must be cancelled, use <strong>Void</strong> with a written reason.</li>
            </ol>
          </CardContent>
        </Card>

      </div>

      {testCheckPreviewUrl && createPortal(
        <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-gray-900/70 p-4">
          <div className="flex h-[92vh] w-[95vw] max-w-[1400px] flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-6 py-4">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">
                  Test Check Preview
                </h2>
                <p className="mt-1 text-sm text-gray-500">
                  This preview uses the current draft settings. Nothing is saved until you click Save Settings.
                </p>
              </div>
              <div className="flex items-center gap-3">
                <Button variant="outline" size="sm" onClick={handlePrintTestCheckPreview}>
                  Print
                </Button>
                <Button variant="outline" size="sm" onClick={handleDownloadTestCheckPreview}>
                  Download PDF
                </Button>
                <Button size="sm" onClick={handleCloseTestCheckPreview}>
                  Close
                </Button>
              </div>
            </div>
            <div className="flex-1 bg-gray-100 p-5">
              <iframe
                src={`${testCheckPreviewUrl}#toolbar=0&navpanes=0&scrollbar=1&view=Fit`}
                className="h-full w-full rounded-xl border bg-white shadow-lg"
                title="Test Check Preview"
              />
            </div>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}
