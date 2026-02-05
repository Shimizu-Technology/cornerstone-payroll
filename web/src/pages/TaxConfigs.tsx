import { useState, useEffect } from 'react';
import { Plus, CheckCircle, History, Edit, Trash2, Copy } from 'lucide-react';

interface TaxBracket {
  id: number;
  bracket_order: number;
  min_income: number;
  max_income: number | null;
  rate: number;
  rate_percent: number;
}

interface FilingStatusConfig {
  id: number;
  filing_status: string;
  standard_deduction: number;
  brackets?: TaxBracket[];
}

interface TaxConfig {
  id: number;
  tax_year: number;
  ss_wage_base: number;
  ss_rate: number;
  medicare_rate: number;
  additional_medicare_rate: number;
  additional_medicare_threshold: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  filing_statuses: FilingStatusConfig[];
}

interface AuditLog {
  id: number;
  action: string;
  field_name: string | null;
  old_value: string | null;
  new_value: string | null;
  user_id: number | null;
  ip_address: string | null;
  created_at: string;
}

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001';

export default function TaxConfigs() {
  const [configs, setConfigs] = useState<TaxConfig[]>([]);
  const [selectedConfig, setSelectedConfig] = useState<TaxConfig | null>(null);
  const [auditLogs, setAuditLogs] = useState<AuditLog[]>([]);
  const [loading, setLoading] = useState(true);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [showAuditModal, setShowAuditModal] = useState(false);
  const [newYear, setNewYear] = useState(new Date().getFullYear() + 1);
  const [copyFromYear, setCopyFromYear] = useState<number | null>(null);

  useEffect(() => {
    fetchConfigs();
  }, []);

  const fetchConfigs = async () => {
    try {
      const res = await fetch(`${API_URL}/api/v1/admin/tax_configs`);
      const data = await res.json();
      setConfigs(data.tax_configs);
    } catch (error) {
      console.error('Failed to fetch tax configs:', error);
    } finally {
      setLoading(false);
    }
  };

  const fetchConfigDetails = async (id: number) => {
    try {
      const res = await fetch(`${API_URL}/api/v1/admin/tax_configs/${id}`);
      const data = await res.json();
      setSelectedConfig(data.tax_config);
    } catch (error) {
      console.error('Failed to fetch config details:', error);
    }
  };

  const fetchAuditLogs = async (id: number) => {
    try {
      const res = await fetch(`${API_URL}/api/v1/admin/tax_configs/${id}/audit_logs`);
      const data = await res.json();
      setAuditLogs(data.audit_logs);
      setShowAuditModal(true);
    } catch (error) {
      console.error('Failed to fetch audit logs:', error);
    }
  };

  const createConfig = async () => {
    try {
      const body: Record<string, number | null> = { tax_year: newYear };
      if (copyFromYear) {
        body.copy_from_year = copyFromYear;
      }
      
      const res = await fetch(`${API_URL}/api/v1/admin/tax_configs`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });
      
      if (res.ok) {
        setShowCreateModal(false);
        fetchConfigs();
      }
    } catch (error) {
      console.error('Failed to create config:', error);
    }
  };

  const activateConfig = async (id: number) => {
    try {
      const res = await fetch(`${API_URL}/api/v1/admin/tax_configs/${id}/activate`, {
        method: 'POST'
      });
      if (res.ok) {
        fetchConfigs();
      }
    } catch (error) {
      console.error('Failed to activate config:', error);
    }
  };

  const deleteConfig = async (id: number, year: number) => {
    if (!confirm(`Are you sure you want to delete the ${year} tax configuration?`)) return;
    
    try {
      const res = await fetch(`${API_URL}/api/v1/admin/tax_configs/${id}`, {
        method: 'DELETE'
      });
      if (res.ok) {
        fetchConfigs();
        if (selectedConfig?.id === id) {
          setSelectedConfig(null);
        }
      }
    } catch (error) {
      console.error('Failed to delete config:', error);
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
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8 p-4 bg-gray-50 rounded-lg">
            <div>
              <label className="block text-xs font-medium text-gray-500 uppercase">
                SS Wage Base
              </label>
              <p className="mt-1 text-lg font-semibold text-gray-900">
                {formatCurrency(selectedConfig.ss_wage_base)}
              </p>
            </div>
            <div>
              <label className="block text-xs font-medium text-gray-500 uppercase">
                SS Rate
              </label>
              <p className="mt-1 text-lg font-semibold text-gray-900">
                {formatPercent(selectedConfig.ss_rate)}
              </p>
            </div>
            <div>
              <label className="block text-xs font-medium text-gray-500 uppercase">
                Medicare Rate
              </label>
              <p className="mt-1 text-lg font-semibold text-gray-900">
                {formatPercent(selectedConfig.medicare_rate)}
              </p>
            </div>
            <div>
              <label className="block text-xs font-medium text-gray-500 uppercase">
                Add'l Medicare
              </label>
              <p className="mt-1 text-lg font-semibold text-gray-900">
                {formatPercent(selectedConfig.additional_medicare_rate)} over {formatCurrency(selectedConfig.additional_medicare_threshold)}
              </p>
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
                  <div className="text-sm text-gray-500">
                    Standard Deduction: <span className="font-semibold text-gray-900">{formatCurrency(fs.standard_deduction)}</span>
                  </div>
                </div>

                {fs.brackets && (
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
