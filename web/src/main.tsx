import { StagingContext } from './components/StagingContext'
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PostHogProvider } from './providers/PostHogProvider';
import App from './App.tsx';
import { clientSubdomainHost } from './lib/tenant-subdomain';
import { TenantComingSoon } from './pages/tenant/TenantComingSoon';
import './index.css';

const tenantHost = clientSubdomainHost(window.location, import.meta.env.DEV);

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {tenantHost ? (
      <TenantComingSoon host={tenantHost} />
    ) : (
      <>
        <StagingContext />
        <PostHogProvider>
          <App />
        </PostHogProvider>
      </>
    )}
  </StrictMode>
);

if (!tenantHost && 'serviceWorker' in navigator && !import.meta.env.DEV) {
  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('/sw.js')
      .catch((err) => console.warn('SW registration failed:', err));
  });
}
