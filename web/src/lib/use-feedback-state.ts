import { useCallback, useState, type Dispatch, type SetStateAction } from 'react';

/** Retain error state while letting a repeated failed attempt show a dismissed toast again. */
export function useFeedbackState<T>(initial: T | (() => T)): [T, Dispatch<SetStateAction<T>>, number] {
  const [value, setValue] = useState<T>(initial);
  const [attempt, setAttempt] = useState(0);
  const setFeedback = useCallback<Dispatch<SetStateAction<T>>>((next) => {
    setValue(next);
    setAttempt((previous) => previous + 1);
  }, []);
  return [value, setFeedback, attempt];
}
