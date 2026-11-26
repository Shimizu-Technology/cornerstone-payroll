# frozen_string_literal: true

# The employee app switch's readiness checks for each demo company, computed
# in the staff web process's own environment (smoke.sh runs this with
# staff.env): the real ping to the employee API over HTTPS, its signed
# attestation, and the database's RLS state. Prints one READINESS line per company.

companies = TenantScope.as_system(reason: "List demo companies for the local smoke check") { Company.active.demo.order(:id).to_a }
abort "no demo companies" if companies.empty?

failed = false
companies.each do |company|
  readiness = TenantScope.with_company(company.id) { EmployeeAppSwitch::Readiness.new(company: company) }
  checks = TenantScope.with_company(company.id) { readiness.platform_checks + readiness.counsel_checks.values }
  # Only the MFA check may be waived (REQUIRE_MFA off); anything else must pass.
  failed ||= checks.any? { |check| check.status != "passed" && !(check.key == "mfa" && check.status == "waived") }
  puts "READINESS " + JSON.generate(company: company.subdomain_slug, checks: checks.map { |check| check.as_json.slice(:key, :status, :detail) })
end
exit(failed ? 1 : 0)
