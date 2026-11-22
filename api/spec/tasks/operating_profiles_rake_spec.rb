# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "operating_profiles:parity" do
  let(:task) { Rake::Task["operating_profiles:parity"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("operating_profiles:parity")
    task.reenable
  end

  def track_sql_writes
    writes = []
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA"
      next unless sql.match?(/\A\s*(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP)\b/i)

      writes << sql
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end
    writes
  end

  it "succeeds with zero database writes when all live companies match legacy configuration and skips test workspaces" do
    organization = create(:organization)
    mosa = create(
      :company,
      organization: organization,
      name: "MoSa's Parity Co",
      payroll_intake_source_types: [ "mosa_revel" ],
      client_payroll_approval_required: true
    )
    create(
      :company,
      organization: organization,
      name: "MoSa's Pending Sandbox",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox",
      migration_source_company: mosa,
      migration_rehearsal_status: "pending"
    )
    ClientOperatingProfiles::BackfillService.call

    writes = track_sql_writes do
      expect { task.invoke }.to output(
        a_string_including("OK    operating_profiles:parity", "differences=0", "skipped_test_workspaces=1")
      ).to_stdout
    end

    expect(writes).to be_empty
  end

  it "prints company id, company name, and field names without personal data and exits nonzero on differences" do
    organization = create(:organization)
    company = create(
      :company,
      organization: organization,
      name: "Spike Parity Co",
      filing_contact_name: "Private Contact Name",
      phone: "671-555-9999",
      email: "private-contact@example.com"
    )
    missing_profile_company = create(
      :company,
      organization: organization,
      name: "Unbackfilled Co"
    )
    ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: company.id))

    profile = company.client_operating_profiles.first!
    profile.update!(
      offering: "payroll_portals",
      options: profile.options.deep_merge(
        "year_end" => {
          "contact" => {
            "email" => "different-personal@example.com"
          }
        }
      )
    )

    writes = track_sql_writes do
      expect {
        expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      }.to output(
        a_string_including(
          "DIFF  company_id=#{company.id} name=\"Spike Parity Co\" field=offering",
          "DIFF  company_id=#{company.id} name=\"Spike Parity Co\" field=year_end.contact.email",
          "DIFF  company_id=#{missing_profile_company.id} name=\"Unbackfilled Co\" field=profile"
        ).and(satisfy { |text| !text.include?("private-contact@example.com") && !text.include?("different-personal@example.com") && !text.include?("Private Contact Name") })
      ).to_stdout
        .and output(a_string_including("FAIL  operating_profiles:parity")).to_stderr
    end

    expect(writes).to be_empty
    expect(ClientOperatingProfile.where(company_id: missing_profile_company.id)).to be_empty
  end
end
