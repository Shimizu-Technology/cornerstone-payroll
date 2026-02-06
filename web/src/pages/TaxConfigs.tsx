import { useState, useEffect } from 'react';
import { Plus, CheckCircle, History, Edit, Trash2, Copy, Save, X } from 'lucide-react';
import {
  taxConfigsApi,
  type TaxConfig,
  type TaxConfigAuditLog,
  type TaxConfigBracket,
  type TaxConfigFilingStatus,
} from '@/services/api';

interface EditableConfig {
  ss_wage_base: number;
  ss_rate: number;
  medicare_rate: number;
  additional_medicare_rate: number;
  additional_medicare_threshold: number;
}

export default function TaxConfigs() {
  const [configs, setConfigs] = useState<TaxConfig[]>([]);
  const [selectedConfig, setSelectedConfig] = useState<TaxConfig | null>(null);
  const [auditLogs, setAuditLogs] = useState<TaxConfigAuditLog[]>([]);
  const [loading, setLoading] = useState(true);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [showAuditModal, setShowAuditModal] = useState(false);
  const [newYear, setNewYear] = useState(new Date().getFullYear() + 1);
  const [copyFromYear, setCopyFromYear] = useState<number | null>(null);
  
  // Editing state
  const [isEditingGlobal, setIsEditingGlobal] = useState(false);
  const [editableConfig, setEditableConfig] = useState<EditableConfig | null>(null);
  const [editingFilingStatus, setEditingFilingStatus] = useState<string | null>(null);
  const [editableStandardDeduction, setEditableStandardDeduction] = useState<number>(0);
  const [editingBrackets, setEditingBrackets] = useState<string | null>(null);
  const [editableBrackets, setEditableBrackets] = useState<TaxConfigBracket[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fetchConfigs();
  }, []);

  const fetchConfigs = async () => {
    try {
      const data = await taxConfigsApi.list();
      setConfigs(data.tax_configs);
    } catch (error) {
      console.error('Failed to fetch tax configs:', error);
    } finally {
      setLoading(false);
    }
  };

  const fetchConfigDetails = async (id: number) => {
    try {
      const data = await taxConfigsApi.get(id);
      setSelectedConfig(data.tax_config);
    } catch (error) {
      console.error('Failed to fetch config details:', error);
    }
  };

  const fetchAuditLogs = async (id: number) => {
    try {
      const data = await taxConfigsApi.auditLogs(id);
      setAuditLogs(data.audit_logs);
      setShowAuditModal(true);
    } catch (error) {
      console.error('Failed to fetch audit logs:', error);
    }
  };

  const createConfig = async () => {
    try {
      await taxConfigsApi.create({
        tax_year: newYear,
        copy_from_year: copyFromYear ?? undefined,
      });
      setShowCreateModal(false);
      fetchConfigs();
    } catch (error) {
      console.error('Failed to create config:', error);
    }
  };

  const activateConfig = async (id: number) => {
    try {
      await taxConfigsApi.activate(id);
      fetchConfigs();
    } catch (error) {
      console.error('Failed to activate config:', error);
    }
  };

  const deleteConfig = async (id: number, year: number) => {
    if (!confirm(`Are you sure you want to delete the ${year} tax configuration?`)) return;
    
    try {
      await taxConfigsApi.delete(id);
      fetchConfigs();
      if (selectedConfig?.id === id) {
        setSelectedConfig(null);
      }
    } catch (error) {
      console.error('Failed to delete config:', error);
    }
  };

  // Start editing global config settings
  const startEditingGlobal = () => {
    if (!selectedConfig) return;
    setEditableConfig({
      ss_wage_base: selectedConfig.ss_wage_base,
      ss_rate: selectedConfig.ss_rate,
      medicare_rate: selectedConfig.medicare_rate,
      additional_medicare_rate: selectedConfig.additional_medicare_rate,
      additional_medicare_threshold: selectedConfig.additional_medicare_threshold
    });
    setIsEditingGlobal(true);
  };

  // Save global config settings
  const saveGlobalConfig = async () => {
    if (!selectedConfig || !editableConfig) return;
    setSaving(true);
    
    try {
      await taxConfigsApi.update(selectedConfig.id, editableConfig);
      await fetchConfigDetails(selectedConfig.id);
      fetchConfigs();
      setIsEditingGlobal(false);
      setEditableConfig(null);
    } catch (error) {
      console.error('Failed to save config:', error);
    } finally {
      setSaving(false);
    }
  };

  // Start editing filing status standard deduction
  const startEditingFilingStatus = (fs: TaxConfigFilingStatus) => {
    setEditingFilingStatus(fs.filing_status);
    setEditableStandardDeduction(fs.standard_deduction);
  };

  // Save filing status standard deduction
  const saveFilingStatus = async () => {
    if (!selectedConfig || !editingFilingStatus) return;
    setSaving(true);
    
    try {
      await taxConfigsApi.updateFilingStatus(selectedConfig.id, editingFilingStatus, {
        standard_deduction: editableStandardDeduction,
      });
      await fetchConfigDetails(selectedConfig.id);
      setEditingFilingStatus(null);
    } catch (error) {
      console.error('Failed to save filing status:', error);
    } finally {
      setSaving(false);
    }
  };

  // Start editing brackets
  const startEditingBrackets = (fs: TaxConfigFilingStatus) => {
    if (!fs.brackets) return;
    setEditingBrackets(fs.filing_status);
    setEditableBrackets(fs.brackets.map(b => ({ ...b })));
  };

  // Update a bracket in edit mode
  const updateBracket = (order: number, field: keyof TaxConfigBracket, value: number | null) => {
    setEditableBrackets(prev => 
      prev.map(b => b.bracket_order === order ? { ...b, [field]: value } : b)
    );
  };

  // Save brackets
  const saveBrackets = async () => {
    if (!selectedConfig || !editingBrackets) return;
    setSaving(true);
    
    try {
      await taxConfigsApi.updateBrackets(selectedConfig.id, editingBrackets, {
        brackets: editableBrackets.map(b => ({
          bracket_order: b.bracket_order,
          min_income: b.min_income,
          max_income: b.max_income,
          rate: b.rate,
        })),
      });
      await fetchConfigDetails(selectedConfig.id);
      setEditingBrackets(null);
      setEditableBrackets([]);
    } catch (error) {
      console.error('Failed to save brackets:', error);
    } finally {
      setSaving(false);
    }
  };

  const formatCurrency = (amount: number) => {
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: 0,
      maximumFractionDigits: 0
    }).format(amount);
  };

  const formatPercent = (rate: number) => {
    return `${(rate * 100).toFixed(2)}%`;
  };

  const formatFilingStatus = (status: string) => {
    return status.split('_').map(word => 
      word.charAt(0).toUpperCase() + word.slice(1)
    ).join(' ');
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600"></div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex justify-between items-center">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Tax Configuration</h1>
          <p className="text-sm text-gray-500 mt-1">
            Manage annual tax rates, brackets, and deductions
          </p>
        </div>
        <button
          onClick={() => setShowCreateModal(true)}
          className="inline-flex items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700"
        >
          <Plus className="h-4 w-4 mr-2" />
          Create New Year
        </button>
      </div>

      {/* Tax Years List */}
      <div className="bg-white shadow rounded-lg overflow-hidden">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Tax Year
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                SS Wage Base
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Last Updated
              </th>
              <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {configs.map((config) => (
              <tr
                key={config.id}
                className={`hover:bg-gray-50 cursor-pointer ${
                  selectedConfig?.id === config.id ? 'bg-indigo-50' : ''
                }`}
                onClick={() => fetchConfigDetails(config.id)}
              >
                <td className="px-6 py-4 whitespace-nowrap">
                  <div className="flex items-center">
                    <span className="text-lg font-semibold text-gray-900">
                      {config.tax_year}
                    </span>
                    {config.is_active && (
                      <CheckCircle className="ml-2 h-5 w-5 text-green-500" />
                    )}
                  </div>
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                  {formatCurrency(config.ss_wage_base)}
                </td>
                <td className="px-6 py-4 whitespace-nowrap">
                  {config.is_active ? (
                    <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                      Active
                    </span>
                  ) : (
                    <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800">
                      Inactive
                    </span>
                  )}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  {new Date(config.updated_at).toLocaleDateString()}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
                  <div className="flex justify-end space-x-2" onClick={(e) => e.stopPropagation()}>
                    {!config.is_active && (
                      <button
                        onClick={() => activateConfig(config.id)}
                        className="text-green-600 hover:text-green-900"
                        title="Activate"
                      >
                        <CheckCircle className="h-5 w-5" />
                      </button>
                    )}
                    <button
                      onClick={() => fetchAuditLogs(config.id)}
                      className="text-gray-600 hover:text-gray-900"
                      title="View History"
                    >
                      <History className="h-5 w-5" />
                    </button>
                    {!config.is_active && (
                      <button
                        onClick={() => deleteConfig(config.id, config.tax_year)}
                        className="text-red-600 hover:text-red-900"
                        title="Delete"
                      >
                        <Trash2 className="h-5 w-5" />
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Selected Config Details */}
      {selectedConfig && (
        <div className="bg-white shadow rounded-lg p-6">
          <div className="flex justify-between items-start mb-6">
            <h2 className="text-xl font-bold text-gray-900">
              {selectedConfig.tax_year} Configuration
            </h2>
            <button
              onClick={() => setSelectedConfig(null)}
              className="text-gray-400 hover:text-gray-600"
            >
              ✕
            </button>
          </div>

          {/* Global Settings */}
          <div className="mb-8 p-4 bg-gray-50 rounded-lg">
            <div className="flex justify-between items-center mb-4">
              <h3 className="text-sm font-medium text-gray-700 uppercase">Tax Rates & Thresholds</h3>
              {!isEditingGlobal ? (
                <button
                  onClick={startEditingGlobal}
                  className="inline-flex items-center text-sm text-indigo-600 hover:text-indigo-800"
                >
                  <Edit className="h-4 w-4 mr-1" />
                  Edit
                </button>
              ) : (
                <div className="flex space-x-2">
                  <button
                    onClick={() => { setIsEditingGlobal(false); setEditableConfig(null); }}
                    className="inline-flex items-center text-sm text-gray-600 hover:text-gray-800"
                    disabled={saving}
                  >
                    <X className="h-4 w-4 mr-1" />
                    Cancel
                  </button>
                  <button
                    onClick={saveGlobalConfig}
                    className="inline-flex items-center text-sm text-green-600 hover:text-green-800"
                    disabled={saving}
                  >
                    <Save className="h-4 w-4 mr-1" />
                    {saving ? 'Saving...' : 'Save'}
                  </button>
                </div>
              )}
            </div>
            
            <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
              <div>
                <label className="block text-xs font-medium text-gray-500 uppercase">
                  SS Wage Base
                </label>
                {isEditingGlobal && editableConfig ? (
                  <input
                    type="number"
                    value={editableConfig.ss_wage_base}
                    onChange={(e) => setEditableConfig({ ...editableConfig, ss_wage_base: parseFloat(e.target.value) })}
                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                ) : (
                  <p className="mt-1 text-lg font-semibold text-gray-900">
                    {formatCurrency(selectedConfig.ss_wage_base)}
                  </p>
                )}
              </div>
              <div>
                <label className="block text-xs font-medium text-gray-500 uppercase">
                  SS Rate
                </label>
                {isEditingGlobal && editableConfig ? (
                  <input
                    type="number"
                    step="0.001"
                    value={editableConfig.ss_rate}
                    onChange={(e) => setEditableConfig({ ...editableConfig, ss_rate: parseFloat(e.target.value) })}
                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                ) : (
                  <p className="mt-1 text-lg font-semibold text-gray-900">
                    {formatPercent(selectedConfig.ss_rate)}
                  </p>
                )}
              </div>
              <div>
                <label className="block text-xs font-medium text-gray-500 uppercase">
                  Medicare Rate
                </label>
                {isEditingGlobal && editableConfig ? (
                  <input
                    type="number"
                    step="0.001"
                    value={editableConfig.medicare_rate}
                    onChange={(e) => setEditableConfig({ ...editableConfig, medicare_rate: parseFloat(e.target.value) })}
                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                ) : (
                  <p className="mt-1 text-lg font-semibold text-gray-900">
                    {formatPercent(selectedConfig.medicare_rate)}
                  </p>
                )}
              </div>
              <div>
                <label className="block text-xs font-medium text-gray-500 uppercase">
                  Add'l Medicare Rate
                </label>
                {isEditingGlobal && editableConfig ? (
                  <input
                    type="number"
                    step="0.001"
                    value={editableConfig.additional_medicare_rate}
                    onChange={(e) => setEditableConfig({ ...editableConfig, additional_medicare_rate: parseFloat(e.target.value) })}
                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                ) : (
                  <p className="mt-1 text-lg font-semibold text-gray-900">
                    {formatPercent(selectedConfig.additional_medicare_rate)}
                  </p>
                )}
              </div>
              <div>
                <label className="block text-xs font-medium text-gray-500 uppercase">
                  Add'l Medicare Threshold
                </label>
                {isEditingGlobal && editableConfig ? (
                  <input
                    type="number"
                    value={editableConfig.additional_medicare_threshold}
                    onChange={(e) => setEditableConfig({ ...editableConfig, additional_medicare_threshold: parseFloat(e.target.value) })}
                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                ) : (
                  <p className="mt-1 text-lg font-semibold text-gray-900">
                    {formatCurrency(selectedConfig.additional_medicare_threshold)}
                  </p>
                )}
              </div>
            </div>
          </div>

          {/* Filing Statuses */}
          <div className="space-y-6">
            {selectedConfig.filing_statuses.map((fs) => (
              <div key={fs.id} className="border rounded-lg p-4">
                <div className="flex justify-between items-center mb-4">
                  <h3 className="text-lg font-medium text-gray-900">
                    {formatFilingStatus(fs.filing_status)}
                  </h3>
                  <div className="flex items-center space-x-4">
                    {editingFilingStatus === fs.filing_status ? (
                      <div className="flex items-center space-x-2">
                        <span className="text-sm text-gray-500">Standard Deduction: $</span>
                        <input
                          type="number"
                          value={editableStandardDeduction}
                          onChange={(e) => setEditableStandardDeduction(parseFloat(e.target.value))}
                          className="w-32 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                        />
                        <button
                          onClick={() => setEditingFilingStatus(null)}
                          className="text-gray-600 hover:text-gray-800"
                          disabled={saving}
                        >
                          <X className="h-4 w-4" />
                        </button>
                        <button
                          onClick={saveFilingStatus}
                          className="text-green-600 hover:text-green-800"
                          disabled={saving}
                        >
                          <Save className="h-4 w-4" />
                        </button>
                      </div>
                    ) : (
                      <div className="flex items-center space-x-2">
                        <span className="text-sm text-gray-500">
                          Standard Deduction: <span className="font-semibold text-gray-900">{formatCurrency(fs.standard_deduction)}</span>
                        </span>
                        <button
                          onClick={() => startEditingFilingStatus(fs)}
                          className="text-indigo-600 hover:text-indigo-800"
                          title="Edit Standard Deduction"
                        >
                          <Edit className="h-4 w-4" />
                        </button>
                      </div>
                    )}
                  </div>
                </div>

                {fs.brackets && editingBrackets !== fs.filing_status && (
                  <>
                    <div className="flex justify-between items-center mb-2">
                      <span className="text-sm text-gray-500">Tax Brackets</span>
                      <button
                        onClick={() => startEditingBrackets(fs)}
                        className="inline-flex items-center text-sm text-indigo-600 hover:text-indigo-800"
                      >
                        <Edit className="h-4 w-4 mr-1" />
                        Edit Brackets
                      </button>
                    </div>
                    <table className="min-w-full">
                      <thead>
                        <tr className="text-xs font-medium text-gray-500 uppercase">
                          <th className="text-left py-2">Rate</th>
                          <th className="text-right py-2">Min Income</th>
                          <th className="text-right py-2">Max Income</th>
                          <th className="text-right py-2">Biweekly Min</th>
                          <th className="text-right py-2">Biweekly Max</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-gray-100">
                        {fs.brackets.map((bracket) => (
                          <tr key={bracket.id} className="text-sm">
                            <td className="py-2 font-medium text-indigo-600">
                              {bracket.rate_percent}%
                            </td>
                            <td className="py-2 text-right text-gray-900">
                              {formatCurrency(bracket.min_income)}
                            </td>
                            <td className="py-2 text-right text-gray-900">
                              {bracket.max_income ? formatCurrency(bracket.max_income) : '∞'}
                            </td>
                            <td className="py-2 text-right text-gray-500">
                              {formatCurrency(bracket.min_income / 26)}
                            </td>
                            <td className="py-2 text-right text-gray-500">
                              {bracket.max_income ? formatCurrency(bracket.max_income / 26) : '∞'}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </>
                )}

                {/* Editable Brackets */}
                {editingBrackets === fs.filing_status && (
                  <>
                    <div className="flex justify-between items-center mb-2">
                      <span className="text-sm text-gray-500">Tax Brackets (Editing)</span>
                      <div className="flex space-x-2">
                        <button
                          onClick={() => { setEditingBrackets(null); setEditableBrackets([]); }}
                          className="inline-flex items-center text-sm text-gray-600 hover:text-gray-800"
                          disabled={saving}
                        >
                          <X className="h-4 w-4 mr-1" />
                          Cancel
                        </button>
                        <button
                          onClick={saveBrackets}
                          className="inline-flex items-center text-sm text-green-600 hover:text-green-800"
                          disabled={saving}
                        >
                          <Save className="h-4 w-4 mr-1" />
                          {saving ? 'Saving...' : 'Save Brackets'}
                        </button>
                      </div>
                    </div>
                    <table className="min-w-full">
                      <thead>
                        <tr className="text-xs font-medium text-gray-500 uppercase">
                          <th className="text-left py-2">Rate</th>
                          <th className="text-right py-2">Min Income</th>
                          <th className="text-right py-2">Max Income</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-gray-100">
                        {editableBrackets.map((bracket) => (
                          <tr key={bracket.bracket_order} className="text-sm">
                            <td className="py-2">
                              <input
                                type="number"
                                step="0.01"
                                value={(bracket.rate * 100).toFixed(1)}
                                onChange={(e) => updateBracket(bracket.bracket_order, 'rate', parseFloat(e.target.value) / 100)}
                                className="w-20 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                              />
                              <span className="ml-1 text-gray-500">%</span>
                            </td>
                            <td className="py-2 text-right">
                              <input
                                type="number"
                                value={bracket.min_income}
                                onChange={(e) => updateBracket(bracket.bracket_order, 'min_income', parseFloat(e.target.value))}
                                className="w-32 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm text-right"
                              />
                            </td>
                            <td className="py-2 text-right">
                              <input
                                type="number"
                                value={bracket.max_income ?? ''}
                                placeholder="∞"
                                onChange={(e) => updateBracket(bracket.bracket_order, 'max_income', e.target.value ? parseFloat(e.target.value) : null)}
                                className="w-32 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm text-right"
                              />
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    <p className="mt-2 text-xs text-gray-500">
                      Leave "Max Income" empty for the top bracket (no upper limit).
                    </p>
                  </>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Create Modal */}
      {showCreateModal && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white rounded-lg p-6 w-full max-w-md">
            <h3 className="text-lg font-medium text-gray-900 mb-4">
              Create New Tax Year
            </h3>
            
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700">
                  Tax Year
                </label>
                <input
                  type="number"
                  value={newYear}
                  onChange={(e) => setNewYear(parseInt(e.target.value))}
                  className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700">
                  Copy From (optional)
                </label>
                <select
                  value={copyFromYear || ''}
                  onChange={(e) => setCopyFromYear(e.target.value ? parseInt(e.target.value) : null)}
                  className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option value="">Start from scratch</option>
                  {configs.map((c) => (
                    <option key={c.id} value={c.tax_year}>
                      Copy from {c.tax_year}
                    </option>
                  ))}
                </select>
                <p className="mt-1 text-xs text-gray-500">
                  Copying will duplicate all brackets and settings, then you can update the values.
                </p>
              </div>
            </div>

            <div className="mt-6 flex justify-end space-x-3">
              <button
                onClick={() => setShowCreateModal(false)}
                className="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                onClick={createConfig}
                className="px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
              >
                <Copy className="h-4 w-4 inline mr-2" />
                Create
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Audit Log Modal */}
      {showAuditModal && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white rounded-lg p-6 w-full max-w-2xl max-h-[80vh] overflow-auto">
            <div className="flex justify-between items-center mb-4">
              <h3 className="text-lg font-medium text-gray-900">
                Change History
              </h3>
              <button
                onClick={() => setShowAuditModal(false)}
                className="text-gray-400 hover:text-gray-600"
              >
                ✕
              </button>
            </div>
            
            {auditLogs.length === 0 ? (
              <p className="text-gray-500 text-center py-8">No changes recorded yet.</p>
            ) : (
              <div className="space-y-3">
                {auditLogs.map((log) => (
                  <div key={log.id} className="border-l-4 border-indigo-500 pl-4 py-2">
                    <div className="flex justify-between text-sm">
                      <span className="font-medium text-gray-900 capitalize">
                        {log.action}
                        {log.field_name && `: ${log.field_name}`}
                      </span>
                      <span className="text-gray-500">
                        {new Date(log.created_at).toLocaleString()}
                      </span>
                    </div>
                    {log.old_value && (
                      <p className="text-sm text-gray-500">
                        Changed from <span className="text-red-600">{log.old_value}</span> to{' '}
                        <span className="text-green-600">{log.new_value}</span>
                      </p>
                    )}
                    {!log.old_value && log.new_value && (
                      <p className="text-sm text-gray-600">{log.new_value}</p>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
