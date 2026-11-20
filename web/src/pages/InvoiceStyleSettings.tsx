import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router';
import { ArrowLeft, Download, ImagePlus, Trash2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { PdfDocumentView } from '@/components/documents/PdfPreview';
import { financeWriteBlockedMessage } from '@/components/finance/FinanceWriteNotice';
import { useCompany } from '@/contexts/CompanyContext';
import { isTestWorkspaceCompany } from '@/lib/company-write-access';
import {
  invoiceBillingProfilesApi,
  type InvoiceBillingProfile,
  type InvoiceLogoSize,
  type InvoiceStyleSettings as StyleSettings,
  type InvoiceTheme,
} from '@/services/api';
import {
  INVOICE_THEMES,
  SWATCHES,
  initialsFor,
  normalizeHex,
  textOnAccent,
  themeDefaultAccent,
} from '@/lib/invoiceStyle';

const MAX_LOGO_BYTES = 1_048_576;
const PREVIEW_DELAY_MS = 450;
const fieldClass = 'min-h-11 w-full rounded-lg border border-neutral-300 bg-white px-3 text-base text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300';

function styleFromProfile(profile: InvoiceBillingProfile): StyleSettings {
  return {
    invoice_theme: profile.invoice_theme || 'classic',
    accent_color: profile.accent_color || null,
    logo_size: profile.logo_size || 'medium',
    show_service_period: profile.show_service_period ?? true,
    show_item_column: profile.show_item_column ?? true,
    show_how_to_pay: profile.show_how_to_pay ?? true,
    footer_note: profile.footer_note || null,
    payment_instructions: profile.payment_instructions || null,
  };
}

function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function InvoiceStyleSettings() {
  const { profileId } = useParams();
  const id = Number(profileId);
  const { activeCompany } = useCompany();
  const financeReadOnly = isTestWorkspaceCompany(activeCompany);
  const [profile, setProfile] = useState<InvoiceBillingProfile | null>(null);
  const [style, setStyle] = useState<StyleSettings | null>(null);
  const [savedStyle, setSavedStyle] = useState<StyleSettings | null>(null);
  const [hexDraft, setHexDraft] = useState('');
  const [pendingLogo, setPendingLogo] = useState<File | null>(null);
  const [pendingLogoUrl, setPendingLogoUrl] = useState<string | null>(null);
  const [removeLogo, setRemoveLogo] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [previewBlob, setPreviewBlob] = useState<Blob | null>(null);
  const [previewBusy, setPreviewBusy] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const previewRequest = useRef(0);

  useEffect(() => {
    let current = true;
    setLoading(true);
    void invoiceBillingProfilesApi.get(id).then(({ invoice_billing_profile: loaded }) => {
      if (!current) return;
      const initial = styleFromProfile(loaded);
      setProfile(loaded);
      setStyle(initial);
      setSavedStyle(initial);
      setHexDraft(initial.accent_color || themeDefaultAccent(initial.invoice_theme));
    }).catch((loadError) => {
      if (current) setError(loadError instanceof Error ? loadError.message : 'Unable to load this billing profile');
    }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [id]);

  useEffect(() => {
    if (!pendingLogo) {
      setPendingLogoUrl(null);
      return;
    }
    const url = URL.createObjectURL(pendingLogo);
    setPendingLogoUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [pendingLogo]);

  const hexValid = normalizeHex(hexDraft) !== null;

  // The preview is the real PDF renderer drawing a sample invoice, refreshed
  // shortly after each change. Older responses are ignored.
  useEffect(() => {
    if (!style || !hexValid) return;
    const request = ++previewRequest.current;
    setPreviewBusy(true);
    const timer = window.setTimeout(() => {
      void invoiceBillingProfilesApi.samplePdf(id, style, { logo: pendingLogo, removeLogo })
        .then((result) => {
          if (request !== previewRequest.current) return;
          setPreviewBlob(result.blob);
          setPreviewError(null);
        })
        .catch((previewFailure) => {
          if (request !== previewRequest.current) return;
          setPreviewError(previewFailure instanceof Error ? previewFailure.message : 'The preview could not be rendered');
        })
        .finally(() => { if (request === previewRequest.current) setPreviewBusy(false); });
    }, PREVIEW_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, [id, style, pendingLogo, removeLogo, hexValid]);

  const update = useCallback((patch: Partial<StyleSettings>) => {
    setNotice(null);
    setStyle((current) => (current ? { ...current, ...patch } : current));
  }, []);

  const dirty = useMemo(() => (
    Boolean(style && savedStyle && (JSON.stringify(style) !== JSON.stringify(savedStyle) || pendingLogo || removeLogo))
  ), [style, savedStyle, pendingLogo, removeLogo]);

  if (loading || !style || !profile) {
    return (
      <div>
        <Header title="Invoice style" />
        <div className="mx-auto max-w-6xl px-4 py-6 sm:px-6 lg:px-8">
          {error ? <p role="alert" className="text-base text-danger-700">{error}</p> : <p role="status" className="text-sm text-neutral-600">Loading billing profile…</p>}
        </div>
      </div>
    );
  }

  const effectiveAccent = style.accent_color || themeDefaultAccent(style.invoice_theme);
  const onAccent = textOnAccent(effectiveAccent);
  const theme = INVOICE_THEMES.find((entry) => entry.id === style.invoice_theme) || INVOICE_THEMES[0];
  const showsSavedLogo = Boolean(profile.has_logo) && !removeLogo && !pendingLogo;

  const pickTheme = (themeId: InvoiceTheme) => {
    // A theme brings its own color unless a custom color was chosen.
    const keepCustom = style.accent_color !== null && style.accent_color !== themeDefaultAccent(style.invoice_theme);
    update({ invoice_theme: themeId, accent_color: keepCustom ? style.accent_color : null });
    if (!keepCustom) setHexDraft(themeDefaultAccent(themeId));
  };

  const pickColor = (color: string) => {
    setHexDraft(color);
    update({ accent_color: color === themeDefaultAccent(style.invoice_theme) ? null : color });
  };

  const typeHex = (value: string) => {
    setHexDraft(value);
    const normalized = normalizeHex(value);
    if (normalized) update({ accent_color: normalized === themeDefaultAccent(style.invoice_theme) ? null : normalized });
  };

  const chooseLogo = (file: File | null) => {
    if (!file) return;
    if (!['image/png', 'image/jpeg'].includes(file.type) || file.size > MAX_LOGO_BYTES) {
      setError('Choose a PNG or JPEG logo that is 1 MB or smaller.');
      return;
    }
    setError(null);
    setNotice(null);
    setRemoveLogo(false);
    setPendingLogo(file);
  };

  // Discarding a chosen file keeps the saved logo; only "Remove logo"
  // marks the saved one for removal.
  const discardPendingLogo = () => {
    setNotice(null);
    setPendingLogo(null);
  };

  const removeSavedLogo = () => {
    setNotice(null);
    setRemoveLogo(true);
  };

  const save = async () => {
    if (financeReadOnly) { setError(financeWriteBlockedMessage); return; }
    if (!hexValid) { setError('Enter the brand color as a hex value like #1F4E79.'); return; }
    setSaving(true);
    setError(null);
    try {
      let { invoice_billing_profile: saved } = await invoiceBillingProfilesApi.updateStyle(id, style);
      if (pendingLogo) ({ invoice_billing_profile: saved } = await invoiceBillingProfilesApi.uploadLogo(id, pendingLogo));
      else if (removeLogo) ({ invoice_billing_profile: saved } = await invoiceBillingProfilesApi.removeLogo(id));
      const next = styleFromProfile(saved);
      setProfile(saved);
      setStyle(next);
      setSavedStyle(next);
      setPendingLogo(null);
      setRemoveLogo(false);
      setNotice('Style saved. New invoices and draft previews use it. Issued invoices keep the look they were issued with.');
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : 'Unable to save the invoice style');
    } finally {
      setSaving(false);
    }
  };

  const downloadSample = async () => {
    if (!hexValid) { setError('Enter the brand color as a hex value like #1F4E79.'); return; }
    setDownloading(true);
    setError(null);
    try {
      const result = await invoiceBillingProfilesApi.samplePdf(id, style, { logo: pendingLogo, removeLogo, download: true });
      saveBlob(result.blob, result.filename || `invoice-style-sample-${style.invoice_theme}.pdf`);
    } catch (downloadError) {
      setError(downloadError instanceof Error ? downloadError.message : 'Unable to download the sample');
    } finally {
      setDownloading(false);
    }
  };

  const toggles: { key: 'show_service_period' | 'show_item_column' | 'show_how_to_pay'; label: string; hint: string }[] = [
    { key: 'show_service_period', label: 'Service period', hint: 'The month or dates the invoice covers' },
    { key: 'show_item_column', label: 'Product or service column', hint: 'Shown when lines have a product or service name' },
    { key: 'show_how_to_pay', label: 'How to pay', hint: 'Your payment instructions' },
  ];

  return (
    <div>
      <Header
        title="Invoice style"
        mobileSticky={false}
        description={`How invoices from ${profile.name} look. Each billing profile keeps its own style.`}
        actions={(
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={downloadSample} loading={downloading} disabled={!hexValid}>
              <Download className="mr-1.5 h-4 w-4" aria-hidden="true" />Download sample PDF
            </Button>
            <Button onClick={save} loading={saving} disabled={financeReadOnly || !dirty || !hexValid}>Save style</Button>
          </div>
        )}
      />
      <div className="mx-auto max-w-6xl space-y-5 px-4 py-6 sm:px-6 lg:px-8">
        <nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-2 text-sm text-neutral-600">
          <Link to="/tools/invoices/assistant#billing-profiles" className="inline-flex min-h-11 items-center gap-1.5 rounded-full pr-2 font-medium text-primary-800 hover:underline">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />Billing profiles
          </Link>
          <span aria-hidden="true">›</span>
          <span className="font-medium text-neutral-900">{profile.name}</span>
          {dirty && <span className="rounded-full bg-amber-50 px-2.5 py-1 text-xs font-semibold text-amber-800">Unsaved changes</span>}
          <a href="#invoice-preview" className="ml-auto inline-flex min-h-11 items-center rounded-full px-2 font-medium text-primary-800 hover:underline lg:hidden">Jump to preview</a>
        </nav>
        {financeReadOnly && <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{financeWriteBlockedMessage} You can still preview styles.</p>}
        {error && <p role="alert" className="rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">{error}</p>}
        {notice && <p role="status" className="rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}

        <div className="flex flex-wrap items-start gap-5">
          {/* Edits are locked while a save is in flight so none are lost when the saved style returns. */}
          <fieldset disabled={saving} aria-busy={saving || undefined} className="m-0 flex min-w-0 flex-[1_1_380px] flex-col gap-4 border-0 p-0 disabled:opacity-80">
            <section aria-labelledby="theme-heading" className="flex flex-col gap-3 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
              <h2 id="theme-heading" className="text-base font-semibold text-neutral-900">Theme</h2>
              <div className="grid grid-cols-1 gap-2.5 min-[420px]:grid-cols-2">
                {INVOICE_THEMES.map((entry) => {
                  const selected = entry.id === style.invoice_theme;
                  return (
                    <button
                      key={entry.id}
                      type="button"
                      aria-pressed={selected}
                      onClick={() => pickTheme(entry.id)}
                      className={`flex min-h-[72px] flex-col gap-0.5 rounded-xl bg-white px-3.5 py-3 text-left transition-colors hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 ${selected ? 'border-2 border-neutral-900' : 'border border-neutral-300'}`}
                    >
                      <span className="font-semibold text-neutral-900">{entry.name}</span>
                      <span className="text-sm text-neutral-600">{entry.blurb}</span>
                    </button>
                  );
                })}
              </div>
            </section>

            <section aria-labelledby="color-heading" className="flex flex-col gap-3 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
              <h2 id="color-heading" className="text-base font-semibold text-neutral-900">Brand color</h2>
              <div className="flex flex-wrap items-center gap-2.5">
                {SWATCHES.map((color) => {
                  const selected = color === effectiveAccent;
                  return (
                    <button
                      key={color}
                      type="button"
                      aria-label={`Use color ${color}${color === themeDefaultAccent(style.invoice_theme) ? ' (theme default)' : ''}`}
                      aria-pressed={selected}
                      onClick={() => pickColor(color)}
                      className={`h-11 w-11 rounded-full shadow-[0_0_0_1px_#CBD5E1] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 ${selected ? 'border-[3px] border-neutral-900' : 'border-2 border-white'}`}
                      style={{ backgroundColor: color }}
                    />
                  );
                })}
              </div>
              <div className="flex flex-wrap items-end gap-3">
                <label className="flex flex-col gap-1 text-sm text-neutral-700">
                  Custom hex
                  <input
                    type="text"
                    inputMode="text"
                    autoComplete="off"
                    spellCheck={false}
                    value={hexDraft}
                    onChange={(event) => typeHex(event.target.value)}
                    aria-invalid={!hexValid}
                    aria-describedby="hex-help"
                    className={`${fieldClass} w-36 font-mono uppercase ${hexValid ? '' : 'border-danger-500'}`}
                  />
                </label>
                <label className="flex flex-col gap-1 text-sm text-neutral-700">
                  Pick
                  <input
                    type="color"
                    value={effectiveAccent.toLowerCase()}
                    onChange={(event) => pickColor(event.target.value.toUpperCase())}
                    className="h-11 w-14 cursor-pointer rounded-lg border border-neutral-300 bg-white p-1"
                  />
                </label>
                <span
                  className="inline-flex min-h-11 items-center rounded-lg px-3 text-sm font-semibold"
                  style={{ backgroundColor: effectiveAccent, color: onAccent }}
                  aria-hidden="true"
                >
                  Amount due
                </span>
              </div>
              <p id="hex-help" className={`text-sm ${hexValid ? 'text-neutral-600' : 'text-danger-700'}`}>
                {hexValid
                  ? `Text on this color prints in ${onAccent === '#FFFFFF' ? 'white' : 'black'} so it stays readable. ${style.accent_color ? '' : 'This is the theme’s default color.'}`
                  : 'Enter six hex digits, like #1F4E79.'}
              </p>
            </section>

            <section aria-labelledby="logo-heading" className="flex flex-col gap-3 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
              <h2 id="logo-heading" className="text-base font-semibold text-neutral-900">Logo</h2>
              <div className="flex flex-wrap items-center gap-3.5">
                <div className="flex h-16 min-w-16 max-w-48 items-center justify-center overflow-hidden rounded-xl border border-neutral-200 bg-white">
                  {pendingLogoUrl ? (
                    <img src={pendingLogoUrl} alt="New logo, not saved yet" className="max-h-14 max-w-44 object-contain" />
                  ) : showsSavedLogo ? (
                    <span className="px-3 text-center text-xs font-medium text-neutral-600">Logo on file<br />(shown in preview)</span>
                  ) : (
                    <span
                      className="flex h-16 w-16 items-center justify-center text-xl font-bold"
                      style={{ backgroundColor: effectiveAccent, color: onAccent }}
                      aria-label={`Monogram ${initialsFor(profile.legal_name || profile.name)}`}
                    >
                      {initialsFor(profile.legal_name || profile.name)}
                    </span>
                  )}
                </div>
                <div className="flex flex-col gap-1.5">
                  <div className="flex flex-wrap gap-2">
                    <label className={`inline-flex min-h-11 cursor-pointer items-center rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-800 focus-within:ring-2 focus-within:ring-primary-300 hover:bg-neutral-50 ${financeReadOnly ? 'pointer-events-none opacity-60' : ''}`}>
                      <ImagePlus className="mr-1.5 h-4 w-4" aria-hidden="true" />
                      {profile.has_logo || pendingLogo ? 'Replace logo' : 'Upload logo'}
                      <input
                        type="file"
                        accept="image/png,image/jpeg"
                        className="sr-only"
                        disabled={financeReadOnly}
                        onChange={(event) => { chooseLogo(event.target.files?.[0] || null); event.target.value = ''; }}
                      />
                    </label>
                    {pendingLogo && (
                      <Button variant="outline" onClick={discardPendingLogo} disabled={financeReadOnly}>
                        <Trash2 className="mr-1.5 h-4 w-4" aria-hidden="true" />Discard new logo
                      </Button>
                    )}
                    {showsSavedLogo && (
                      <Button variant="outline" onClick={removeSavedLogo} disabled={financeReadOnly}>
                        <Trash2 className="mr-1.5 h-4 w-4" aria-hidden="true" />Remove logo
                      </Button>
                    )}
                    {removeLogo && !pendingLogo && (
                      <Button variant="outline" onClick={() => setRemoveLogo(false)}>Keep current logo</Button>
                    )}
                  </div>
                  <p className="text-sm text-neutral-600">
                    {removeLogo
                      ? 'The logo will be removed when you save. Invoices then show your initials.'
                      : 'PNG or JPEG, up to 1 MB. Square and wide logos both work. Without a logo, invoices show your initials.'}
                  </p>
                </div>
              </div>
              <label className="flex flex-col gap-1 text-sm text-neutral-700">
                Logo size
                <select
                  value={style.logo_size}
                  onChange={(event) => update({ logo_size: event.target.value as InvoiceLogoSize })}
                  className={fieldClass}
                >
                  <option value="small">Small</option>
                  <option value="medium">Medium</option>
                  <option value="large">Large</option>
                </select>
              </label>
            </section>

            <section aria-labelledby="show-heading" className="flex flex-col gap-2 rounded-xl border border-neutral-200 bg-white p-4 sm:p-5">
              <h2 id="show-heading" className="text-base font-semibold text-neutral-900">What to show</h2>
              {toggles.map((toggle) => (
                <label key={toggle.key} className="flex min-h-11 cursor-pointer items-center gap-3 rounded-lg py-1">
                  <input
                    type="checkbox"
                    checked={style[toggle.key]}
                    onChange={(event) => update({ [toggle.key]: event.target.checked })}
                    className="h-5 w-5 shrink-0 accent-neutral-900"
                  />
                  <span className="flex flex-col">
                    <span className="text-base text-neutral-900">{toggle.label}</span>
                    <span className="text-sm text-neutral-600">{toggle.hint}</span>
                  </span>
                </label>
              ))}
              {style.show_how_to_pay && (
                <label className="flex flex-col gap-1 text-sm text-neutral-700">
                  How to pay
                  <textarea
                    rows={3}
                    value={style.payment_instructions || ''}
                    onChange={(event) => update({ payment_instructions: event.target.value || null })}
                    placeholder="Make checks payable to… or bank transfer details"
                    className={`${fieldClass} min-h-[88px] resize-y py-2.5`}
                  />
                </label>
              )}
              <label className="flex flex-col gap-1 text-sm text-neutral-700">
                Footer note
                <textarea
                  rows={2}
                  value={style.footer_note || ''}
                  onChange={(event) => update({ footer_note: event.target.value || null })}
                  placeholder="Thank you for your business."
                  className={`${fieldClass} min-h-[72px] resize-y py-2.5`}
                />
              </label>
            </section>
          </fieldset>

          <div id="invoice-preview" className="flex min-w-0 scroll-mt-4 flex-[1_1_420px] flex-col gap-2.5 lg:sticky lg:top-40">
            <div className="flex items-center justify-between gap-3">
              <h2 className="text-sm font-semibold text-neutral-700">Preview · {theme.name}</h2>
              <span role="status" className="text-sm text-neutral-600">{previewBusy ? 'Updating…' : ''}</span>
            </div>
            <div className="h-[560px] overflow-hidden rounded-xl border border-neutral-200 bg-white sm:h-[720px] lg:h-[min(720px,calc(100vh-15rem))]">
              {previewError
                ? <p role="alert" className="p-4 text-sm text-danger-700">{previewError}</p>
                : <PdfDocumentView blob={previewBlob} className="h-full" />}
            </div>
            <p className="text-sm text-neutral-600">
              This is the real PDF, drawn with a sample customer and amounts. Each billing profile keeps its own style.
              Invoices already issued keep the look they were issued with.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
