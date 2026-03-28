import { useState, useEffect, useCallback } from 'react';
import { Plus, Building2, Check, X, Pencil } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { companiesApi, ApiError } from '@/services/api';
import type { CompanyListItem, CompanyDetail, CompanyFormData } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';

const payFrequencyOptions = [
  { value: 'biweekly', label: 'Biweekly' },
  { value: 'weekly', label: 'Weekly' },
  { value: 'semimonthly', label: 'Semi-monthly' },
  { value: 'monthly', label: 'Monthly' },
];

const checkStockOptions = [
  { value: 'bottom_check', label: 'Bottom Check' },
  { value: 'top_check', label: 'Top Check' },
];

const emptyForm: CompanyFormData = {
  name: '',
  ein: '',
  pay_frequency: 'biweekly',
  address_line1: '',
  address_line2: '',
  city: '',
  state: '',
  zip: '',
  phone: '',
  email: '',
  bank_name: '',
  bank_address: '',
  check_stock_type: 'bottom_check',
  next_check_number: 1001,
};

function formatEIN(value: string): string {
  const digits = value.replace(/\D/g, '').slice(0, 9);
  if (digits.length <= 2) return digits;
  return `${digits.slice(0, 2)}-${digits.slice(2)}`;
}

export function Clients() {
  const { user } = useAuth();
  const { refreshCompanies } = useCompany();
  const [companies, setCompanies] = useState<CompanyListItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isSuperAdmin, setIsSuperAdmin] = useState(false);

  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [form, setForm] = useState<CompanyFormData>({ ...emptyForm });
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await companiesApi.list();
      setCompanies(data.companies);
      setIsSuperAdmin(data.is_super_admin);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load clients');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const handleAddNew = () => {
    setEditingId(null);
    setForm({ ...emptyForm });
    setFormError(null);
    setShowForm(true);
  };

  const handleEdit = async (id: number) => {
    try {
      const data = await companiesApi.get(id);
      const c = data.company;
      setForm({
        name: c.name || '',
        ein: c.ein || '',
        pay_frequency: c.pay_frequency || 'biweekly',
        active: c.active,
        address_line1: c.address_line1 || '',
        address_line2: c.address_line2 || '',
        city: c.city || '',
        state: c.state || '',
        zip: c.zip || '',
        phone: c.phone || '',
        email: c.email || '',
        bank_name: c.bank_name || '',
        bank_address: c.bank_address || '',
        check_stock_type: c.check_stock_type || 'bottom_check',
        next_check_number: c.next_check_number ?? 1001,
      });
      setEditingId(id);
      setFormError(null);
      setShowForm(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load client details');
    }
  };

  const handleCancel = () => {
    setShowForm(false);
    setEditingId(null);
    setForm({ ...emptyForm });
    setFormError(null);
  };

  const handleSave = async () => {
    if (!form.name.trim()) {
      setFormError('Client name is required');
      return;
    }

    setSaving(true);
    setFormError(null);

    try {
      if (editingId) {
        await companiesApi.update(editingId, form);
      } else {
        await companiesApi.create(form);
      }
      setShowForm(false);
      setEditingId(null);
      setForm({ ...emptyForm });
      await load();
      refreshCompanies();
    } catch (err) {
      if (err instanceof ApiError) {
        setFormError(err.message);
      } else {
        setFormError(err instanceof Error ? err.message : 'Failed to save');
      }
    } finally {
      setSaving(false);
    }
  };

  const updateField = (field: keyof CompanyFormData, value: string | number | boolean) => {
    setForm(prev => ({ ...prev, [field]: value }));
  };

  return (
    <>
      <Header
        title="Client Management"
        subtitle="Manage payroll clients"
      />

      <div className="p-6 space-y-6">
        {/* Error */}
        {error && (
          <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
            {error}
          </div>
        )}

        {/* Add new button */}
        {isSuperAdmin && !showForm && (
          <div className="flex justify-end">
            <Button onClick={handleAddNew}>
              <Plus className="w-4 h-4 mr-2" />
              Add New Client
            </Button>
          </div>
        )}

        {/* Create / Edit form */}
        {showForm && (
          <Card className="p-6">
            <h3 className="text-lg font-semibold mb-4">
              {editingId ? 'Edit Client' : 'New Client'}
            </h3>

            {formError && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
                {formError}
              </div>
            )}

            {/* Basic Info */}
            <div className="space-y-4">
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1">Basic Information</h4>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Client Name <span className="text-red-500">*</span>
                  </label>
                  <Input
                    value={form.name}
                    onChange={(e) => updateField('name', e.target.value)}
                    placeholder="e.g. MoSa's Hotbox, Inc."
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">EIN</label>
                  <Input
                    value={form.ein || ''}
                    onChange={(e) => updateField('ein', formatEIN(e.target.value))}
                    placeholder="XX-XXXXXXX"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Pay Frequency</label>
                  <Select
                    value={form.pay_frequency}
                    onChange={(e) => updateField('pay_frequency', e.target.value)}
                  >
                    {payFrequencyOptions.map(opt => (
                      <option key={opt.value} value={opt.value}>{opt.label}</option>
                    ))}
                  </Select>
                </div>
              </div>

              {/* Contact */}
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Contact</h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Phone</label>
                  <Input
                    value={form.phone || ''}
                    onChange={(e) => updateField('phone', e.target.value)}
                    placeholder="(671) 555-1234"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Email</label>
                  <Input
                    type="email"
                    value={form.email || ''}
                    onChange={(e) => updateField('email', e.target.value)}
                    placeholder="payroll@company.com"
                  />
                </div>
              </div>

              {/* Address */}
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Address</h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Address Line 1</label>
                  <Input
                    value={form.address_line1 || ''}
                    onChange={(e) => updateField('address_line1', e.target.value)}
                    placeholder="123 Main St"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Address Line 2</label>
                  <Input
                    value={form.address_line2 || ''}
                    onChange={(e) => updateField('address_line2', e.target.value)}
                    placeholder="Suite 100"
                  />
                </div>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">City</label>
                  <Input
                    value={form.city || ''}
                    onChange={(e) => updateField('city', e.target.value)}
                    placeholder="Tamuning"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">State</label>
                  <Input
                    value={form.state || ''}
                    onChange={(e) => updateField('state', e.target.value)}
                    placeholder="GU"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">ZIP</label>
                  <Input
                    value={form.zip || ''}
                    onChange={(e) => updateField('zip', e.target.value)}
                    placeholder="96913"
                  />
                </div>
              </div>

              {/* Bank Info */}
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Bank Information</h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Bank Name</label>
                  <Input
                    value={form.bank_name || ''}
                    onChange={(e) => updateField('bank_name', e.target.value)}
                    placeholder="Bank of Guam"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Bank Address</label>
                  <Input
                    value={form.bank_address || ''}
                    onChange={(e) => updateField('bank_address', e.target.value)}
                    placeholder="111 Chalan Santo Papa"
                  />
                </div>
              </div>

              {/* Check Settings */}
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Check Settings</h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Check Stock Type</label>
                  <Select
                    value={form.check_stock_type || 'bottom_check'}
                    onChange={(e) => updateField('check_stock_type', e.target.value)}
                  >
                    {checkStockOptions.map(opt => (
                      <option key={opt.value} value={opt.value}>{opt.label}</option>
                    ))}
                  </Select>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Next Check Number</label>
                  <Input
                    type="number"
                    value={form.next_check_number ?? 1001}
                    onChange={(e) => updateField('next_check_number', parseInt(e.target.value) || 1001)}
                  />
                </div>
              </div>

              {/* Active toggle (edit only) */}
              {editingId && (
                <div className="flex items-center gap-3 pt-2">
                  <label className="text-sm font-medium text-gray-700">Active</label>
                  <button
                    type="button"
                    role="switch"
                    aria-checked={form.active !== false}
                    onClick={() => updateField('active', form.active === false)}
                    className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                      form.active !== false ? 'bg-blue-600' : 'bg-gray-300'
                    }`}
                  >
                    <span
                      className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                        form.active !== false ? 'translate-x-6' : 'translate-x-1'
                      }`}
                    />
                  </button>
                </div>
              )}
            </div>

            {/* Actions */}
            <div className="flex justify-end gap-3 mt-6 pt-4 border-t">
              <Button variant="outline" onClick={handleCancel} disabled={saving}>
                <X className="w-4 h-4 mr-1" /> Cancel
              </Button>
              <Button onClick={handleSave} disabled={saving}>
                <Check className="w-4 h-4 mr-1" />
                {saving ? 'Saving…' : editingId ? 'Update Client' : 'Create Client'}
              </Button>
            </div>
          </Card>
        )}

        {/* Clients list */}
        {loading ? (
          <div className="flex items-center justify-center py-12 text-gray-500">Loading clients…</div>
        ) : (
          <Card>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Client Name</TableHead>
                  <TableHead>EIN</TableHead>
                  <TableHead>Pay Frequency</TableHead>
                  <TableHead className="text-center">Employees</TableHead>
                  <TableHead className="text-center">Status</TableHead>
                  {isSuperAdmin && <TableHead className="text-right">Actions</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {companies.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={isSuperAdmin ? 6 : 5} className="text-center py-8 text-gray-500">
                      No clients found. Click "Add New Client" to get started.
                    </TableCell>
                  </TableRow>
                ) : (
                  companies.map((c) => (
                    <TableRow key={c.id}>
                      <TableCell>
                        <div className="flex items-center gap-2">
                          <Building2 className="w-4 h-4 text-gray-400" />
                          <span className="font-medium text-gray-900">{c.name}</span>
                        </div>
                      </TableCell>
                      <TableCell className="text-gray-600 font-mono text-sm">—</TableCell>
                      <TableCell className="text-gray-600 capitalize">{c.pay_frequency}</TableCell>
                      <TableCell className="text-center">
                        <span className="text-gray-900 font-medium">{c.active_employees}</span>
                        <span className="text-gray-400 text-xs ml-1">/ {c.total_employees}</span>
                      </TableCell>
                      <TableCell className="text-center">
                        {c.active !== false ? (
                          <Badge variant="success">Active</Badge>
                        ) : (
                          <Badge variant="default">Inactive</Badge>
                        )}
                      </TableCell>
                      {isSuperAdmin && (
                        <TableCell className="text-right">
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => handleEdit(c.id)}
                            className="text-xs"
                          >
                            <Pencil className="w-3 h-3 mr-1" /> Edit
                          </Button>
                        </TableCell>
                      )}
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </Card>
        )}
      </div>
    </>
  );
}
