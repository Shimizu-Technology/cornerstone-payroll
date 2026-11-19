import { useCallback, useEffect, useRef } from 'react';

/**
 * Returns a check that is false once the step has unmounted, for example
 * after the user opens another client. A save in flight stops there instead
 * of sending follow-up requests or reporting success on the wrong page.
 */
export function useStillMounted(): () => boolean {
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);
  return useCallback(() => mounted.current, []);
}
