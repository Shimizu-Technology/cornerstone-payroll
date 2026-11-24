import { useCallback, useEffect, useMemo, useRef, useState, type ChangeEvent, type FormEvent, type ReactElement } from 'react';
import { Navigate } from 'react-router';
import { AlertTriangle, ImageUp, Monitor, Smartphone } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Skeleton } from '@/components/ui/skeleton';
import { EmployeeAppPreview, type PreviewDevice, type PreviewScreen } from '@/components/employee-app/EmployeeAppPreview';
import { HelpContactsEditor } from '@/components/employee-app/HelpContactsEditor';
import { formatPhone } from '@/lib/employee-app-text';
import { draftProblems, fromDraft, toDraft, type HelpContactDraft } from '@/lib/help-contact-drafts';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { canWriteCompany, companyReadOnlyMessage } from '@/lib/company-write-access';
import { accentColorCheck, brandColorCheck, brandRoles, isHexColor } from '@/lib/tenant-brand-colors';
import { cn } from '@/lib/utils';
import { ApiError } from '@/services/api';
import { employeeAppSettingsApi, type BrandingUpdate, type EmployeeAppSettings } from '@/services/employee-app-settings-api';

const APP_NAME_FITS = 12;
const LOGO_ACCEPT = '.png,.webp,image/png,image/webp';
const LOGO_TYPES = ['image/png', 'image/webp'];
const UNSUPPORTED_LOGO = "Upload a PNG or WebP image. SVG isn't supported.";
const RECOMMENDED_EDGE = 512;
const SMALL_EDGE = 256;

function brandingForm(settings: EmployeeAppSettings): BrandingUpdate {
  const { branding } = settings;
  return {
    display_name: branding.display_name ?? '',
    app_name: branding.app_name ?? '',
    primary_color: branding.primary_color ?? '',
    accent_color: branding.accent_color ?? '',
    show_main_phone: branding.show_main_phone,
  };
}

function sameBranding(a: BrandingUpdate, b: BrandingUpdate): boolean {
  return a.display_name.trim() === b.display_name.trim() && a.app_name.trim() === b.app_name.trim()
    && a.primary_color.toLowerCase() === b.primary_color.toLowerCase()
    && a.accent_color.toLowerCase() === b.accent_color.toLowerCase() && a.show_main_phone === b.show_main_phone;
}

function errorMessage(caught: unknown, fallback: string): string {
  return caught instanceof Error && caught.message ? caught.message : fallback;
}

function helpContactErrors(caught: unknown): Record<number, string[]> {
  if (!(caught instanceof ApiError)) return {};
  const details = (caught.data as { details?: { help_contacts?: Record<string, string[]> } } | undefined)?.details?.help_contacts;
  if (!details) return {};
  return Object.fromEntries(Object.entries(details).map(([index, messages]) => [Number(index), messages]));
}

function Segmented<T extends string>({ label, value, options, onChange }: {
  label: string;
  value: T;
  options: { value: T; label: string; icon?: ReactElement }[];
  onChange: (value: T) => void;
}): ReactElement {
  return (
    <div role="radiogroup" aria-label={label} className="inline-flex rounded-full border border-neutral-200 bg-neutral-50 p-1">
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={value === option.value}
          onClick={() => onChange(option.value)}
          className={cn(
            'inline-flex min-h-10 items-center gap-1.5 rounded-full px-3 text-sm font-semibold transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300',
            value === option.value ? 'bg-white text-neutral-950 shadow-sm' : 'text-neutral-600 hover:text-neutral-900',
          )}
        >
          {option.icon}
          {option.label}
        </button>
      ))}
    </div>
  );
}

function ColorField({ id, label, value, placeholder, disabled, onChange }: {
  id: string;
  label: string;
  value: string;
  placeholder: string;
  disabled: boolean;
  onChange: (value: string) => void;
}): ReactElement {
  const valid = value === '' || isHexColor(value);
  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-sm font-medium text-neutral-800">{label}</label>
      <div className="flex items-center gap-2">
        <input
          type="color"
          aria-label={`${label} picker`}
          value={isHexColor(value) ? value.toLowerCase() : '#ffffff'}
          disabled={disabled}
          onChange={(event) => onChange(event.target.value)}
          className="h-11 w-14 shrink-0 cursor-pointer rounded-xl border border-neutral-300 bg-white p-1 disabled:cursor-not-allowed"
        />
        <input
          id={id}
          value={value}
          placeholder={placeholder}
          maxLength={7}
          spellCheck={false}
          autoComplete="off"
          disabled={disabled}
          aria-invalid={!valid}
          onChange={(event) => onChange(event.target.value.trim())}
          className={cn('h-11 w-full min-w-0 rounded-xl border bg-white px-3 font-mono text-base uppercase sm:text-sm',
            valid ? 'border-neutral-300' : 'border-danger-400')}
        />
      </div>
      {!valid && <p className="text-sm text-danger-700">Use a six-digit color code like #1898CF.</p>}
    </div>
  );
}

function ColorResult({ primary, accent }: { primary: string; accent: string }): ReactElement | null {
  const hasAccent = isHexColor(accent);
  if (!isHexColor(primary)) {
    if (!hasAccent) return null;
    const roles = brandRoles(null, accent);
    return (
      <div className="rounded-2xl border border-neutral-200 bg-neutral-50/60 p-4">
        <span className="inline-flex items-center rounded-full px-3 py-1 text-sm font-semibold" style={{ background: roles.accent, color: roles.accentInk }}>
          Highlight
        </span>
        <p className="mt-3 text-sm text-neutral-700" role="status">{accentColorCheck(accent)}</p>
      </div>
    );
  }
  const check = brandColorCheck(primary, hasAccent);
  const roles = brandRoles(primary, hasAccent ? accent : null);
  return (
    <div className={cn('rounded-2xl border p-4', check.tone === 'ok' ? 'border-success-200 bg-success-50/40' : 'border-primary-100 bg-primary-50/40')}>
      <div className="flex flex-wrap items-center gap-3">
        <span className="inline-flex items-center gap-2 text-sm text-neutral-700">
          <span aria-hidden="true" className="size-8 rounded-lg border border-black/10" style={{ background: primary }} />
          Your color
        </span>
        <span aria-hidden="true" className="text-neutral-400">→</span>
        <span className="inline-flex min-h-10 items-center rounded-full px-4 text-sm font-semibold text-white" style={{ background: roles.action }}>
          Buttons look like this
        </span>
        {hasAccent && (
          <span className="inline-flex items-center rounded-full px-3 py-1 text-sm font-semibold" style={{ background: roles.accent, color: roles.accentInk }}>
            Highlight
          </span>
        )}
      </div>
      <p className="mt-3 text-sm font-medium text-neutral-900" role="status">{check.message}</p>
      <p className="mt-1 text-xs text-neutral-600">
        White text on your color: {check.ratio}. Buttons need 4.5 to 1.
        {check.tone !== 'ok' && ` Button color: ${roles.action.toUpperCase()}.`}
      </p>
      {hasAccent && <p className="mt-1 text-xs text-neutral-600">{accentColorCheck(accent)}</p>}
    </div>
  );
}

function HomeScreenIcon({ logoUrl, label, fallbackLetter }: { logoUrl: string | null; label: string; fallbackLetter: string }): ReactElement {
  return (
    <div className="flex w-20 flex-col items-center gap-1.5" aria-label={`Home Screen icon labeled ${label}`} role="img">
      <span className="grid size-16 place-items-center overflow-hidden rounded-[18px] border border-neutral-200 bg-white shadow-sm">
        {logoUrl
          ? <img src={logoUrl} alt="" className="size-[80%] object-contain" />
          : <span className="text-2xl font-bold text-neutral-700">{fallbackLetter}</span>}
      </span>
      <span className="w-full truncate text-center text-xs text-neutral-800">{label}</span>
    </div>
  );
}

export function EmployeeAppSettings(): ReactElement {
  const { user, isLoading: authLoading } = useAuth();
  const { activeCompany, activeCompanyId, loading: companyLoading } = useCompany();
  const isClient = user?.role === 'client';
  const hasClientAdministration = useSelectedCompanyCapability('manage_client_administration');
  const api = useMemo(() => employeeAppSettingsApi(isClient ? 'client' : 'staff'), [isClient]);
  const companyReady = !authLoading && !companyLoading && activeCompany != null && activeCompanyId != null && activeCompany.id === activeCompanyId;
  const canOpen = isClient || hasClientAdministration;
  const canEdit = companyReady && canOpen && canWriteCompany(activeCompany, isClient ? 'payroll_operations' : 'manage_client_administration');

  const [settings, setSettings] = useState<EmployeeAppSettings | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [form, setForm] = useState<BrandingUpdate | null>(null);
  const [drafts, setDrafts] = useState<HelpContactDraft[]>([]);
  const [savedDrafts, setSavedDrafts] = useState<string>('[]');
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const [brandingStatus, setBrandingStatus] = useState<{ tone: 'success' | 'error'; message: string } | null>(null);
  const [contactsStatus, setContactsStatus] = useState<{ tone: 'success' | 'error'; message: string } | null>(null);
  const [logoStatus, setLogoStatus] = useState<{ tone: 'success' | 'error'; message: string } | null>(null);
  const [savingBranding, setSavingBranding] = useState(false);
  const [savingContacts, setSavingContacts] = useState(false);
  const [logoBusy, setLogoBusy] = useState(false);
  const [logoSize, setLogoSize] = useState<{ width: number; height: number } | null>(null);
  const [showProblems, setShowProblems] = useState(false);
  const [serverErrors, setServerErrors] = useState<Record<number, string[]>>({});
  const [screen, setScreen] = useState<PreviewScreen>('sign-in');
  const [device, setDevice] = useState<PreviewDevice>('phone');
  const fileRef = useRef<HTMLInputElement | null>(null);
  const contactsRef = useRef<HTMLDivElement | null>(null);
  const requestRef = useRef(0);

  const applySettings = useCallback((data: EmployeeAppSettings, { resetForm = true, resetContacts = true } = {}) => {
    setSettings(data);
    if (resetForm) setForm(brandingForm(data));
    if (resetContacts) {
      setDrafts(data.help_contacts.map((contact) => toDraft(contact)));
      setSavedDrafts(JSON.stringify(data.help_contacts));
      setServerErrors({});
      setShowProblems(false);
    }
  }, []);

  useEffect(() => {
    if (!companyReady || !canOpen || activeCompanyId == null) return undefined;
    const request = ++requestRef.current;
    setSettings(null);
    setLoadError(null);
    api.get(activeCompanyId)
      .then((response) => { if (request === requestRef.current) applySettings(response.data); })
      .catch((caught: unknown) => { if (request === requestRef.current) setLoadError(errorMessage(caught, "The employee app settings couldn't load.")); });
    return () => { requestRef.current += 1; };
  }, [activeCompanyId, api, applySettings, canOpen, companyReady]);

  // The saved logo comes from a signed-in request, so the preview can show it
  // before the client's subdomain is on.
  const logoDigest = settings?.branding.logo?.digest ?? null;
  const externalLogo = settings?.branding.external_logo_url ?? null;
  const settingsCompanyId = settings?.company_id ?? null;
  useEffect(() => {
    setLogoSize(null);
    if (!logoDigest || settingsCompanyId == null) {
      setLogoUrl(externalLogo);
      return undefined;
    }
    let objectUrl: string | null = null;
    let cancelled = false;
    api.logo(settingsCompanyId)
      .then((blob) => {
        if (cancelled) return;
        objectUrl = URL.createObjectURL(blob);
        setLogoUrl(objectUrl);
      })
      .catch(() => { if (!cancelled) setLogoUrl(null); });
    return () => {
      cancelled = true;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [api, externalLogo, logoDigest, settingsCompanyId]);

  if (!authLoading && !companyLoading && !canOpen) return <Navigate to="/app" replace />;

  const companyName = settings?.company_name ?? activeCompany?.name ?? 'this company';
  const displayName = form?.display_name.trim() || companyName;
  const homeScreenName = form?.app_name.trim() || displayName;
  const mainPhone = settings?.main_phone ?? null;
  const previewContacts = drafts.filter((draft) => draft.name.trim()).map(fromDraft);
  const brandingDirty = !!(settings && form && !sameBranding(form, brandingForm(settings)));
  const contactsDirty = JSON.stringify(drafts.map(fromDraft)) !== savedDrafts;
  const colorsValid = !!form && (form.primary_color === '' || isHexColor(form.primary_color)) && (form.accent_color === '' || isHexColor(form.accent_color));
  const readOnlyReason = !canEdit && companyReady ? companyReadOnlyMessage(activeCompany) : null;
  const savedContactCount = settings?.help_contacts.length ?? 0;
  // Fields lock while a save is in flight, so its response can't discard
  // edits made after Save was clicked.
  const brandingLocked = !canEdit || savingBranding;
  const hasLogo = !!(settings?.branding.logo || settings?.branding.external_logo_url);
  const logoWarning = logoSize && hasLogo
    ? (Math.min(logoSize.width, logoSize.height) < SMALL_EDGE
      ? `This logo is ${logoSize.width}×${logoSize.height} pixels, so it may look blurry as a Home Screen icon. Use one at least ${RECOMMENDED_EDGE}×${RECOMMENDED_EDGE} if you can.`
      : Math.abs(logoSize.width - logoSize.height) / Math.max(logoSize.width, logoSize.height) > 0.1
        ? `This logo isn't square (${logoSize.width}×${logoSize.height}), so it will be shrunk to fit the square Home Screen icon.`
        : null)
    : null;

  const updateForm = (patch: Partial<BrandingUpdate>): void => {
    setForm((current) => (current ? { ...current, ...patch } : current));
    setBrandingStatus(null);
  };

  const saveBranding = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!form || activeCompanyId == null || !colorsValid) return;
    setSavingBranding(true);
    setBrandingStatus(null);
    try {
      const response = await api.updateBranding(activeCompanyId, {
        ...form,
        display_name: form.display_name.trim(),
        app_name: form.app_name.trim(),
      });
      applySettings(response.data, { resetContacts: false });
      setBrandingStatus({ tone: 'success', message: 'Saved. Employees see the new look the next time they open the app.' });
    } catch (caught) {
      setBrandingStatus({ tone: 'error', message: errorMessage(caught, "The branding wasn't saved. Try again.") });
    } finally {
      setSavingBranding(false);
    }
  };

  const chooseLogo = async (event: ChangeEvent<HTMLInputElement>): Promise<void> => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file || activeCompanyId == null || !settings) return;
    setLogoStatus(null);
    // Trust the file name only when the browser doesn't know the type.
    const genericType = !file.type || file.type === 'application/octet-stream';
    if (!LOGO_TYPES.includes(file.type) && !(genericType && /\.(png|webp)$/i.test(file.name))) {
      setLogoStatus({ tone: 'error', message: UNSUPPORTED_LOGO });
      return;
    }
    if (file.size > settings.logo_limits.max_bytes) {
      setLogoStatus({ tone: 'error', message: 'That file is over 1 MB. Export a smaller PNG or WebP and try again.' });
      return;
    }
    setLogoBusy(true);
    try {
      const response = await api.uploadLogo(activeCompanyId, file);
      applySettings(response.data, { resetForm: false, resetContacts: false });
      setLogoStatus({ tone: 'success', message: 'Logo saved.' });
    } catch (caught) {
      setLogoStatus({ tone: 'error', message: errorMessage(caught, "The logo wasn't saved. Try again.") });
    } finally {
      setLogoBusy(false);
    }
  };

  const removeLogo = async (): Promise<void> => {
    if (activeCompanyId == null) return;
    setLogoBusy(true);
    setLogoStatus(null);
    try {
      const response = await api.removeLogo(activeCompanyId);
      applySettings(response.data, { resetForm: false, resetContacts: false });
      setLogoStatus({ tone: 'success', message: 'Logo removed. Employees see the first letter of the name instead.' });
    } catch (caught) {
      setLogoStatus({ tone: 'error', message: errorMessage(caught, "The logo wasn't removed. Try again.") });
    } finally {
      setLogoBusy(false);
    }
  };

  const saveContacts = async (): Promise<void> => {
    if (activeCompanyId == null) return;
    setShowProblems(true);
    setContactsStatus(null);
    if (drafts.some((draft) => Object.keys(draftProblems(draft)).length > 0)) {
      setContactsStatus({ tone: 'error', message: 'Fix the highlighted contacts, then save again.' });
      return;
    }
    setSavingContacts(true);
    try {
      const response = await api.updateHelpContacts(activeCompanyId, drafts.map(fromDraft));
      applySettings(response.data, { resetForm: false });
      setContactsStatus({ tone: 'success', message: response.data.help_contacts.length ? 'Help contacts saved.' : 'Help contacts removed. Employees see the fallback message.' });
    } catch (caught) {
      setServerErrors(helpContactErrors(caught));
      setContactsStatus({ tone: 'error', message: errorMessage(caught, "The Help contacts weren't saved. Try again.") });
    } finally {
      setSavingContacts(false);
    }
  };

  const startContacts = (): void => {
    if (drafts.length === 0) setDrafts([toDraft()]);
    setScreen('help');
    requestAnimationFrame(() => {
      const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
      contactsRef.current?.scrollIntoView?.({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
      contactsRef.current?.querySelector('input')?.focus();
    });
  };

  return (
    <div>
      <Header title="Employee app" description={`How the app looks to ${companyName} employees, and who they can ask for help`} />
      <div className="space-y-6 p-4 pb-24 sm:p-6 lg:p-8">
        {loadError && <ActionFeedback tone="error" message={loadError} />}
        {readOnlyReason && <ActionFeedback tone="info" message={readOnlyReason} />}

        {!settings || !form ? (
          !loadError && (
            <div className="space-y-4" aria-busy="true" aria-label="Loading employee app settings">
              <Skeleton className="h-24 w-full rounded-2xl" />
              <Skeleton className="h-96 w-full rounded-2xl" />
            </div>
          )
        ) : (
          <>
            {savedContactCount === 0 && (
              <Card className="border-warning-300 bg-warning-50/50">
                <CardContent className="flex flex-col gap-4 py-5 sm:flex-row sm:items-start sm:justify-between">
                  <div className="flex items-start gap-3">
                    <AlertTriangle aria-hidden="true" className="mt-0.5 size-5 shrink-0 text-warning-700" />
                    <div>
                      <p className="font-semibold text-neutral-950">Help contacts not set up</p>
                      <p className="mt-1 text-sm text-neutral-700">
                        Until you add someone, employees who need help see: “Ask your manager at {displayName}.”
                        {mainPhone && form.show_main_phone ? ` They also see a button to call ${formatPhone(mainPhone)}.` : ''}
                      </p>
                    </div>
                  </div>
                  {canEdit && <Button type="button" variant="secondary" className="shrink-0" onClick={startContacts}>Set up Help contacts</Button>}
                </CardContent>
              </Card>
            )}

            <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_420px]">
              <Card className="min-w-0 xl:col-start-1 xl:row-start-1">
                <CardHeader>
                  <CardTitle>Name, logo and colors</CardTitle>
                  <CardDescription>What employees see when they sign in and on every screen.</CardDescription>
                </CardHeader>
                <CardContent>
                  <form className="space-y-6" onSubmit={(event) => void saveBranding(event)}>
                    <div className="grid gap-4 sm:grid-cols-2">
                      <Input label="Name employees see" value={form.display_name} placeholder={companyName} maxLength={60} disabled={brandingLocked}
                        helperText={`Leave blank to use ${companyName}.`} onChange={(event) => updateForm({ display_name: event.target.value })} />
                      <div className="space-y-2">
                        <Input label="Home Screen name" value={form.app_name} placeholder={displayName} maxLength={30} disabled={brandingLocked}
                          helperText={form.app_name.trim().length > APP_NAME_FITS
                            ? `Phones may cut this off after about ${APP_NAME_FITS} characters.`
                            : 'The label under the app icon when someone adds it to their phone.'}
                          onChange={(event) => updateForm({ app_name: event.target.value })} />
                      </div>
                    </div>
                    <div className="flex flex-wrap items-end gap-6">
                      <HomeScreenIcon logoUrl={logoUrl} label={homeScreenName} fallbackLetter={displayName.match(/[\p{L}\p{N}]/u)?.[0]?.toUpperCase() ?? 'C'} />
                      <p className="max-w-sm text-sm text-neutral-600">How the app icon and its name look on a phone’s Home Screen.</p>
                    </div>

                    <section aria-labelledby="logo-heading" className="space-y-3 border-t border-neutral-200 pt-5">
                      <h3 id="logo-heading" className="text-sm font-semibold text-neutral-950">Logo</h3>
                      <div className="flex flex-wrap items-center gap-4">
                        <span className="grid size-20 shrink-0 place-items-center overflow-hidden rounded-2xl border border-neutral-200 bg-white">
                          {logoUrl ? <img src={logoUrl} alt={`${displayName} logo`} className="size-[85%] object-contain"
                            onLoad={(event) => setLogoSize({ width: event.currentTarget.naturalWidth, height: event.currentTarget.naturalHeight })} />
                            : <span className="px-2 text-center text-xs text-neutral-500">No logo yet</span>}
                        </span>
                        <div className="space-y-2">
                          <div className="flex flex-wrap gap-2">
                            <Button type="button" variant="secondary" disabled={!canEdit} loading={logoBusy} loadingLabel="Saving logo"
                              onClick={() => fileRef.current?.click()}>
                              <ImageUp aria-hidden="true" className="mr-1 size-4" />
                              {hasLogo ? 'Replace logo' : 'Upload logo'}
                            </Button>
                            {hasLogo && (
                              <Button type="button" variant="ghost" disabled={!canEdit || logoBusy} onClick={() => void removeLogo()}>Remove</Button>
                            )}
                          </div>
                          <p className="text-xs text-neutral-600">PNG or WebP, up to 1 MB. Square, at least 512×512, works best for the Home Screen icon.</p>
                        </div>
                        <input ref={fileRef} type="file" accept={LOGO_ACCEPT} className="sr-only" tabIndex={-1} aria-label="Logo file"
                          onChange={(event) => void chooseLogo(event)} />
                      </div>
                      {logoWarning && <p className="text-sm text-warning-800" role="status">{logoWarning}</p>}
                      {logoStatus && <p role={logoStatus.tone === 'error' ? 'alert' : 'status'} className={cn('text-sm', logoStatus.tone === 'error' ? 'text-danger-700' : 'text-success-700')}>{logoStatus.message}</p>}
                    </section>

                    <section aria-labelledby="colors-heading" className="space-y-4 border-t border-neutral-200 pt-5">
                      <h3 id="colors-heading" className="text-sm font-semibold text-neutral-950">Colors</h3>
                      <div className="grid gap-4 sm:grid-cols-2">
                        <ColorField id="brand-color" label="Brand color" value={form.primary_color} placeholder="#1898CF" disabled={brandingLocked}
                          onChange={(value) => updateForm({ primary_color: value })} />
                        <ColorField id="accent-color" label="Accent color (optional)" value={form.accent_color} placeholder="#FADF06" disabled={brandingLocked}
                          onChange={(value) => updateForm({ accent_color: value })} />
                      </div>
                      {form.accent_color && !brandingLocked && (
                        <button type="button" className="text-sm font-semibold text-primary-700 underline-offset-2 hover:underline" onClick={() => updateForm({ accent_color: '' })}>
                          Clear accent color
                        </button>
                      )}
                      <ColorResult primary={form.primary_color} accent={form.accent_color} />
                      {!form.primary_color && <p className="text-sm text-neutral-600">Without a brand color, the app uses Cornerstone Payroll blue.</p>}
                    </section>

                    <section aria-labelledby="phone-heading" className="space-y-2 border-t border-neutral-200 pt-5">
                      <h3 id="phone-heading" className="text-sm font-semibold text-neutral-950">Main phone</h3>
                      {mainPhone ? (
                        <label className="flex min-h-11 items-start gap-3 text-sm text-neutral-800">
                          <input type="checkbox" className="mt-0.5 size-5 rounded border-neutral-300" checked={form.show_main_phone} disabled={brandingLocked}
                            onChange={(event) => updateForm({ show_main_phone: event.target.checked })} />
                          <span>
                            Show {formatPhone(mainPhone)} on the sign-in screen, and on Help when no contacts are set
                            <span className="block text-xs text-neutral-500">Anyone who opens the sign-in page can see it.</span>
                          </span>
                        </label>
                      ) : (
                        <p className="text-sm text-neutral-600">No main phone is on file for {companyName}. {isClient ? 'Ask Cornerstone to add one.' : 'Add one on the client record.'}</p>
                      )}
                    </section>

                    <div className="flex flex-wrap items-center gap-3 border-t border-neutral-200 pt-5">
                      <Button type="submit" disabled={!canEdit || !brandingDirty || !colorsValid} loading={savingBranding} loadingLabel="Saving">Save changes</Button>
                      {savingBranding
                        ? <span className="text-sm text-neutral-600" role="status">Saving… Fields unlock when it's done.</span>
                        : brandingDirty && <span className="text-sm text-neutral-600">Unsaved changes. The preview shows them.</span>}
                    </div>
                    {brandingStatus && <ActionFeedback tone={brandingStatus.tone} message={brandingStatus.message} />}
                  </form>
                </CardContent>
              </Card>

              <Card className="min-w-0 self-start xl:sticky xl:top-40 xl:col-start-2 xl:row-span-2 xl:row-start-1">
                <CardHeader>
                  <div className="flex items-center justify-between gap-2">
                    <CardTitle>Preview</CardTitle>
                    <span className="rounded-full bg-neutral-100 px-2.5 py-0.5 text-xs font-semibold text-neutral-700">Sample data</span>
                  </div>
                  <CardDescription>What employees will see, including unsaved changes. The pay shown is sample data.</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  <div className="flex flex-wrap gap-2">
                    <Segmented label="Screen" value={screen} onChange={setScreen}
                      options={[{ value: 'sign-in', label: 'Sign-in' }, { value: 'home', label: 'Home' }, { value: 'help', label: 'Help' }]} />
                    <Segmented label="Screen size" value={device} onChange={setDevice}
                      options={[
                        { value: 'phone', label: 'Phone', icon: <Smartphone aria-hidden="true" className="size-4" /> },
                        { value: 'desktop', label: 'Desktop', icon: <Monitor aria-hidden="true" className="size-4" /> },
                      ]} />
                  </div>
                  <EmployeeAppPreview
                    screen={screen}
                    device={device}
                    contacts={previewContacts}
                    brand={{
                      name: displayName,
                      logoUrl,
                      primaryColor: isHexColor(form.primary_color) ? form.primary_color : null,
                      accentColor: isHexColor(form.accent_color) ? form.accent_color : null,
                      mainPhone: form.show_main_phone ? mainPhone : null,
                    }}
                  />
                  {settings.subdomain.host && <p className="text-xs text-neutral-600">Employees sign in at {settings.subdomain.host}.</p>}
                </CardContent>
              </Card>

              <div ref={contactsRef} className="min-w-0 scroll-mt-40 xl:col-start-1 xl:row-start-2">
                <Card>
                  <CardHeader>
                    <CardTitle>Help contacts</CardTitle>
                    <CardDescription>
                      Up to {settings.max_help_contacts} people employees can ask about their pay or the app, shown in this order. Only signed-in employees see them.
                    </CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <HelpContactsEditor
                      drafts={drafts}
                      max={settings.max_help_contacts}
                      disabled={!canEdit || savingContacts}
                      showProblems={showProblems}
                      serverErrors={serverErrors}
                      onChange={(next) => { setDrafts(next); setContactsStatus(null); setServerErrors({}); }}
                    />
                    <div className="flex flex-wrap items-center gap-3 border-t border-neutral-200 pt-4">
                      <Button type="button" disabled={!canEdit || !contactsDirty} loading={savingContacts} loadingLabel="Saving" onClick={() => void saveContacts()}>
                        Save Help contacts
                      </Button>
                      {contactsDirty && <span className="text-sm text-neutral-600">Unsaved changes.</span>}
                    </div>
                    {contactsStatus && <ActionFeedback tone={contactsStatus.tone} message={contactsStatus.message} />}
                  </CardContent>
                </Card>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default EmployeeAppSettings;
