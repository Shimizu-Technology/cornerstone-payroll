# frozen_string_literal: true

# First-run data for the local production copy, run once by up.sh through
# `rails runner` on the owner connection (guard off). Fictional names only.
#
# - an organization with its own office company and one super admin bound to
#   the Clerk development user up.sh created (payroll.admin+clerk_test@...);
# - the Harbor Finch demo employers, through the repo's own demo seed;
# - the draft Employee App Terms, recorded the way employee_terms:publish does.
#
# The employee app switch, subdomains and invitations stay off: staff turn
# them on through the app, as in production.

abort "bootstrap.rb runs only in a local production copy" unless LocalDeployment.local? && Rails.env.production?

clerk_id = ENV.fetch("LP_CLERK_STAFF_USER_ID")
legal_dir = ENV.fetch("LP_LEGAL_DIR")
origin_suffix = ENV.fetch("LP_TENANT_ORIGIN_SUFFIX")

organization, actor = TenantScope.as_system(reason: "Bootstrap the local production copy") do
  organization = Organization.find_or_create_by!(slug: "cornerstone-local") do |org|
    org.name = "Cornerstone Payroll Local"
    org.status = "active"
  end
  office = organization.companies.find_or_create_by!(name: "Cornerstone Payroll Local Office") do |company|
    company.address_line1 = "1 Finchwater Lane"
    company.city = "Hagåtña"
    company.state = "GU"
    company.zip = "96910"
    company.phone = "(671) 555-0100"
    company.email = "office@cornerstone.localhost"
    company.pay_frequency = "biweekly"
    company.ein = "00-0000101"
  end
  organization.update!(primary_company: office) unless organization.primary_company_id

  actor = User.find_or_initialize_by(email: "payroll.admin+clerk_test@example.com")
  actor.assign_attributes(organization: organization, company: office, name: "Payroll Admin", role: "super_admin",
    active: true, clerk_id: clerk_id)
  actor.save!
  [ organization, actor ]
end

result = Current.set(user: actor) { DemoCompany::Seed.new(organization: organization, actor: actor).call }
puts "demo companies=#{result.companies.map(&:id).join(',')} employees_created=#{result.employees_created} " \
     "periods_committed=#{result.periods_committed}"

# The seed builds the old test-workspace demo shape, which never posts payroll
# liabilities. Convert to Track B's shape (live + demo flag) the way
# docs/rollout/TRACK_B_DEMO_SHAPE_MIGRATION_RUNBOOK.md does, then post the
# liabilities the seeded periods skipped, so checks, the liability center and
# year-end match production after Track B.
demo_ids = result.companies.map(&:id)
converted = Current.set(user: actor) do
  DemoCompany::ConvertToFlag.new(organization: organization, actor: actor, company_ids: demo_ids.join(","), dry_run: false).call
end
puts "demo shape converted=#{converted.converted_company_ids.join(',')} already=#{converted.already_converted_company_ids.join(',')}"
TenantScope.as_system(reason: "Post liabilities for the seeded demo payroll") do
  Company.where(id: demo_ids).find_each do |company|
    posted = PayrollLiabilityBackfillService.new(company: company, actor: actor).call(confirm: true)
    abort "liability backfill failed for company #{company.id}: #{posted[:errors].inspect}" if posted[:errors].any?
    puts "liabilities company=#{company.id} posted=#{posted[:posted_count]}"
  end
end

TenantScope.as_system(reason: "Record the draft Employee App Terms") do
  terms = Dir[File.join(legal_dir, "employee-terms-*-draft.html")].max
  privacy = Dir[File.join(legal_dir, "employee-privacy-*-draft.html")].max
  abort "No employee-terms-*-draft.html and employee-privacy-*-draft.html in #{legal_dir}; update bootstrap.rb to the new names" unless terms && privacy
  version = File.basename(terms)[/\d{4}-\d{2}-\d{2}/]
  unless EmployeeTermsVersion.exists?(version: version)
    EmployeeTermsVersion.create!(version: version, status: "draft",
      terms_url: "https://harborfinch#{origin_suffix}/legal/#{File.basename(terms)}",
      privacy_url: "https://harborfinch#{origin_suffix}/legal/#{File.basename(privacy)}",
      text_digest: Digest::SHA256.file(terms).hexdigest, published_at: Time.current)
  end
  puts "terms=#{version} staff_user=#{actor.id} organization=#{organization.id}"
end
