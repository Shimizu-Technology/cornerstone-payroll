/**
 * CPR-66: Check Settings Page
 * Operator-level configuration for check printing: offsets, stock type, next check number.
 */
import { useState, useEffect } from 'react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { checksApi } from '@/services/api';
import type { CheckSettings as CheckSettingsType } from '@/types';

export function CheckSettingsPage() {
  const [settings, setSettings] = useState<CheckSettingsType | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  // Editable form state
  const [stockType, setStockType] = useState<'bottom_check' | 'top_check'>('bottom_check');
  const [offsetX, setOffsetX] = useState('0.000');
  const [offsetY, setOffsetY] = useState('0.000');
  const [bankName, setBankName] = useState('');
  const [bankAddress, setBankAddress] = useState('');
  const [nextCheckNumber, setNextCheckNumber] = useState('');
  const [nextCheckNumberSaving, setNextCheckNumberSaving] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const data = await checksApi.getSettings();
        const s = data.check_settings;
        setSettings(s);
        setStockType(s.check_stock_type);
        setOffsetX(s.check_offset_x.toFixed(3));
        setOffsetY(s.check_offset_y.toFixed(3));
        setBankName(s.bank_name ?? '');
        setBankAddress(s.bank_address ?? '');
        setNextCheckNumber(String(s.next_check_number));
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load settings');
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const handleSaveSettings = async () => {
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const data = await checksApi.updateSettings({
        check_stock_type: stockType,
        check_offset_x: parseFloat(offsetX),
        check_offset_y: parseFloat(offsetY),
        bank_name: bankName.trim() || undefined,
        bank_address: bankAddress.trim() || undefined,
      });
      setSettings(data.check_settings);
      setSuccess('Settings saved.');
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

  const handleAlignmentTest = () => {
    window.open(checksApi.alignmentTestPdfUrl(), '_blank');
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

      <div className="p-4 sm:p-6 lg:p-8 max-w-3xl mx-auto space-y-6">

        {/* Feedback */}
        {error && (
          <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-800">{error}</div>
        )}
        {success && (
          <div className="p-3 bg-green-50 border border-green-200 rounded-lg text-sm text-green-800">{success}</div>
        )}

        {/* Check Stock Settings */}
        <Card>
          <div className="p-4 border-b">
            <h2 className="font-semibold text-gray-900">Check Stock Configuration</h2>
            <p className="text-sm text-gray-500 mt-0.5">
              Configure for your pre-printed check stock. Changes take effect on the next PDF generation.
            </p>
          </div>
          <CardContent className="p-4 space-y-4">
            {/* Stock Type */}
            <div className="space-y-1">
              <Label htmlFor="stock-type">Stock Type</Label>
              <Select
                id="stock-type"
                value={stockType}
                onChange={(e) => setStockType(e.target.value as 'bottom_check' | 'top_check')}
                className="w-64"
              >
                <option value="bottom_check">Bottom Check (most common US payroll)</option>
                <option value="top_check">Top Check</option>
              </Select>
              <p className="text-xs text-gray-500">
                Bottom check: stubs on top, check face at bottom. Top check: reversed.
              </p>
            </div>

            {/* Offset calibration */}
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <Label htmlFor="offset-x">X Offset (inches)</Label>
                <Input
                  id="offset-x"
                  type="number"
                  step="0.01"
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
                  type="number"
                  step="0.01"
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

            {/* Alignment test */}
            <div className="pt-2 border-t flex flex-wrap items-center gap-3">
              <Button variant="outline" onClick={handleAlignmentTest} type="button">
                ⬇ Download Alignment Test PDF
              </Button>
              <p className="text-xs text-gray-500">
                Print on plain paper and hold against your check stock to verify field positions
                before using real checks.
              </p>
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
                <Input
                  id="next-check-number"
                  type="number"
                  min="1"
                  value={nextCheckNumber}
                  onChange={(e) => setNextCheckNumber(e.target.value)}
                  className="w-32 font-mono"
                />
              </div>
              <Button
                variant="outline"
                onClick={handleUpdateNextCheckNumber}
                disabled={nextCheckNumberSaving}
              >
                {nextCheckNumberSaving ? 'Updating…' : 'Update Starting Number'}
              </Button>
            </div>
            <div className="text-xs text-gray-500 space-y-1">
              <p>⚠ This can only be changed if no checks have been issued this calendar year.</p>
              <p>Current value: <span className="font-mono font-medium">{settings?.next_check_number}</span></p>
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
    </div>
  );
}
