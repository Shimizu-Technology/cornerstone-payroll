#!/usr/bin/env bash
# Source from the certification drill; only changes the caller's subshell environment.
certification_use_ruby() {
  local application_dir="$1" explicit_bin_dir="$2" expected_version runtime_root actual_version
  expected_version="$(<"${application_dir}/.ruby-version")"
  if [[ -n "${explicit_bin_dir}" ]]; then
    [[ -x "${explicit_bin_dir}/ruby" && -x "${explicit_bin_dir}/bundle" ]] || {
      echo "The supplied certification Ruby directory must contain ruby and bundle." >&2
      return 1
    }
    export PATH="${explicit_bin_dir}:$PATH"
    unset RBENV_VERSION
  else
    runtime_root="$(rbenv root 2>/dev/null)" || {
      echo "Use rbenv or supply AIRE_RUBY_BIN_DIR and PAYROLL_RUBY_BIN_DIR." >&2
      return 1
    }
    export PATH="${runtime_root}/shims:$PATH"
    export RBENV_VERSION="${expected_version}"
  fi
  actual_version="$(ruby -e 'print RUBY_VERSION')" || return 1
  [[ "${actual_version}" == "${expected_version}" ]] || {
    echo "Certification requires Ruby ${expected_version}; selected ${actual_version}." >&2
    return 1
  }
  export BUNDLE_GEMFILE="${application_dir}/Gemfile"
}
