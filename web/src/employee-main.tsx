import { StagingContext } from './components/StagingContext';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PostHogProvider } from './providers/PostHogProvider';
import { supportToken } from './support/grant';
import App from './App';

// No service worker here: nothing about an employee's pay is cached on the
// device (M4-8). Analytics uses the shared privacy-scrubbed PostHog module,
// gated by VITE_PUBLIC_POSTHOG_ENABLED, and stays off in staging and support sessions.
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <StagingContext />
    {supportToken ? <App /> : (
      <PostHogProvider surface="employee">
        <App />
      </PostHogProvider>
    )}
  </StrictMode>
);
