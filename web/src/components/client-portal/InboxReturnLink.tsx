import { Link, useSearchParams } from 'react-router';

export function InboxReturnLink() {
  const [params] = useSearchParams();
  const target = params.get('inbox');
  if (!target || !/^\/app\/client-inbox(?:\?|$)/.test(target)) return null;
  return <Link to={target} className="mb-4 inline-flex min-h-11 items-center rounded px-2 text-sm font-semibold text-primary-800 underline">Back to Client Inbox</Link>;
}
