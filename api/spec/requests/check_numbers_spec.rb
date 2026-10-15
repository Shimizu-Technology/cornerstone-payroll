# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check-number worksheet", type: :request do
  let(:company) { create(:company, next_check_number: 3002) }
  let(:admin_user) { create(:user, company: company, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:employee_a) { create(:employee, company: company, first_name: "Alice", last_name: "Reyes") }
  let(:employee_b) { create(:employee, company: company, first_name: "Ben", last_name: "Cruz") }
  let!(:item_a) { create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee_a, check_number: "3000") }
  let!(:item_b) { create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee_b, check_number: "3001") }
  let!(:non_employee_check) do
    create(:non_employee_check, company: company, pay_period: pay_period, payment_period_type: "pay_period", check_number: "3500")
  end

  before do
    allow_any_instance_of(Api::V1::Admin::CheckNumbersController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::CheckNumbersController)
      .to receive(:current_user).and_return(admin_user)
  end

  def reconcile_item!(item, status)
    item.mark_printed!(user: admin_user)
    item.mark_delivered!(
      user: admin_user,
      delivered_on: Date.current,
      delivery_method: "hand_delivery",
      attestation: true
    )
    attributes = {
      source_type: "payroll_item",
      source_id: item.id,
      event_type: status,
      effective_on: Date.current,
      idempotency_key: SecureRandom.uuid
    }
    if status == "cleared"
      attributes.merge!(evidence_type: "bank_statement", evidence_reference: "Test statement line 12")
    else
      attributes[:reason] = "Employee reported the issued check lost"
    end
    CheckReconciliationEventService.new(company: company, actor: admin_user, attributes: attributes).call
  end

  it "saves a mixed worksheet atomically and supports swapping payroll numbers" do
    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        reason: "Reviewed physical check stock",
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "3001" },
          { source_type: "payroll_item", source_id: item_b.id, check_number: "3000" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3600" }
        ]
      }
    }.to change { CheckEvent.where(event_type: "renumbered").count }.by(2)
      .and change { NonEmployeeCheckEdit.count }.by(1)
      .and change { AuditLog.where(action: [ "checks#check_number_updated", "non_employee_checks#updated" ]).count }.by(3)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["updated_count"]).to eq(3)
    expect(item_a.reload.check_number).to eq("3001")
    expect(item_b.reload.check_number).to eq("3000")
    expect(non_employee_check.reload.check_number).to eq("3600")
    expect(company.reload.next_check_number).to eq(3601)
    expect(response.parsed_body.dig("check_print_queue", "items").map { |row| row["check_number"] })
      .to include("3000", "3001", "3600")
  end

  it "rolls back every requested change when one number is already used outside the worksheet" do
    other_period = create(
      :pay_period,
      :committed,
      company: company,
      start_date: Date.new(2024, 2, 1),
      end_date: Date.new(2024, 2, 14),
      pay_date: Date.new(2024, 2, 16)
    )
    other_employee = create(:employee, company: company)
    create(:payroll_item, :with_check, company: company, pay_period: other_period, employee: other_employee, check_number: "3999")

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3999" }
        ]
      }
    }.not_to change { AuditLog.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("3999")
    expect(item_a.reload.check_number).to eq("3000")
    expect(non_employee_check.reload.check_number).to eq("3500")
  end

  it "rejects duplicate numbers inside the submitted worksheet" do
    item_a.mark_package_prepared!(user: admin_user)
    non_employee_check.mark_package_prepared!
    patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
      changes: [
        { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" },
        { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3100" }
      ]
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Check number 3100 is entered more than once")
    expect(item_a.reload.check_number).to eq("3000")
    expect(non_employee_check.reload.check_number).to eq("3500")
  end

  it "does not allow a blank payroll check number" do
    patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
      changes: [ { source_type: "payroll_item", source_id: item_a.id, check_number: "" } ]
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Check number is required")
    expect(item_a.reload.check_number).to eq("3000")
  end

  it "does not write history when the submitted worksheet has no effective changes" do
    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "3000" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3500" }
        ]
      }
    }.not_to change { AuditLog.count }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["updated_count"]).to eq(0)
    expect(CheckEvent.where(event_type: "renumbered")).to be_empty
    expect(NonEmployeeCheckEdit.all).to be_empty
  end

  it "renumbers prepared checks before they are issued" do
    item_a.mark_printed!(user: admin_user)

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        reason: "Actual physical check stock used",
        changes: [ { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" } ]
      }
    }.to change { CheckEvent.where(event_type: "renumbered").count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(item_a.reload.check_number).to eq("3100")
    expect(item_a.check_printed_at).to be_present
  end

  it "corrects saved-package check numbers without changing payroll and makes the old package stale" do
    transmittal = Transmittal.create!(pay_period: pay_period, company: company,
      payroll_check_numbers: %w[3000 3001], non_employee_check_numbers: { non_employee_check.id.to_s => "3500" })
    signoff = CheckSignoffSheet.create!(pay_period: pay_period, company: company,
      entries: [ { name: "Reyes, Alice", check_number: "3000" }, { name: "Cruz, Ben", check_number: "3001" } ])
    item_a.mark_package_prepared!(user: admin_user)
    item_b.mark_package_prepared!(user: admin_user)
    originals = [ item_a, item_b ].map { |item| item.reload.attributes.except("check_number", "updated_at") }
    manifest = [ item_a, item_b ].map do |item|
      {
        "key" => "payroll_item:#{item.id}", "source_type" => "payroll_item", "source_id" => item.id,
        "check_number" => item.check_number, "amount" => item.net_pay.to_s,
        "source_updated_at" => item.updated_at.iso8601(6), "print_count" => 0, "printed_at" => nil
      }
    end
    package = CheckPrintRun.create!(
      company: company, pay_period: pay_period, created_by: admin_user, status: "prepared",
      check_stock_type: company.check_stock_type, starting_slot: 1, selected_count: 2,
      manifest: manifest, storage_key: "check-print-runs/renumber-spec.pdf", filename: "renumber-spec.pdf",
      sha256: "a" * 64, byte_size: 100, generated_at: Time.current
    )
    expect(CheckReconciliationStatus.for(item_a)).to eq("prepared")
    expect { CheckPrintRunSelectionVerifier.new(run: package).call }.not_to raise_error

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        reason: "Correct starting number to match physical stock",
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "4100" },
          { source_type: "payroll_item", source_id: item_b.id, check_number: "4101" }
        ]
      }
    }.to change { CheckEvent.where(event_type: "renumbered").count }.by(2)
      .and change { AuditLog.where(action: "checks#check_number_updated").count }.by(2)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["updated_count"]).to eq(2)
    expect([ item_a.reload.check_number, item_b.reload.check_number ]).to eq(%w[4100 4101])
    expect([ item_a, item_b ].map { |item| item.attributes.except("check_number", "updated_at") }).to eq(originals)
    expect(company.reload.next_check_number).to eq(4102)
    expect(transmittal.reload.payroll_check_numbers).to eq(%w[4100 4101])
    expect(transmittal.check_number_first).to eq("3500")
    expect(transmittal.check_number_last).to eq("4101")
    expect(transmittal.non_employee_check_numbers).to eq(non_employee_check.id.to_s => "3500")
    expect(signoff.reload.entries.pluck("check_number")).to eq(%w[4100 4101])
    expect(CheckEvent.where(event_type: "voided")).to be_empty
    expect(item_a.check_prepared?).to be(false)
    corrected_queue = response.parsed_body.dig("check_print_queue", "items").select { |row| row["source_type"] == "payroll_item" }
    expect(corrected_queue.pluck("status")).to eq(%w[unprinted unprinted])
    expect {
      item_a.mark_delivered!(user: admin_user, delivered_on: Date.current, delivery_method: "hand_delivery", attestation: true)
    }.to raise_error(ArgumentError, /Generate a current check package/)
    expect { CheckPrintRunSelectionVerifier.new(run: package).call }
      .to raise_error(CheckPrintRunSelectionVerifier::StaleSelectionError, /different check number/)
    expect(package.reload.manifest).to eq(manifest)
  end

  it "keeps a prepared check unchanged when another worksheet check has already been issued" do
    item_a.mark_package_prepared!(user: admin_user)
    item_b.mark_printed!(user: admin_user)
    item_b.mark_delivered!(user: admin_user, delivered_on: Date.current, delivery_method: "hand_delivery", attestation: true)
    originals = [ item_a, item_b ].map { |item| item.reload.attributes }

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "4100" },
          { source_type: "payroll_item", source_id: item_b.id, check_number: "4101" }
        ]
      }
    }.not_to change { AuditLog.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("cannot be changed after")
    expect([ item_a, item_b ].map { |item| item.reload.attributes }).to eq(originals)
    expect(company.reload.next_check_number).to eq(3002)
    expect(CheckEvent.where(event_type: "renumbered")).to be_empty
  end

  it "does not renumber checks after they are issued" do
    item_a.mark_printed!(user: admin_user)
    item_a.mark_delivered!(
      user: admin_user,
      delivered_on: Date.current,
      delivery_method: "hand_delivery",
      attestation: true
    )

    patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
      changes: [ { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" } ]
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("cannot be changed after")
    expect(item_a.reload.check_number).to eq("3000")
  end

  it "corrects a prepared TOG check and payroll check together without recreating the tax payment" do
    item_a.update!(withholding_tax: 150)
    non_employee_check.update!(payable_to: "Treasurer of Guam", check_type: "tax_deposit",
      auto_generated_type: "fit_deposit", amount: 150)
    non_employee_check.line_items.create!(description: "FIT withholding", amount: 150, position: 0)
    posting = PayrollLiabilityPostingService.post!(pay_period: pay_period, actor: admin_user)
    entry_ids = posting.entries.where(authority: PayrollLiabilityPostingService::GUAM_DRT).pluck(:id)
    PayrollLiabilityCheckAllocationService.allocate!(non_employee_check: non_employee_check, entry_ids: entry_ids)
    transmittal = Transmittal.create!(pay_period: pay_period, company: company,
      payroll_check_numbers: %w[3000 3001], non_employee_check_numbers: { non_employee_check.id.to_s => "3500" })
    item_a.mark_package_prepared!(user: admin_user)
    non_employee_check.mark_package_prepared!
    originals = [ item_a, non_employee_check ].map { |record| record.reload.attributes.except("check_number", "updated_at") }
    allocations = non_employee_check.payroll_liability_check_allocations.map(&:attributes)
    journal = posting.entries.map(&:attributes)
    line_items = non_employee_check.line_items.map(&:attributes)
    manifest = [ item_a, non_employee_check ].map do |record|
      type = record.is_a?(PayrollItem) ? "payroll_item" : "non_employee_check"
      {
        "key" => "#{type}:#{record.id}", "source_type" => type, "source_id" => record.id,
        "check_number" => record.check_number,
        "amount" => (record.is_a?(PayrollItem) ? record.net_pay : record.amount).to_s,
        "source_updated_at" => record.updated_at.iso8601(6), "print_count" => 0, "printed_at" => nil
      }
    end
    package = CheckPrintRun.create!(
      company: company, pay_period: pay_period, created_by: admin_user, status: "prepared",
      check_stock_type: company.check_stock_type, starting_slot: 1, selected_count: 2,
      manifest: manifest, storage_key: "check-print-runs/tog-renumber-spec.pdf", filename: "tog-renumber-spec.pdf",
      sha256: "b" * 64, byte_size: 100, generated_at: Time.current
    )
    expect { CheckPrintRunSelectionVerifier.new(run: package).call }.not_to raise_error

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        reason: "Match physical stock before printing",
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "4100" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "4101" }
        ]
      }
    }.to change { NonEmployeeCheckEdit.count }.by(1)
      .and change { AuditLog.where(action: [ "checks#check_number_updated", "non_employee_checks#updated" ]).count }.by(2)
      .and change { NonEmployeeCheck.count }.by(0)

    expect(response).to have_http_status(:ok)
    expect([ item_a.reload.check_number, non_employee_check.reload.check_number ]).to eq(%w[4100 4101])
    expect([ item_a, non_employee_check ].map { |record| record.attributes.except("check_number", "updated_at") }).to eq(originals)
    expect(non_employee_check.payroll_liability_check_allocations.reload.map(&:attributes)).to eq(allocations)
    expect(posting.entries.reload.map(&:attributes)).to eq(journal)
    expect(non_employee_check.line_items.reload.map(&:attributes)).to eq(line_items)
    expect(non_employee_check.edits.last.changed_fields).to eq([ "check_number" ])
    expect(company.reload.next_check_number).to eq(4102)
    expect(transmittal.reload.payroll_check_numbers).to eq(%w[3001 4100])
    expect(transmittal.non_employee_check_numbers).to eq(non_employee_check.id.to_s => "4101")
    expect(non_employee_check.prepared?).to be(false)
    expect {
      non_employee_check.mark_paid!(actor: admin_user, payment_date: Date.current.iso8601)
    }.to raise_error(ArgumentError, /Generate a current check package/)
    expect { CheckPrintRunSelectionVerifier.new(run: package).call }
      .to raise_error(CheckPrintRunSelectionVerifier::StaleSelectionError, /different check number/)
    expect(package.reload.manifest).to eq(manifest)
  end

  %w[printed paid cleared replacement_required voided electronic].each do |state|
    it "rejects a #{state.humanize.downcase} other-payment check without partially changing the worksheet" do
      item_a.mark_package_prepared!(user: admin_user)
      non_employee_check.mark_package_prepared!
      case state
      when "printed"
        non_employee_check.mark_printed!
      when "paid"
        non_employee_check.update!(paid_at: Time.current, paid_by: admin_user)
      when "cleared", "replacement_required"
        non_employee_check.check_reconciliation_events.create!(company: company, pay_period: pay_period,
          recorded_by: admin_user, event_type: state, check_number: non_employee_check.check_number,
          amount: non_employee_check.amount, effective_on: Date.current, idempotency_key: SecureRandom.uuid)
      when "voided"
        non_employee_check.void!(reason: "Synthetic voided stock")
      when "electronic"
        non_employee_check.update!(payment_method: "eftps")
      end
      originals = [ item_a, non_employee_check ].map { |record| record.reload.attributes }

      expect {
        patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
          changes: [
            { source_type: "payroll_item", source_id: item_a.id, check_number: "4100" },
            { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "4101" }
          ]
        }
      }.not_to change { AuditLog.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect([ item_a, non_employee_check ].map { |record| record.reload.attributes }).to eq(originals)
      expect(company.reload.next_check_number).to eq(3002)
      expect(NonEmployeeCheckEdit.count).to eq(0)
      expect(CheckEvent.where(event_type: "renumbered")).to be_empty
    end
  end

  it "rejects a voided check without partially renumbering a prepared check" do
    item_a.mark_package_prepared!(user: admin_user)
    item_b.update!(voided: true, voided_at: Time.current, void_reason: "Synthetic voided stock")
    originals = [ item_a, item_b ].map { |item| item.reload.attributes }

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "4100" },
          { source_type: "payroll_item", source_id: item_b.id, check_number: "4101" }
        ]
      }
    }.not_to change { AuditLog.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("voided payroll check")
    expect([ item_a, item_b ].map { |item| item.reload.attributes }).to eq(originals)
    expect(company.reload.next_check_number).to eq(3002)
    expect(CheckEvent.where(event_type: "renumbered")).to be_empty
  end

  %w[cleared replacement_required].each do |status|
    it "does not renumber #{status.humanize.downcase} checks or write correction audits" do
      reconcile_item!(item_a, status)
      renumbered_event_count = CheckEvent.where(event_type: "renumbered").count
      correction_audit_count = AuditLog.where(action: "checks#check_number_updated").count

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [ { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" } ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("cannot be changed after")
      expect(item_a.reload.check_number).to eq("3000")
      expect(CheckEvent.where(event_type: "renumbered").count).to eq(renumbered_event_count)
      expect(AuditLog.where(action: "checks#check_number_updated").count).to eq(correction_audit_count)
    end
  end
end
