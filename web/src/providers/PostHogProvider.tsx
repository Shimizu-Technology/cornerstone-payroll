/* eslint-disable react-refresh/only-export-components */
import { useEffect } from 'react';
import posthog from 'posthog-js';
import { PostHogProvider as PHProvider, usePostHog } from 'posthog-js/react';
import { useLocation } from 'react-router';

const POSTHOG_KEY = import.meta.env.VITE_PUBLIC_POSTHOG_KEY;
const POSTHOG_HOST =
  import.meta.env.VITE_PUBLIC_POSTHOG_HOST || 'https://us.i.posthog.com';
const isPostHogExplicitlyEnabled = import.meta.env.VITE_PUBLIC_POSTHOG_ENABLED === 'true';
const isPostHogEnabled = Boolean(isPostHogExplicitlyEnabled && POSTHOG_KEY && POSTHOG_KEY !== 'YOUR_POSTHOG_KEY');

if (isPostHogEnabled && typeof window !== 'undefined') {
  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    capture_pageview: false,
    capture_pageleave: false,
    autocapture: false,
    disable_session_recording: true,
    disable_surveys: true,
    advanced_disable_decide: true,
    loaded: (ph) => {
      if (import.meta.env.DEV) {
        ph.opt_out_capturing();
      }
    },
  });
}

export function PostHogPageView() {
  const location = useLocation();
  const ph = usePostHog();

  useEffect(() => {
    if (ph && isPostHogEnabled) {
      ph.capture('$pageview', {
        $current_url: window.location.href,
        $pathname: location.pathname,
      });
    }
  }, [location, ph]);

  return null;
}

interface PostHogProviderProps {
  children: React.ReactNode;
}

export function PostHogProvider({ children }: PostHogProviderProps) {
  if (!isPostHogEnabled) {
    if (import.meta.env.DEV) {
      console.info('PostHog not configured — analytics disabled');
    }
    return <>{children}</>;
  }

  return <PHProvider client={posthog}>{children}</PHProvider>;
}

export { usePostHog, isPostHogEnabled };
