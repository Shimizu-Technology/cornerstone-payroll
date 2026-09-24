import { useEffect, useRef, useState } from 'react';
import { ExternalLink, Printer, Plus } from 'lucide-react';
import { Link } from 'react-router';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { printerProfilesApi, type PrinterProfile } from '@/services/api';
import type { CheckStockType } from '@/types';

interface PrinterProfileManagerDialogProps {
  open: boolean;
  stockType: CheckStockType;
  profiles: PrinterProfile[];
  selectedProfileId: number | null;
  onOpenChange: (open: boolean) => void;
  onSelected: (profile: PrinterProfile) => Promise<void>;
  onCreated: (profile: PrinterProfile) => Promise<void>;
}

function stockLabel(stockType: CheckStockType): string {
  if (stockType === 'first_hawaiian_4up') return 'First Hawaiian 4-up';
  return stockType === 'top_check' ? 'Top check' : 'Bottom check';
}

export function PrinterProfileManagerDialog({
  open,
  stockType,
  profiles,
  selectedProfileId,
  onOpenChange,
  onSelected,
  onCreated,
}: PrinterProfileManagerDialogProps) {
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [offsetX, setOffsetX] = useState('0');
  const [offsetY, setOffsetY] = useState('0');
  const [busyProfileId, setBusyProfileId] = useState<number | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const wasOpenRef = useRef(false);

  useEffect(() => {
    if (open && !wasOpenRef.current) {
      setCreating(profiles.length === 0);
      setError(null);
    }
    wasOpenRef.current = open;
  }, [open, profiles.length]);

  const resetForm = (): void => {
    setName('');
    setDescription('');
    setOffsetX('0');
    setOffsetY('0');
    setError(null);
  };

  const selectProfile = async (profile: PrinterProfile): Promise<void> => {
    setBusyProfileId(profile.id);
    setError(null);
    try {
      await onSelected(profile);
      onOpenChange(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not select this printer profile.');
    } finally {
      setBusyProfileId(null);
    }
  };

  const createProfile = async (): Promise<void> => {
    if (!name.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const response = await printerProfilesApi.create({
        name: name.trim(),
        description: description.trim() || null,
        check_stock_type: stockType,
        check_offset_x: Number(offsetX),
        check_offset_y: Number(offsetY),
      });
      resetForm();
      setCreating(false);
      try {
        await onCreated(response.printer_profile);
        onOpenChange(false);
      } catch (selectError) {
        setError(selectError instanceof Error
          ? `The profile was created but could not be selected. Choose “Use profile” to retry. ${selectError.message}`
          : 'The profile was created but could not be selected. Choose “Use profile” to retry.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create the printer profile.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange} dismissOnEscape={!saving && busyProfileId === null}>
      <DialogContent className="dialog-wide flex max-h-[94vh] max-w-3xl flex-col overflow-hidden p-0">
        <DialogHeader className="shrink-0 border-b border-slate-200 bg-slate-950 px-6 py-5 text-white">
          <DialogTitle className="text-xl text-white">Printer profiles</DialogTitle>
          <DialogDescription className="mt-1 text-slate-300">
            Shared calibrations for {stockLabel(stockType)} stock. Your selection is personal; creating a profile makes it available to the payroll team.
          </DialogDescription>
        </DialogHeader>

        <div className="grid min-h-0 flex-1 gap-6 overflow-y-auto p-6 md:grid-cols-[1fr_0.9fr]">
          <section>
            <div className="flex items-center justify-between gap-3">
              <div>
                <h3 className="text-sm font-semibold text-slate-950">Available profiles</h3>
                <p className="mt-1 text-xs text-slate-500">Choose the physical printer you will use for this package.</p>
              </div>
              <Button size="sm" variant="outline" className="gap-1.5" onClick={() => setCreating(true)} disabled={saving || busyProfileId !== null}>
                <Plus className="h-3.5 w-3.5" /> New profile
              </Button>
            </div>
            <div className="mt-4 space-y-2">
              {profiles.map((profile) => (
                <div key={profile.id} className={`rounded-xl border p-3 ${selectedProfileId === profile.id ? 'border-blue-300 bg-blue-50' : 'border-slate-200 bg-white'}`}>
                  <div className="flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-semibold text-slate-950">{profile.name}</p>
                      <p className="mt-1 text-xs text-slate-500">X {Number(profile.check_offset_x).toFixed(3)} in · Y {Number(profile.check_offset_y).toFixed(3)} in · Version {profile.lock_version}</p>
                    </div>
                    <Button
                      size="sm"
                      variant={selectedProfileId === profile.id ? 'secondary' : 'outline'}
                      aria-label={selectedProfileId === profile.id ? `${profile.name} selected` : `Use ${profile.name}`}
                      loading={busyProfileId === profile.id}
                      loadingLabel="Selecting…"
                      disabled={selectedProfileId === profile.id || busyProfileId !== null || saving}
                      onClick={() => void selectProfile(profile)}
                    >
                      {selectedProfileId === profile.id ? 'Selected' : 'Use profile'}
                    </Button>
                  </div>
                  {profile.description && <p className="mt-2 text-xs leading-5 text-slate-600">{profile.description}</p>}
                </div>
              ))}
              {profiles.length === 0 && (
                <div className="rounded-xl border border-dashed border-slate-300 px-4 py-8 text-center">
                  <Printer className="mx-auto h-6 w-6 text-slate-400" />
                  <p className="mt-2 text-sm font-medium text-slate-700">No profile for this stock yet</p>
                  <p className="mt-1 text-xs text-slate-500">Create one here so the package uses a named, versioned calibration.</p>
                </div>
              )}
            </div>
            <Link to="/check-settings" className="mt-4 inline-flex items-center gap-1.5 text-xs font-semibold text-blue-700 hover:underline">
              Open printer calibration and profile library <ExternalLink className="h-3.5 w-3.5" />
            </Link>
          </section>

          <section className={`rounded-2xl border border-slate-200 bg-slate-50 p-4 ${creating ? '' : 'opacity-70'}`}>
            <h3 className="text-sm font-semibold text-slate-950">Create a shared profile</h3>
            <p className="mt-1 text-xs leading-5 text-slate-500">Start at zero offsets. Use positive or negative inches only if this printer needs alignment correction.</p>
            <div className="mt-4 space-y-4">
              <Input label="Profile name" value={name} onChange={(event) => setName(event.target.value)} placeholder="Payroll room LaserJet" disabled={!creating || saving} />
              <Input label="Description (optional)" value={description} onChange={(event) => setDescription(event.target.value)} placeholder="Tray 2, accounting office" disabled={!creating || saving} />
              <Input label="Check stock" value={stockLabel(stockType)} disabled />
              <div className="grid grid-cols-2 gap-3">
                <Input label="Horizontal offset" type="number" step="0.001" min="-2" max="2" value={offsetX} onChange={(event) => setOffsetX(event.target.value)} disabled={!creating || saving} />
                <Input label="Vertical offset" type="number" step="0.001" min="-2" max="2" value={offsetY} onChange={(event) => setOffsetY(event.target.value)} disabled={!creating || saving} />
              </div>
              <p className="text-xs text-slate-500">Offsets are measured in inches. You can manage profiles you create and copy a teammate’s profile when you need your own calibration.</p>
              <Button className="w-full" loading={saving} loadingLabel="Creating and selecting…" disabled={!creating || !name.trim()} onClick={() => void createProfile()}>
                Create and use profile
              </Button>
            </div>
          </section>
        </div>

        {error && <div role="alert" className="mx-6 mb-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">{error}</div>}
        <DialogFooter className="shrink-0 border-t border-slate-200 bg-white px-6 py-4">
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={saving || busyProfileId !== null}>Done</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
