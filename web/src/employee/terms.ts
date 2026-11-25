import { useEffect, useState } from 'react';
import { API_BASE_URL } from './config';

export interface EmployeeTerms {
  version: string;
  title: string;
  termsUrl: string;
  privacyUrl: string;
}

function safeDocumentUrl(value: unknown): value is string {
  return typeof value === 'string' && !/[\\\s]/.test(value) && /^(https:\/\/[^/]+|\/[^/])/.test(value);
}

export async function fetchEmployeeTerms(baseUrl: string, signal?: AbortSignal): Promise<EmployeeTerms | null> {
  const response = await fetch(`${baseUrl.replace(/\/+$/, '')}/public/employee_terms`, {
    signal, cache: 'no-store', credentials: 'omit', redirect: 'error',
  });
  if (!response.ok) return null;
  const terms = await response.json();
  if (!terms || typeof terms.version !== 'string' || !terms.version || typeof terms.title !== 'string' ||
      !safeDocumentUrl(terms.terms_url) || !safeDocumentUrl(terms.privacy_url)) return null;
  return { version: terms.version, title: terms.title, termsUrl: terms.terms_url, privacyUrl: terms.privacy_url };
}

export function useEmployeeTerms() {
  const [terms, setTerms] = useState<EmployeeTerms | null>();
  const [loadFailed, setLoadFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    void fetchEmployeeTerms(API_BASE_URL, controller.signal).then((value) => {
      if (!controller.signal.aborted) setTerms(value);
    }).catch(() => {
      if (!controller.signal.aborted) setLoadFailed(true);
    });
    return () => controller.abort();
  }, [attempt]);

  return { terms, loadFailed, reload: () => {
    setLoadFailed(false);
    setTerms(undefined);
    setAttempt((value) => value + 1);
  } };
}
