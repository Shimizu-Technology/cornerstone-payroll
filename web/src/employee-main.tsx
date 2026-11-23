import { StagingContext } from './components/StagingContext';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PostHogProvider } from './providers/PostHogProvider';
import App from './App';
import './index.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <StagingContext />
    <PostHogProvider>
      <App />
    </PostHogProvider>
  </StrictMode>
);
