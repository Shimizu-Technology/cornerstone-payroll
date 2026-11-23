import { StagingContext } from './components/StagingContext'
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PostHogProvider } from './providers/PostHogProvider';
import App from './App.tsx';
import { clientSubdomainHost } from './lib/tenant-subdomain';
import { TenantComingSoon } from './pages/tenant/TenantComingSoon';
import './index.css';

const employeeSurface = import.meta.env.VITE_APP_SURFACE === 'employee';
const tenantHost = employeeSurface ? null : clientSubdomainHost(window.location, import.meta.env.DEV);

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <StagingContext />
    {tenantHost ? (
      <TenantComingSoon host={tenantHost} />
    ) : (
      <PostHogProvider>
        <App />
      </PostHogProvider>
    )}
  </StrictMode>
);

if (!employeeSurface && !tenantHost && 'serviceWorker' in navigator && !import.meta.env.DEV) {
  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('/sw.js')
      .catch((err) => console.warn('SW registration failed:', err));
  });
}
