#!/bin/bash
# Gate script for Cornerstone Payroll Frontend
# Runs all quality checks before commit/deploy

set -e

echo "🔍 Running gate checks..."
echo ""

# Change to project root
cd "$(dirname "$0")/.."

# 1. TypeScript check
echo "📘 TypeScript type checking..."
npx tsc --noEmit
echo "✅ TypeScript: OK"
echo ""

# 2. ESLint
echo "🔎 ESLint..."
npx eslint src --ext .ts,.tsx --max-warnings 0
echo "✅ ESLint: OK"
echo ""

# 3. Build
echo "🏗️  Building..."
npm run build
echo "✅ Build: OK"
echo ""

echo "🎉 All gate checks passed!"
