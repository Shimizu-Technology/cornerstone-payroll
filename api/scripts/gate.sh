#!/bin/bash
# Gate script - runs all checks before committing
# All checks must pass for the gate to open

set -e

# Use rbenv shims if available
if [ -d "$HOME/.rbenv/shims" ]; then
    export PATH="$HOME/.rbenv/shims:$PATH"
fi

echo "========================================="
echo "Running Gate Checks"
echo "========================================="

cd "$(dirname "$0")/.."

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

FAILED=0

# 1. RSpec tests
echo ""
echo "📋 Running RSpec tests..."
if bundle exec rspec --format progress; then
    echo -e "${GREEN}✅ RSpec passed${NC}"
else
    echo -e "${RED}❌ RSpec failed${NC}"
    FAILED=1
fi

# 2. Rubocop
echo ""
echo "🔍 Running Rubocop..."
if bundle exec rubocop --format simple; then
    echo -e "${GREEN}✅ Rubocop passed${NC}"
else
    echo -e "${RED}❌ Rubocop failed${NC}"
    FAILED=1
fi

# 3. Brakeman security scan
echo ""
echo "🔐 Running Brakeman security scan..."
if bundle exec brakeman --no-pager -q --no-summary; then
    echo -e "${GREEN}✅ Brakeman passed${NC}"
else
    echo -e "${RED}❌ Brakeman found security issues${NC}"
    FAILED=1
fi

# Summary
echo ""
echo "========================================="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All gate checks passed!${NC}"
    exit 0
else
    echo -e "${RED}💥 Gate checks failed!${NC}"
    exit 1
fi
