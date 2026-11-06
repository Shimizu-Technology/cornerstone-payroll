# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Recurring setup calculation currentness", type: :request do
  before { ensure_verified_test_tax_years(2024, 2025, 2026) }
  let!(:company) { create(:company) }
  let!(:employee) { create(:employee, company: company) }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let!(:field) { create(:payroll_field_definition, company: company, owner_employee: employee, default_amount: 250) }
  let!(:assignment) { employee.employee_payroll_fields.create!(payroll_field_definition: field, amount: 250) }
  let(:path) { "/api/v1/admin/employees/#{employee.id}/payroll_fields" }

  before do
    [ Api::V1::Admin::PayrollFieldsController, Api::V1::Admin::EmployeePayrollFieldsController, Api::V1::Admin::EmployeesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(controller).to receive(:current_user).and_return(accountant)
    end
  end

  def calculated_period(status: "calculated", pay_date: Date.new(2026, 10, 15), recurring: true, source: "employee_default")
    period = create(:pay_period, company: company, status: "calculated", calculated_at: Time.current,
      start_date: pay_date - 14, end_date: pay_date - 1, pay_date: pay_date,
      run_purpose: recurring ? "regular" : "bonus", includes_recurring_items: recurring)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 1250, net_pay: 1100, hours_worked: 80)
    entry = create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, amount: 250, source: source)
    package = PayrollReview::RevisionService.new(pay_period: period, actor: accountant).issue!
    period.update!(status: status, approved_at: status == "approved" ? Time.current : nil, approved_by_id: status == "approved" ? accountant.id : nil)
    [ period, item, entry, package ]
  end

  %w[calculated approved].each do |status|
    it "invalidates #{status} payroll on 250 to 300 and blocks stale approval and commit without modifying its worksheet" do
      period, item, entry, package = calculated_period(status: status)
      old_item, old_entry = item.attributes, entry.attributes
      patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ period.id ])
      expect(period.reload).to be_draft
      expect(period.calculated_at).to be_nil
      expect(period.approved_at).to be_nil
      expect(period.approved_by_id).to be_nil
      expect(package.reload.status).to eq("superseded")
      expect(item.reload.attributes).to eq(old_item)
      expect(entry.reload.attributes).to eq(old_entry)
      lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: accountant)
      expect { lifecycle.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /calculated/)
      expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /approved/)
    end
  end

  it "invalidates an affected new addition while preserving an unchanged idempotent retry" do
    period, = calculated_period
    payload = { scope: "employee_only", payroll_field: { name: "New recurring allowance", kind: "addition", tax_treatment: "taxable_addition", amount_type: "fixed" }, employee_payroll_field: { amount: 75, start_date: "2026-10-15" } }
    post "#{path}/create_and_assign", params: payload, as: :json
    expect(response).to have_http_status(:created)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    post "#{path}/create_and_assign", params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
  end

  it "invalidates stop and reactivation and does not invalidate a no-op save" do
    period, = calculated_period
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 250 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
    delete "#{path}/#{assignment.id}"
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { active: true } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
  end

  it "invalidates a shared inherited amount change but preserves finalized snapshots" do
    # A new shared identity models a client library field rather than converting scope.
    shared = create(:payroll_field_definition, company: company, default_amount: 250)
    assignment.update!(payroll_field_definition: shared, amount: nil)
    period, item, entry, = calculated_period(status: "approved")
    finalized, final_item, final_entry, = calculated_period(status: "committed", pay_date: Date.new(2026, 9, 30))
    old_final_item, old_final_entry = final_item.attributes, final_entry.attributes
    patch "/api/v1/admin/payroll_fields/#{shared.id}", params: { payroll_field: { default_amount: 300 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ period.id ])
    expect(period.reload).to be_draft
    expect(item.reload.gross_pay).to eq(1250)
    expect(entry.reload.amount).to eq(250)
    expect(finalized.reload).to be_committed
    expect(final_item.reload.attributes).to eq(old_final_item)
    expect(final_entry.reload.attributes).to eq(old_final_entry)
  end

  it "invalidates shared archive and shared metadata used by a manual entry in a recurring-off run" do
    shared = create(:payroll_field_definition, company: company, default_amount: 250)
    assignment.update!(payroll_field_definition: shared)
    period, = calculated_period
    delete "/api/v1/admin/payroll_fields/#{shared.id}"
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    special, _, entry, = calculated_period(recurring: false, source: "manual")
    entry.update!(payroll_field_definition: shared)
    patch "/api/v1/admin/payroll_fields/#{shared.id}", params: { payroll_field: { name: "Shared renamed" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ special.id ])
    expect(special.reload).to be_draft
    expect(entry.reload.source).to eq("manual")
    expect(entry.amount).to eq(250)
  end

  it "leaves future or ended assignments, absent employees, and recurring-off automatic rows alone" do
    period, = calculated_period
    special, = calculated_period(recurring: false, pay_date: Date.new(2026, 10, 16))
    assignment.update!(start_date: Date.new(2026, 10, 20))
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
    assignment.update!(start_date: nil, end_date: Date.new(2026, 10, 14))
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 350 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    assignment.update!(end_date: nil)
    period.payroll_items.destroy_all
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 400 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(special.reload).to be_calculated
  end

  it "includes the last payday and old date range when ending an effective item" do
    assignment.update!(start_date: Date.new(2026, 10, 15), end_date: Date.new(2026, 10, 15))
    period, = calculated_period
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { end_date: "2026-10-14", start_date: nil } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
  end

  it "invalidates existing assignment and bulk update paths too" do
    period, = calculated_period
    patch "#{path}/#{assignment.id}", params: { employee_payroll_field: { amount: 300 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    post "#{path}/bulk_update", params: { employee_payroll_fields: [ { id: assignment.id, payroll_field_definition_id: field.id, amount: 400 } ] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
  end

  it "invalidates legacy conversion when its automatic legacy snapshot can refresh" do
    legacy = { label: "Older allowance", amount: 75, treatment: "taxable_addition", active: true }
    employee.update!(default_payroll_adjustments: [ legacy ])
    period, item, = calculated_period
    item.update!(payroll_adjustments: [ legacy ])
    item.mark_payroll_adjustments_default_snapshot!
    item.save!
    post "#{path}/convert_legacy", params: {
      legacy: legacy.merge(kind: "adjustment"), payroll_field: { name: "Older allowance", category: "other" }, employee_payroll_field: { start_date: "2026-10-15" }
    }, as: :json
    expect(response).to have_http_status(:created)
    expect(period.reload).to be_draft
    expect(item.reload.payroll_adjustments.first["label"]).to eq("Older allowance")
  end
  it "invalidates removing a legacy profile default but leaves an ordinary profile edit alone" do
    legacy = { label: "Older allowance", amount: 750, treatment: "taxable_addition", active: true }
    employee.update!(default_payroll_adjustments: [ legacy ])
    period, item, = calculated_period(status: "approved")
    item.update!(payroll_adjustments: [ legacy ])
    item.mark_payroll_adjustments_default_snapshot!
    item.save!
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { first_name: "Updated" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_approved
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { default_payroll_adjustments: [] } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    expect(item.reload.payroll_adjustments.first["amount"]).to eq(750)
  end
  it "does not invalidate a shared default edit for an explicit zero override" do
    shared = create(:payroll_field_definition, company: company, default_amount: 250)
    assignment.update!(payroll_field_definition: shared, amount: 0)
    period, = calculated_period
    patch "/api/v1/admin/payroll_fields/#{shared.id}", params: { payroll_field: { default_amount: 300 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
  end

  it "covers legacy custom earnings removal and compatible personal creation" do
    employee.update!(default_custom_earnings: [ { label: "Legacy earning", amount: 50 } ])
    period, item, = calculated_period
    item.sync_default_custom_earnings!(employee)
    item.save!
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { default_custom_earnings: [] } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    post "#{path}/create_personal", params: {
      payroll_field: { name: "Compatibility allowance", kind: "addition", tax_treatment: "taxable_addition" },
      employee_payroll_field: { amount: 50 }
    }, as: :json
    expect(response).to have_http_status(:created)
    expect(period.reload).to be_draft
  end


  [ ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved ].each do |error_class|
    it "returns truthful JSON and rolls back creation when post-render invalidation raises #{error_class}" do
      period, item, entry, package = calculated_period
      old_item, old_entry = item.attributes, entry.attributes
      failure = period.dup
      failure.errors.add(:base, "Review invalidation failed")
      error = error_class == ActiveRecord::RecordInvalid ? error_class.new(failure) : error_class.new("Review invalidation failed", failure)
      allow_any_instance_of(PayPeriod).to receive(:invalidate_calculation!).and_raise(error)
      previous_definitions = PayrollFieldDefinition.count
      previous_assignments = EmployeePayrollField.count
      previous_audits = AuditLog.count
      post "#{path}/create_and_assign", params: {
        scope: "employee_only", payroll_field: { name: "Rolled back addition", kind: "addition", tax_treatment: "taxable_addition" },
        employee_payroll_field: { amount: 75 }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body).to eq("errors" => [ "Review invalidation failed" ])
      expect(PayrollFieldDefinition.count).to eq(previous_definitions)
      expect(EmployeePayrollField.count).to eq(previous_assignments)
      expect(AuditLog.count).to eq(previous_audits)
      expect(period.reload).to be_calculated
      expect(package.reload.status).to eq("pending")
      expect(item.reload.attributes).to eq(old_item)
      expect(entry.reload.attributes).to eq(old_entry)
    end

    it "returns truthful JSON and rolls back edited source and reviews when invalidation raises #{error_class}" do
      period, item, entry, package = calculated_period(status: "approved")
      old_period, old_item, old_entry, old_package = period.attributes, item.attributes, entry.attributes, package.attributes
      failure = period.dup
      failure.errors.add(:base, "Review invalidation failed")
      error = error_class == ActiveRecord::RecordInvalid ? error_class.new(failure) : error_class.new("Review invalidation failed", failure)
      allow_any_instance_of(PayPeriod).to receive(:invalidate_calculation!) do |record|
        record.supersede_current_review_package!(reason: "Started invalidation")
        raise error
      end
      patch "#{path}/#{assignment.id}/pay_item", params: {
        payroll_field: { name: "Rolled back rename" }, employee_payroll_field: { amount: 300 }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("errors" => [ "Review invalidation failed" ])
      expect(assignment.reload.amount).to eq(250)
      expect(field.reload.name).not_to eq("Rolled back rename")
      expect(period.reload.attributes).to eq(old_period)
      expect(package.reload.attributes).to eq(old_package)
      expect(item.reload.attributes).to eq(old_item)
      expect(entry.reload.attributes).to eq(old_entry)
    end
  end

  it "preserves cloned approved baseline evidence while invalidating mutable practice calculations" do
    admin = create(:user, company: company, organization: company.organization, role: "admin")
    employee.update!(department: nil)
    [ Date.new(2026, 9, 30), Date.new(2026, 10, 30) ].each do |pay_date|
      source = create(:pay_period, :committed, company: company, start_date: pay_date - 14, end_date: pay_date - 1, pay_date: pay_date)
      source_item = create(:payroll_item, company: company, employee: employee, pay_period: source, gross_pay: 1250, net_pay: 1100)
      create(:payroll_item_field_entry, payroll_item: source_item, payroll_field_definition: field, amount: 250)
      source
    end
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    workspace = TestWorkspace::Create.new(
      source_company: company, actor: admin, acknowledgement: TestWorkspace::Create::ACKNOWLEDGEMENT,
      assignments: [ { user_id: accountant.id, workspace_access_level: "operator" } ], copy_mode: "all_committed"
    ).call
    TestWorkspace::Cloner.new(company: workspace, actor: admin).call
    baselines = workspace.pay_periods.order(:pay_date).to_a
    expect(baselines.map(&:status)).to eq([ "approved", "approved" ])
    expect(baselines.map(&:test_workspace_role)).to eq([ "baseline", "baseline" ])
    baseline_snapshots = baselines.map { |period| [ period.attributes, period.payroll_items.map(&:attributes), period.payroll_items.flat_map { |item| item.payroll_item_field_entries.map(&:attributes) } ] }
    target_employee = workspace.employees.find_by!(test_workspace_source_employee_id: employee.id)
    target_assignment = target_employee.employee_payroll_fields.sole
    practice_source = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 10, 15),
      start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 14))
    practice = create(:pay_period, :calculated, company: workspace, pay_date: Date.new(2026, 10, 15),
      start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 14), calculated_at: Time.current,
      test_workspace_role: "practice", test_workspace_source_pay_period: practice_source)
    item = create(:payroll_item, company: workspace, employee: target_employee, pay_period: practice, gross_pay: 1250, net_pay: 1100)
    create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: target_assignment.payroll_field_definition, amount: 250)
    package = PayrollReview::RevisionService.new(pay_period: practice, actor: accountant).issue!
    allow_any_instance_of(Api::V1::Admin::EmployeePayrollFieldsController).to receive(:current_company_id).and_return(workspace.id)

    patch "/api/v1/admin/employees/#{target_employee.id}/payroll_fields/#{target_assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ practice.id ])
    expect(practice.reload).to be_draft
    expect(package.reload.status).to eq("superseded")
    expect(target_assignment.reload.amount).to eq(300)
    expect(assignment.reload.amount).to eq(250)
    expect(baselines.map { |period| [ period.reload.attributes, period.payroll_items.reload.map(&:attributes), period.payroll_items.flat_map { |row| row.payroll_item_field_entries.reload.map(&:attributes) } ] }).to eq(baseline_snapshots)
  ensure
    ActiveJob::Base.queue_adapter = original_adapter if original_adapter
  end
  it "invalidates an approved imported run without changing its frozen source portions or saved money" do
    period, item, entry, package = calculated_period(status: "approved")
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    uuid = SecureRandom.uuid
    batch_id = "AIRE-PAY-CURRENTNESS-#{SecureRandom.uuid}"
    line = { "source_user_uuid" => uuid, "source_time_entry_id" => "41", "line_key" => "operations:41",
      "source_kind" => "current", "original_work_date" => period.start_date.iso8601,
      "total_hours" => 4, "regular_hours" => 4, "overtime_hours" => 0 }
    payload = { "schema_version" => "2.0", "batch_id" => batch_id,
      "employees" => [ { "source_user_id" => "91", "source_user_uuid" => uuid, "adjustments" => [ line ] } ] }
    checksum = TimeTracking::CanonicalPayload.checksum(payload)
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source,
      status: "applied", external_batch_id: batch_id, external_batch_checksum: checksum,
      source_payload_hash: checksum, raw_payload: payload)
    allocation = TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source,
      time_tracking_import: import, pay_period: period, payroll_item: item, employee: employee,
      source_user_id: "91", source_user_uuid: uuid, source_time_entry_id: "41",
      line_key: "operations:41", source_kind: "current", original_work_date: period.start_date,
      total_hours: 4, regular_hours: 4, overtime_hours: 0)
    batch_ack = AirePayrollAcknowledgement.record!(time_tracking_import: import, status: "imported", occurred_at: Time.current)
    entry_ack = AirePayrollEntryAcknowledgement.record_for_import!(time_tracking_import: import, status: "imported", occurred_at: Time.current).sole
    batch_ack.mark_delivered!(at: Time.current)
    entry_ack.mark_delivered!(at: Time.current)
    frozen_rows = [ import.attributes, allocation.attributes, item.attributes, entry.attributes ]
    old_receipts = [ batch_ack.reload.attributes, entry_ack.reload.attributes ]
    expect(TimeTracking::Client).not_to receive(:new)

    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    expect(package.reload.status).to eq("superseded")
    expect([ import.reload.attributes, allocation.reload.attributes, item.reload.attributes, entry.reload.attributes ]).to eq(frozen_rows)
    expect([ batch_ack.reload.attributes, entry_ack.reload.attributes ]).to eq(old_receipts)
    expect([ AirePayrollAcknowledgement.count, AirePayrollEntryAcknowledgement.count ]).to eq([ 1, 1 ])
    expect(allocation).to be_readonly
  end

  it "keeps a committed reported-payment reservation and its financial hold when future setup changes" do
    period, item, entry, package = calculated_period(status: "approved")
    period.update!(status: "committed", committed_at: Time.current, committed_by_id: accountant.id)
    item.update!(check_number: "30000")
    create(:check_event, payroll_item: item, user: accountant, event_type: "delivered",
      check_number: "30000", evidence_type: "hand_delivery", evidence_reference: "SYNTHETIC-EXISTING-HANDOFF")
    EmployeeYtdTotal.create!(employee: employee, year: 2026, gross_pay: item.gross_pay, net_pay: item.net_pay)
    CompanyYtdTotal.create!(company: company, year: 2026, gross_pay: item.gross_pay, net_pay: item.net_pay)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    allocation = TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: item, employee: employee, created_by: accountant,
      source_user_uuid: SecureRandom.uuid, source_time_entry_id: "41", source_time_entry_version: 2,
      original_work_date: period.start_date, regular_hours: 4, overtime_hours: 0,
      reconciliation_note: "Synthetic existing payment match awaiting exact source confirmation",
      payment_resolution_intent: { "command_id" => SecureRandom.uuid, "review_pay_period_id" => period.id.to_s },
      payment_resolution_receipt: {})
    frozen_rows = [ period.attributes, item.attributes, entry.attributes, package.attributes, allocation.attributes ]
    check_rows = item.check_events.map(&:attributes)
    ytd_rows = [ EmployeeYtdTotal.where(employee_id: employee.id).map(&:attributes), CompanyYtdTotal.where(company_id: company.id).map(&:attributes) ]
    expect(TimeTracking::Client).not_to receive(:new)

    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(assignment.reload.amount).to eq(300)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([])
    expect([ period.reload.attributes, item.reload.attributes, entry.reload.attributes, package.reload.attributes, allocation.reload.attributes ]).to eq(frozen_rows)
    expect(item.check_events.reload.map(&:attributes)).to eq(check_rows)
    expect([ EmployeeYtdTotal.where(employee_id: employee.id).map(&:attributes), CompanyYtdTotal.where(company_id: company.id).map(&:attributes) ]).to eq(ytd_rows)
    expect(allocation).to be_payment_resolution_pending
    expect(period.update(status: "draft")).to be(false)
    expect(period.errors.full_messages.join).to include("hours remain reserved")
    expect(period.reload.attributes).to eq(frozen_rows.first)
  end
end
