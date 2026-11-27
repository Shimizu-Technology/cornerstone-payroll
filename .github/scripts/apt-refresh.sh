#!/usr/bin/env bash
# Refresh apt package indexes on a GitHub-hosted Ubuntu runner.
#
# Some runners intermittently fail to resolve Ubuntu's archive hosts. apt-get update only warns when
# that happens, and the next install then fails with "Unable to locate package". This retries until
# every index downloads and switches to public DNS resolvers if the runner's resolver keeps failing.
set -uo pipefail

echo 'Acquire::Retries "5";' | sudo tee /etc/apt/apt.conf.d/80-retries >/dev/null

# The runner image ships Microsoft's package repository, which CI never installs from. When that
# repository returns 403, every refresh fails (here and inside `playwright install --with-deps`), so
# turn it off for this job.
disable_microsoft_repo() {
  local file
  for file in /etc/apt/sources.list.d/*; do
    [ -f "$file" ] || continue
    if grep -q 'packages\.microsoft\.com' "$file"; then
      sudo mv "$file" "$file.disabled"
      echo "Disabled $(basename "$file") for this job."
    fi
  done
}
disable_microsoft_repo

use_public_dns() {
  echo "::warning::Package index refresh keeps failing; switching this runner to public DNS resolvers."
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=9.9.9.9\nDomains=~.\n' |
    sudo tee /etc/systemd/resolved.conf.d/90-ci-public-dns.conf >/dev/null
  sudo systemctl restart systemd-resolved
}

for attempt in 1 2 3 4 5 6; do
  if sudo apt-get update --error-on=any; then
    exit 0
  fi
  [ "$attempt" -eq 2 ] && use_public_dns
  sleep $((attempt * 10))
done

echo "::error::Package indexes could not be refreshed after 6 attempts."
exit 1
