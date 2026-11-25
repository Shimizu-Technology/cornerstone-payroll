/* eslint-disable react-refresh/only-export-components */
import { useEffect, type ReactNode } from 'react';
import posthog from 'posthog-js';
import { PostHogProvider as PHProvider, usePostHog } from 'posthog-js/react';
import { useLocation } from 'react-router';
import {
  capturePageView,
  currentSurface,
  initAnalytics,
  isPostHogEnabled,
  type AnalyticsSurface,
} from '@/lib/analytics';

initAnalytics();

interface PostHogPageViewProps {
  surface?: AnalyticsSurface;
}

export function PostHogPageView({ surface = currentSurface() }: PostHogPageViewProps) {
  const location = useLocation();
  const ph = usePostHog();

  useEffect(() => {
    if (ph && isPostHogEnabled) {
      capturePageView(ph, location.pathname, surface);
    }
  }, [location.pathname, ph, surface]);

  return null;
}

interface PostHogProviderProps {
  children: ReactNode;
  surface?: AnalyticsSurface;
}

export function PostHogProvider({ children, surface = currentSurface() }: PostHogProviderProps) {
  if (!isPostHogEnabled) {
    if (import.meta.env.DEV) {
      console.info('PostHog not configured — analytics disabled');
    }
    return <>{children}</>;
  }

  initAnalytics({ surface });

  return <PHProvider client={posthog}>{children}</PHProvider>;
}

export { usePostHog, isPostHogEnabled };
