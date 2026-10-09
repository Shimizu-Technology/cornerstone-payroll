import { useCallback, useEffect, useRef, useState } from 'react';
import { employeeIntakeApi, type EmployeeIntakeSettings } from '@/services/employee-intake-api';

export function useEmployeeIntakeSettings(companyId: number, isClient: boolean, enabled = true) {
  const [result, setResult] = useState<{ companyId: number; isClient: boolean; data: EmployeeIntakeSettings } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const requestId = useRef(0);
  const scope = `${companyId}:${isClient}`;
  const scopeRef = useRef(scope);
  scopeRef.current = scope;
  const settings = result?.companyId === companyId && result.isClient === isClient ? result.data : null;

  const reload = useCallback(async () => {
    const generation = ++requestId.current;
    const requestedScope = `${companyId}:${isClient}`;
    setLoading(true);
    setError(null);
    try {
      const response = await employeeIntakeApi.settings(companyId, isClient);
      if (generation !== requestId.current || scopeRef.current !== requestedScope) return;
      setResult({ companyId, isClient, data: response.data });
    } catch (caught) {
      if (generation !== requestId.current || scopeRef.current !== requestedScope) return;
      setResult(null);
      setError(caught instanceof Error ? caught.message : 'Could not load employee entry settings.');
    } finally {
      if (generation === requestId.current && scopeRef.current === requestedScope) setLoading(false);
    }
  }, [companyId, isClient]);

  useEffect(() => {
    if (enabled) void reload();
    return () => { requestId.current += 1; };
  }, [reload, enabled]);

  useEffect(() => {
    if (!settings?.enabled || !settings.expires_at) return;
    const delay = new Date(settings.expires_at).getTime() - Date.now();
    if (!Number.isFinite(delay)) return;
    const timer = window.setTimeout(() => { void reload(); }, Math.min(Math.max(delay, 0) + 100, 2_147_483_647));
    return () => window.clearTimeout(timer);
  }, [settings, reload]);

  return { settings, loading, error, reload };
}
