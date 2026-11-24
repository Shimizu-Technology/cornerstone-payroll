#!/usr/bin/env bash
set -euo pipefail

web_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q
git -C "$fixture" config user.name "Netlify ignore test"
git -C "$fixture" config user.email "netlify-ignore@example.invalid"
mkdir -p "$fixture"/{web/scripts,docs,api}
cp "$web_dir"/netlify.toml "$fixture"/web/
cp "$web_dir"/scripts/netlify-ignore-build.sh "$fixture"/web/scripts/
git -C "$fixture" add .
git -C "$fixture" commit -qm baseline
baseline="$(git -C "$fixture" rev-parse HEAD)"
ignore_command="$(sed -n 's/^  ignore = "\(.*\)"$/\1/p' "$fixture/web/netlify.toml")"
test -n "$ignore_command"

expect_status() {
  local expected="$1" context="$2" cached="$3" commit="$4" actual=0
  (
    cd "$fixture/web"
    CONTEXT="$context" CACHED_COMMIT_REF="$cached" COMMIT_REF="$commit" bash -c "$ignore_command"
  ) || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected exit $expected, got $actual ($context, $cached..$commit)" >&2
    exit 1
  fi
}

for case_spec in '0 docs/runbook.md' '0 api/example.rb' '1 web/example.ts' '1 package-lock.json' '1 .gitignore' '1 web/.gitignore'; do
  read -r expected file <<< "$case_spec"
  echo "$file"
  touch "$fixture/$file"
  git -C "$fixture" add -f "$file"
  git -C "$fixture" commit -qm "$file"
  expect_status "$expected" production "$baseline" "$(git -C "$fixture" rev-parse HEAD)"
  git -C "$fixture" reset -q --hard "$baseline"
done
expect_status 1 production "$baseline" "$baseline"
expect_status 1 production "" "$baseline"
expect_status 1 production "0000000000000000000000000000000000000000" "$baseline"
expect_status 1 deploy-preview "$baseline" "$baseline"

# Employee site (same netlify.toml, VITE_APP_SURFACE=employee in the site's environment).
expect_employee_status() {
  local expected="$1" context="$2" cached="$3" commit="$4" actual=0
  (
    cd "$fixture/web"
    VITE_APP_SURFACE=employee CONTEXT="$context" CACHED_COMMIT_REF="$cached" COMMIT_REF="$commit" bash -c "$ignore_command"
  ) || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    echo "Employee site: expected exit $expected, got $actual ($context)" >&2
    exit 1
  fi
}

for case_spec in '0 docs/runbook.md' '0 api/example.rb' '1 web/example.ts' '1 package-lock.json'; do
  read -r expected file <<< "$case_spec"
  echo "employee: $file"
  mkdir -p "$(dirname "$fixture/$file")"
  touch "$fixture/$file"
  git -C "$fixture" add -f "$file"
  git -C "$fixture" commit -qm "employee $file"
  expect_employee_status "$expected" production "$baseline" "$(git -C "$fixture" rev-parse HEAD)"
  git -C "$fixture" reset -q --hard "$baseline"
done
web_change() {
  touch "$fixture/web/example.ts"
  git -C "$fixture" add -f web/example.ts
  git -C "$fixture" commit -qm "employee web change"
  git -C "$fixture" rev-parse HEAD
}
changed="$(web_change)"
expect_employee_status 0 deploy-preview "$baseline" "$changed"
expect_employee_status 0 branch-deploy "$baseline" "$changed"
expect_employee_status 0 "" "$baseline" "$changed"
expect_employee_status 1 production "$baseline" "$baseline"
expect_employee_status 1 production "" "$changed"
git -C "$fixture" reset -q --hard "$baseline"
# Payroll's site (no surface set) still builds a changed web/ in every context.
changed="$(web_change)"
expect_status 1 deploy-preview "$baseline" "$changed"
expect_status 1 branch-deploy "$baseline" "$changed"
git -C "$fixture" reset -q --hard "$baseline"
echo "ignore rules ok"
