# frozen_string_literal: true

# Records an Employee App Terms of Use and Privacy Notice version on the
# server, so the employee app switch can check counsel's status (M4-9d).
# Rows are immutable: counsel's approval is a new row with STATUS=approved.
#
#   VERSION=2026-12-01 STATUS=draft TERMS_URL=https://... PRIVACY_URL=https://... \
#     bin/rails employee_terms:publish
namespace :employee_terms do
  desc "Record an Employee App Terms version (VERSION, STATUS=draft|approved, TERMS_URL, PRIVACY_URL)"
  task publish: :environment do
    version = EmployeeTermsVersion.create!(
      version: ENV.fetch("VERSION").strip,
      status: ENV.fetch("STATUS").strip,
      terms_url: ENV.fetch("TERMS_URL").strip,
      privacy_url: ENV.fetch("PRIVACY_URL").strip,
      published_at: Time.current
    )
    puts "Recorded Employee App Terms #{version.version} (#{version.status})."
  rescue KeyError => error
    abort "Missing #{error.key}. Set VERSION, STATUS, TERMS_URL and PRIVACY_URL."
  end
end
