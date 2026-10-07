# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Audited issuer names on prepared checks", type: :request do
  let(:company) { create(:company, name: "Original Issuer", check_stock_type: "top_check", next_check_number: 6001) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "org_admin") }
  let(:employee) { create(:employee, company: company, address_line1: "Original employee address") }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, :with_check, company: company, employee: employee, pay_period: period, check_number: "6000") }
  let(:run) do
    settings = CheckRenderSettings.resolve(company: company, actor: actor)
    CheckPrintRun.create!(company: company, pay_period: period, created_by: actor, status: "prepared",
      check_stock_type: company.check_stock_type, generated_at: Time.current - 1.second,
      starting_slot: 1, selected_count: 1, storage_key: SecureRandom.uuid, filename: "original-issuer.pdf",
      sha256: "a" * 64, byte_size: 100, calibration_snapshot: settings.snapshot,
      manifest: [ {
        "key" => "payroll_item:#{item.id}", "source_type" => "payroll_item", "source_id" => item.id,
        "check_number" => item.check_number, "amount" => format("%.2f", item.net_pay),
        "source_updated_at" => item.updated_at.iso8601(6), "print_count" => 0, "printed_at" => nil,
        "render_input_digest" => CheckPrintRenderFingerprint.for_record(item, company: company, check_stock_type: company.check_stock_type)
      } ])
  end

  before do
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_company_id).and_return(company.id)
    run
    item.mark_package_prepared!(user: actor)
  end

  def rename(name = "Current Issuer", **fields)
    patch "/api/v1/admin/companies/#{company.id}", params: { company: fields.merge(name: name) }
    expect(response).to have_http_status(:ok)
    company.reload
    run.reload
    item.reload
  end

  def expect_current
    expect(CheckPackagePreparation.current_for?(item)).to be(true)
    expect { CheckPrintRunSelectionVerifier.new(run: run).call }.not_to raise_error
  end

  it "preserves the full immutable package after a genuine name-only update" do
    original_package = run.attributes.deep_dup
    original_digest = run.manifest.first.fetch("render_input_digest")
    rename
    expect_current
    expect(run.reload.attributes).to eq(original_package)
    expect(CheckPrintRenderFingerprint.for_record(item, company: company, check_stock_type: company.check_stock_type)).not_to eq(original_digest)
    audit = AuditLog.find_by!(action: "company#name_changed", company_id: company.id)
    expect(audit).to have_attributes(user_id: actor.id, organization_id: company.organization_id)
    expect(audit.metadata).to include("actual_changes" => true, "name_only" => true, "changed_fields" => [ "name" ])
    expect(audit.metadata.fetch("before_values")).to include("name" => "Original Issuer")
    expect(audit.metadata.fetch("after_values")).to include("name" => "Current Issuer")
  end

  it "continues to accept the original package after unrelated check-sequence advancement" do
    rename
    expect(company.next_check_number!).to eq("6001")
    company.reload
    run.reload
    expect_current
  end

  it "follows several trusted renames, including sequence changes between them" do
    rename("Intermediate Issuer")
    company.next_check_number!
    rename("Current Issuer")
    expect_current
  end

  it "does not authorize fallback after a mixed name/configuration edit" do
    rename("Current Issuer", email: "changed@example.com")
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
    expect { CheckPrintRunSelectionVerifier.new(run: run).call }.to raise_error(CheckPrintRunSelectionVerifier::StaleSelectionError)
    expect(AuditLog.where(action: "company#name_changed", company_id: company.id)).to be_empty
  end

  it "does not cross a mixed rename in the middle of the name chain" do
    rename("Intermediate Issuer", email: "changed@example.com")
    rename("Current Issuer")
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
  end

  it "does not permit an unaudited name change" do
    company.update!(name: "Unrecorded Issuer")
    run.reload
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
  end

  it "does not cross an unaudited name change between genuine renames" do
    rename("Intermediate Issuer")
    company.update!(name: "Unrecorded Issuer")
    rename("Current Issuer")
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
  end

  it "still rejects changed employee rendering details" do
    rename
    employee.update!(address_line1: "Changed employee address")
    item.reload
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
    expect { CheckPrintRunSelectionVerifier.new(run: run).call }.to raise_error(CheckPrintRunSelectionVerifier::StaleSelectionError, /rendered/)
  end

  it "still rejects changed payment amounts" do
    rename
    item.update!(net_pay: 1000)
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
    expect { CheckPrintRunSelectionVerifier.new(run: run).call }.to raise_error(CheckPrintRunSelectionVerifier::StaleSelectionError)
  end

  it "retains the existing calibration verification guard" do
    rename
    company.update!(check_offset_x: 0.25)
    run.reload
    expect { CheckPrintRunSelectionVerifier.new(run: run).call }.to raise_error(CheckPrintRunSelectionVerifier::StaleSelectionError, /calibration/)
  end

  it "does not allow an audit belonging to another company to authorize a name" do
    other = create(:company)
    company.update!(name: "Current Issuer")
    AuditLog.record!(user: actor, company_id: other.id, organization_id: other.organization_id,
      record_type: "Company", record_id: company.id, action: "company#name_changed",
      metadata: { actual_changes: true, name_only: true, changed_fields: [ "name" ],
        before_values: { name: "Original Issuer" }, after_values: { name: "Current Issuer" } })
    run.reload
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
  end

  it "ignores name audits older than package generation" do
    AuditLog.create!(user: actor, company_id: company.id, organization_id: company.organization_id,
      record_type: "Company", record_id: company.id, event_category: "activity", created_at: run.generated_at - 1.minute,
      action: "company#name_changed", metadata: { actual_changes: true, name_only: true, changed_fields: [ "name" ],
        before_values: { name: "Original Issuer" }, after_values: { name: "Current Issuer" } })
    company.update!(name: "Current Issuer")
    run.reload
    expect(CheckPackagePreparation.current_for?(item)).to be(false)
  end

  it "rolls the rename back if its required domain audit cannot save" do
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
    patch "/api/v1/admin/companies/#{company.id}", params: { company: { name: "Current Issuer" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(company.reload.name).to eq("Original Issuer")
    expect(run.reload.company.name).to eq("Original Issuer")
  end
end
