/** @vitest-environment node */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { resolveRouteTemplate, UNKNOWN_ROUTE_TEMPLATE } from './analytics-routes';

const srcDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function sampleConcretePath(pattern: string): string[] {
  const normalized = pattern.startsWith('/') ? pattern : `/${pattern}`;
  const segments = normalized.split('/').filter(Boolean);
  const paths: string[][] = [[]];

  for (const segment of segments) {
    if (segment.startsWith(':') && segment.endsWith('?')) {
      const paramName = segment.slice(1, -1);
      const withoutOptional = paths.map((p) => [...p]);
      const withOptional = paths.map((p) => [...p, `sample-${paramName}`]);
      paths.length = 0;
      paths.push(...withoutOptional, ...withOptional);
    } else if (segment.startsWith(':')) {
      const paramName = segment.slice(1);
      for (const p of paths) p.push(`sample-${paramName}`);
    } else {
      for (const p of paths) p.push(segment);
    }
  }

  return paths.map((p) => (p.length > 0 ? `/${p.join('/')}` : '/'));
}

function extractStaffAppRoutePatterns(source: string): string[] {
  const routesBlockMatch = /<Routes>([\s\S]*?)<\/Routes>/.exec(source);
  if (!routesBlockMatch) {
    throw new Error('Could not locate <Routes> block in App.tsx');
  }
  const block = routesBlockMatch[1];
  const patterns: string[] = [];
  const stack: string[] = [];

  let i = 0;
  while (i < block.length) {
    if (block.startsWith('</Route>', i)) {
      stack.pop();
      i += '</Route>'.length;
      continue;
    }

    if (block.startsWith('<Route', i) && /[\s/>]/.test(block[i + 6] ?? '')) {
      let j = i + 6;
      let braceDepth = 0;
      let quote: '"' | "'" | null = null;
      while (j < block.length) {
        const ch = block[j];
        if (quote) {
          if (ch === '\\') {
            j += 2;
            continue;
          }
          if (ch === quote) quote = null;
        } else if (ch === '"' || ch === "'") {
          quote = ch;
        } else if (ch === '{') {
          braceDepth += 1;
        } else if (ch === '}') {
          braceDepth = Math.max(0, braceDepth - 1);
        } else if (ch === '>' && braceDepth === 0) {
          break;
        }
        j += 1;
      }

      const tagContent = block.slice(i + 6, j);
      const isSelfClosing = tagContent.trimEnd().endsWith('/');
      const pathMatch = /\bpath="([^"]+)"/.exec(tagContent);
      const rawPath = pathMatch?.[1];

      if (rawPath === '*') {
        if (!isSelfClosing) stack.push('');
      } else {
        const prefix = stack.filter(Boolean).join('/');
        const segment = rawPath ? rawPath.replace(/^\/+|\/+$/g, '') : '';
        const joined = rawPath
          ? rawPath.startsWith('/')
            ? `/${segment}`
            : prefix
              ? `/${prefix}/${segment}`
              : `/${segment}`
          : prefix
            ? `/${prefix}`
            : '';

        if (isSelfClosing) {
          if (rawPath) {
            patterns.push(joined || '/');
          }
        } else {
          stack.push(segment);
        }
      }

      i = j + 1;
      continue;
    }

    i += 1;
  }

  return patterns;
}

function extractEmployeeAppRoutePatterns(source: string): string[] {
  const patterns = new Set<string>(['/']);

  const routesBlockMatch = /<Routes>([\s\S]*?)<\/Routes>/.exec(source);
  if (!routesBlockMatch) {
    throw new Error('Could not locate <Routes> block in EmployeeApp.tsx');
  }
  for (const match of routesBlockMatch[1].matchAll(/<Route\b[^>]*\bpath="([^"]+)"/g)) {
    const rawPath = match[1];
    if (rawPath !== '*') {
      patterns.add(rawPath.startsWith('/') ? rawPath : `/${rawPath}`);
    }
  }

  for (const match of source.matchAll(/\bpath\s*===\s*'(\/[^']*)'/g)) {
    patterns.add(match[1]);
  }

  const signUpSetMatch = /const SIGN_UP_PATHS = new Set\(\[([^\]]+)\]\)/.exec(source);
  if (signUpSetMatch) {
    for (const match of signUpSetMatch[1].matchAll(/'(\/[^']*)'/g)) {
      patterns.add(match[1]);
    }
  }

  return [...patterns];
}

describe('analytics route-inventory parity', () => {
  it('covers every non-catch-all route declared in App.tsx', () => {
    const appSource = readFileSync(path.join(srcDir, 'App.tsx'), 'utf8');
    const patterns = extractStaffAppRoutePatterns(appSource);
    expect(patterns.length).toBeGreaterThan(40);

    for (const pattern of patterns) {
      for (const samplePath of sampleConcretePath(pattern)) {
        const resolved = resolveRouteTemplate(samplePath, 'staff');
        expect(
          resolved,
          `Staff route "${pattern}" (sample "${samplePath}") resolved to /unknown — add it to STAFF_ROUTE_OBJECTS`,
        ).not.toBe(UNKNOWN_ROUTE_TEMPLATE);
      }
    }
  });

  it('covers every non-catch-all route declared in EmployeeApp.tsx', () => {
    const employeeSource = readFileSync(path.join(srcDir, 'EmployeeApp.tsx'), 'utf8');
    const patterns = extractEmployeeAppRoutePatterns(employeeSource);
    expect(patterns.length).toBeGreaterThan(10);

    for (const pattern of patterns) {
      for (const samplePath of sampleConcretePath(pattern)) {
        const resolved = resolveRouteTemplate(samplePath, 'employee');
        expect(
          resolved,
          `Employee route "${pattern}" (sample "${samplePath}") resolved to /unknown — add it to EMPLOYEE_ROUTE_OBJECTS`,
        ).not.toBe(UNKNOWN_ROUTE_TEMPLATE);
      }
    }
  });
});
