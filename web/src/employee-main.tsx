import { StagingContext } from './components/StagingContext';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';

// No PostHog and no service worker here: nothing about an employee's pay is
// sent to analytics or cached on the device (M4-8).
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <StagingContext />
    <App />
  </StrictMode>
);
