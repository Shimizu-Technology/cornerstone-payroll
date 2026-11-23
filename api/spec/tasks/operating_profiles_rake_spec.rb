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

  context "with edited profile versions" do
    let(:company) { create(:company) }
    let(:actor) { create(:user, company: company, role: "org_admin") }
    let(:key) { "tips.default" }
    let(:original) { "paid_in_check" }
    let(:updated) { "already_paid_out" }
    let(:start) { PayrollBusinessClock.today - 30 }
    let!(:baseline) do
      ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: start)
      )
    end

    def append(previous, value)
      date = previous.effective_on + 10
      previous.update!(ends_on: date - 1)
      values = OperatingProfileCatalog.values_for(previous).merge(key => value)
      company.client_operating_profiles.create!(
        **OperatingProfileCatalog.attributes_from(values), version: previous.version + 1, effective_on: date
      )
    end

    def record_audit(profile, before:, after:, user: actor, metadata: {})
      AuditLog.record!(
        user: user, company_id: company.id, action: ClientOperatingProfiles::UpdateService::AUDIT_ACTION,
        record_type: "ClientOperatingProfile", record_id: profile.id,
        metadata: {
          version: profile.version, effective_on: profile.effective_on.iso8601, changed_fields: [ key ],
          before_values: { key => before }, after_values: { key => after }
        }.merge(metadata)
      )
    end

    it "replays staff audits in profile version order even when audit IDs are reversed" do
      v2 = append(baseline, updated)
      v3 = append(v2, original)
      record_audit(v3, before: updated, after: original)
      record_audit(v2, before: original, after: updated)

      expect { task.invoke }.to output(a_string_including("OK    operating_profiles:parity", "differences=0")).to_stdout
      expect(ClientOperatingProfiles::ParityChecker.call(on: v2.effective_on)).to be_passed
    end

    it "rejects an unaudited v3 even when its values equal v2, and ignores a client audit" do
      v2 = append(baseline, updated)
      record_audit(v2, before: original, after: updated)
      v3 = append(v2, updated)
      client = create(:user, company: company, role: "client")
      record_audit(v3, before: original, after: updated, user: client)

      expect {
        expect { task.invoke }.to raise_error(SystemExit)
      }.to output(a_string_including("field=profile.audit.v3")).to_stdout
        .and output(a_string_including("FAIL  operating_profiles:parity")).to_stderr
    end

    it "reports malformed audit metadata and broken continuity while continuing to check other companies" do
      v2 = append(baseline, updated)
      record_audit(v2, before: original, after: updated, metadata: { after_values: nil })
      record_audit(v2, before: updated, after: original)

      unchecked_company = create(:company)
      expect {
        expect { task.invoke }.to raise_error(SystemExit)
      }.to output(a_string_including("field=profile.audit.v2", "company_id=#{unchecked_company.id}")).to_stdout
        .and output(a_string_including("FAIL  operating_profiles:parity")).to_stderr
    end
  end
end
