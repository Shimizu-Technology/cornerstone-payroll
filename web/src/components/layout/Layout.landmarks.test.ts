import { expect, it } from 'vitest';

// Layout renders the page's one <main>. A page inside it that adds its own
// nests a second main landmark, which screen readers announce twice.
const pages = import.meta.glob<string>(['/src/pages/**/*.tsx', '!/src/pages/**/*.test.tsx'], {
  query: '?raw', import: 'default', eager: true,
});

// Pages that render outside Layout, so they supply their own main.
const STANDALONE = new Set([
  '/src/pages/PublicHome.tsx',
  '/src/pages/legal/LegalLayout.tsx',
  '/src/pages/tenant/TenantComingSoon.tsx',
]);

function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}

it('leaves the main landmark to the app layout on every page it wraps', () => {
  const nested = Object.entries(pages)
    .filter(([path, source]) => !STANDALONE.has(path) && /<main[\s>]|role=["']main["']/.test(withoutComments(source)))
    .map(([path]) => path);

  expect(Object.keys(pages).length).toBeGreaterThan(50);
  expect(nested).toEqual([]);
});
