# frozen_string_literal: true

require "rails_helper"

# The pay run's Activity tab: every run-scoped action, in plain words, and no
# entries for data the screen loads on its own.
RSpec.describe "Pay run activity feed", type: :request do
  let!(:organization) { create(:organization, name: "Activity Firm") }
  let!(:company) { create(:company, organization: organization, name: "Activity Client") }
  let!(:other_company) { create(:company, organization: organization, name: "Other Client") }
  let!(:staff) { create(:user, organization: organization, company: company, role: :admin, name: "Dana Admin") }
  let!(:pay_period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15),
      pay_date: Date.new(2026, 11, 19), status: "calculated")
  end
  let!(:other_period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 10, 19), end_date: Date.new(2026, 11, 1),
      pay_date: Date.new(2026, 11, 5))
  end
  let!(:avery) { create(:employee, company: company, first_name: "Avery", last_name: "Monroe") }
  let!(:nadine) { create(:employee, company: company, first_name: "Nadine", last_name: "Robles") }
  let(:feed_url) { "/api/v1/admin/record_activities/pay_periods/#{pay_period.id}" }

  before do
    AuditLog.delete_all
    stub_portal_user(Api::V1::Admin::RecordActivitiesController, staff, company)
  end

  def log!(action, record_type: "pay_periods", record_id: pay_period.id, metadata: {}, **attributes)
    create(:audit_log, user: staff, organization: organization, company: company, action: action,
      record_type: record_type, record_id: record_id, metadata: metadata, **attributes)
  end

  def feed(params = {})
    get feed_url, params: { per_page: 100 }.merge(params)
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def headlines(params = {})
    feed(params).fetch("data").to_h { |entry| [ entry.fetch("id"), entry.fetch("display_action") ] }
  end

  it "describes each run action in plain words with names, amounts and revisions" do
    preview = log!("checks#preview_pdf", record_type: "PayPeriod", event_category: "document_access",
      metadata: { pay_period_id: pay_period.id, revision: 2, part: "combined" })
    marked = log!("payroll_entry_resolutions#save", record_type: "PayPeriod", subject_name: "Nadine Robles",
      metadata: { resolution: { employee_id: nadine.id, note: "On leave" }, employee_name: "Nadine Robles" })
    undone = log!("payroll_entry_resolutions#destroy", record_type: "PayPeriod", subject_name: "Nadine Robles",
      metadata: { resolution: { employee_id: nadine.id, note: nil }, employee_name: "Nadine Robles" })
    removed = log!("payroll_items#destroy", record_type: "payroll_items", record_id: 999_001, subject_name: "Avery Monroe",
      metadata: { pay_period_id: pay_period.id, employee_name: "Avery Monroe" })
    added_back = log!("pay_period_excluded_employees#destroy", record_type: "PayPeriod", subject_name: "Avery Monroe",
      metadata: { employee_id: avery.id })
    imported = log!("payroll_imports#apply", record_type: "payroll_imports",
      metadata: { pay_period_id: pay_period.id, applied_count: 52, source_files: %w[revel_hours supplemental_workbook] })
    owner_pay = log!("payroll_items#update", record_type: "payroll_items", record_id: 999_002, subject_name: "Leilani Reyes",
      metadata: { pay_period_id: pay_period.id, owner_pay: true, after_values: { salary_override: "8807.5" } })
    hours = log!("payroll_items#update", record_type: "payroll_items", record_id: 999_003, subject_name: "Avery Monroe",
      metadata: { pay_period_id: pay_period.id, after_values: { hours_worked: "40.0", overtime_hours: "2.5" } })
    package = log!("check_print_runs#generated", record_type: "check_print_runs", record_id: 999_004,
      metadata: { pay_period_id: pay_period.id, package_number: 1, selected_count: 9,
        check_numbers: %w[22026 22027 22028 22029 22030 22031 22032 22033 22034] })
    opened = log!("check_print_runs#pdf", record_type: "check_print_runs", record_id: 999_004, event_category: "document_access",
      metadata: { pay_period_id: pay_period.id, package_number: 1, access_type: "view" })
    renumbered = log!("checks#check_number_updated", record_type: "checks", record_id: 999_005, subject_name: "Yuji Fitial",
      metadata: { pay_period_id: pay_period.id, before_values: { check_number: "22034" }, after_values: { check_number: "22040" } })
    method_changed = log!("payroll_item#payment_delivery_method_changed", record_type: "PayrollItem", record_id: 999_006,
      subject_name: "Avery Monroe", metadata: { pay_period_id: pay_period.id, from: "direct_deposit", to: "paper_check" })

    actions = headlines

    expect(actions.fetch(preview.id)).to eq("Dana Admin downloaded the preview: checks and pay stubs (revision 2)")
    expect(actions.fetch(marked.id)).to eq("Dana Admin marked Nadine Robles Not paid this period: “On leave”")
    expect(actions.fetch(undone.id)).to eq("Dana Admin undid Not paid for Nadine Robles")
    expect(actions.fetch(removed.id)).to eq("Dana Admin removed Avery Monroe from this run")
    expect(actions.fetch(added_back.id)).to eq("Dana Admin added Avery Monroe back to this run")
    expect(actions.fetch(imported.id)).to eq("Dana Admin applied the import: 52 employees (Revel PDF, workbook)")
    expect(actions.fetch(owner_pay.id)).to eq("Dana Admin saved owner pay for Leilani Reyes: $8,807.50")
    expect(actions.fetch(hours.id)).to eq("Dana Admin saved hours for Avery Monroe: 40 regular, 2.5 overtime")
    expect(actions.fetch(package.id)).to eq("Dana Admin generated check package #1: 9 checks, 22026–22034")
    expect(actions.fetch(opened.id)).to eq("Dana Admin viewed the saved check PDF for package #1")
    expect(actions.fetch(renumbered.id)).to eq("Dana Admin changed the check number for Yuji Fitial from 22034 to 22040")
    expect(actions.fetch(method_changed.id))
      .to eq("Dana Admin changed the payment method for Avery Monroe from direct deposit to paper check")
  end

  it "keeps approve, roll back and approve again as separate milestones" do
    first = log!("pay_periods#approve", created_at: 3.hours.ago)
    rolled_back = log!("pay_periods#unapprove", created_at: 2.hours.ago)
    second = log!("pay_periods#approve", created_at: 1.hour.ago)

    expect(feed.fetch("data").pluck("id", "action")).to eq([
      [ second.id, "pay_periods#approve" ], [ rolled_back.id, "pay_periods#unapprove" ], [ first.id, "pay_periods#approve" ]
    ])
  end

  it "finds older run rows through the run's items, imports and check packages" do
    item = create(:payroll_item, pay_period: pay_period, employee: avery)
    other_item = create(:payroll_item, pay_period: other_period, employee: nadine)
    item_log = log!("payroll_items#update", record_type: "payroll_items", record_id: item.id, subject_name: "Avery Monroe")
    import_log = log!("payroll_imports#preview", record_type: "payroll_imports")
    other_item_log = log!("payroll_items#update", record_type: "payroll_items", record_id: other_item.id)
    other_period_log = log!("payroll_imports#preview", record_type: "payroll_imports", record_id: other_period.id)
    settings_log = log!("checks#update_check_settings", record_type: "checks", record_id: item.id)

    ids = headlines.keys

    expect(ids).to include(item_log.id, import_log.id)
    expect(ids).not_to include(other_item_log.id, other_period_log.id, settings_log.id)
  end

  it "finds older non-employee check rows through the run's checks" do
    check = create(:non_employee_check, company: company, pay_period: pay_period)
    check.update_columns(id: pay_period.id + 5_000) if check.id == pay_period.id
    expect(check.id).not_to eq(pay_period.id)
    renumbered = log!("non_employee_checks#updated", record_type: "non_employee_checks", record_id: check.id,
      subject_name: check.payable_to, metadata: {})
    voided = log!("void_non_employee_check", record_type: "NonEmployeeCheck", record_id: check.id, metadata: {})
    other_check = create(:non_employee_check, company: company, pay_period: other_period)
    elsewhere = log!("non_employee_checks#updated", record_type: "non_employee_checks", record_id: other_check.id)

    ids = headlines.keys

    expect(ids).to include(renumbered.id, voided.id)
    expect(ids).not_to include(elsewhere.id)
  end

  it "says not set for a pay amount entered for the first time" do
    log = log!("pay_periods#run_payroll", metadata: {
      input_change_count: 1,
      input_changes: [ { employee_id: avery.id, employee_name: "Leilani Reyes",
        before_values: {}, after_values: { salary_override: "8807.5" } } ]
    })

    entry = feed.fetch("data").find { |row| row["id"] == log.id }
    expect(entry.fetch("detail_lines")).to eq([ "Leilani Reyes: pay not set → $8,807.50" ])
  end

  it "stays inside the current client" do
    foreign = create(:audit_log, company: other_company, action: "payroll_items#destroy", record_type: "payroll_items",
      record_id: 1, metadata: { pay_period_id: pay_period.id })

    expect(headlines.keys).not_to include(foreign.id)
  end

  it "names another run's dates when the action belongs to a different run" do
    log = log!("payroll_items#destroy", record_type: "payroll_items", record_id: 1, subject_name: "Avery Monroe",
      metadata: { pay_period_id: other_period.id })

    get "/api/v1/admin/record_activities/pay_periods/#{other_period.id}"
    expect(response.parsed_body.dig("data", 0, "display_action")).to eq("Dana Admin removed Avery Monroe from this run")

    presenter = AuditLogPresenter.new(log, run_context_id: pay_period.id)
    expect(presenter.headline).to eq("Dana Admin removed Avery Monroe from the Oct 19, 2026 – Nov 1, 2026 run")
  end

  it "reads an older resolution's employee name within the same client" do
    log = log!("payroll_entry_resolutions#save", record_type: "PayPeriod", metadata: { resolution: { employee_id: nadine.id } })

    expect(headlines.fetch(log.id)).to eq("Dana Admin marked Nadine Robles Not paid this period")
  end

  it "summarizes a calculation that changed entries and lists each change" do
    log = log!("pay_periods#run_payroll", metadata: {
      input_change_count: 1,
      input_changes: [ { employee_id: avery.id, employee_name: "Avery Monroe",
        before_values: { hours_worked: "0.0" }, after_values: { hours_worked: "40.0" } } ]
    })

    entry = feed.fetch("data").find { |row| row["id"] == log.id }
    expect(entry.fetch("display_action")).to eq("Dana Admin calculated payroll with new entries for Avery Monroe: 40 regular")
    expect(entry.fetch("detail_lines")).to eq([ "Avery Monroe: regular hours 0 → 40" ])
  end

  it "hides report editor loads by default and shows them on request" do
    detail = log!("reports#transmittal_preview", record_type: "reports", event_category: "document_access",
      metadata: { pay_period_id: pay_period.id, report_key: "transmittal", access_type: "preview" })
    document = log!("reports#transmittal_log_pdf", record_type: "reports", event_category: "document_access",
      metadata: { pay_period_id: pay_period.id, report_key: "transmittal_log", access_type: "view" })

    default_view = feed
    expect(default_view.fetch("data").pluck("id")).to eq([ document.id ])
    expect(default_view.dig("meta", "hidden_detail_count")).to eq(1)

    full_view = feed(include_hidden_details: true)
    expect(full_view.fetch("data").pluck("id")).to contain_exactly(document.id, detail.id)
    expect(full_view.dig("meta", "hidden_detail_count")).to eq(0)
  end

  it "hides worker and client pay stub views by default and labels them when shown" do
    item = create(:payroll_item, pay_period: pay_period, employee: avery)
    worker_view = create(:audit_log, company: company, organization: organization, user: nil, action: "worker_statement#viewed",
      record_type: "PayrollItem", record_id: item.id, subject_name: "Avery Monroe", event_category: "integration",
      metadata: { employee_id: avery.id, payroll_item_id: item.id })
    client_download = log!("client_pay_stubs#download", record_type: "PayrollItem", record_id: item.id,
      event_category: "document_access", metadata: { employee_id: avery.id, pay_period_id: pay_period.id })
    staff_change = log!("payroll_items#update", record_type: "payroll_items", record_id: item.id, subject_name: "Avery Monroe")

    default_view = feed
    expect(default_view.fetch("data").pluck("id")).to eq([ staff_change.id ])
    expect(default_view.dig("meta", "hidden_detail_count")).to eq(2)

    shown = headlines(include_hidden_details: true)
    expect(shown.fetch(worker_view.id)).to eq("Avery Monroe viewed their pay stub in the AIRE app")
    expect(shown.fetch(client_download.id)).to eq("Dana Admin downloaded the pay stub for Avery Monroe from the client portal")
  end

  it "counts hidden rows only for the first page" do
    3.times { |index| log!("pay_periods#run_payroll", created_at: index.minutes.ago) }
    log!("reports#transmittal_preview", record_type: "reports", metadata: { pay_period_id: pay_period.id })

    expect(feed(per_page: 2).dig("meta", "hidden_detail_count")).to eq(1)
    expect(feed(per_page: 2, page: 2).fetch("meta")).not_to have_key("hidden_detail_count")
  end

  it "names the run in company-wide history, where there is no run to call this one" do
    log = log!("payroll_items#destroy", record_type: "payroll_items", record_id: 1, subject_name: "Avery Monroe",
      metadata: { pay_period_id: pay_period.id })

    expect(AuditLogPresenter.new(log).headline).to eq("Dana Admin removed Avery Monroe from the Nov 2, 2026 – Nov 15, 2026 run")
  end

  it "reads older rows' employee names in one query" do
    logs = 3.times.map do
      log!("payroll_entry_resolutions#save", record_type: "PayPeriod", metadata: { resolution: { employee_id: nadine.id } })
    end
    names = AuditLogPresenter.preload_employee_names(logs)

    employee_queries = 0
    counter = ->(*, payload) { employee_queries += 1 if payload[:sql].include?('FROM "employees"') }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      headlines = logs.map { |entry| AuditLogPresenter.new(entry, employee_names: names).headline }
      expect(headlines.uniq).to eq([ "Dana Admin marked Nadine Robles Not paid this period" ])
    end
    expect(employee_queries).to eq(0)
  end

  describe "rows written by real requests" do
    before { ensure_verified_test_tax_years(2026) }

    it "tags payroll row changes with the run and the employee" do
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      owner = create(:employee, :salary, company: company, first_name: "Leilani", last_name: "Reyes", salary_type: "variable", pay_rate: 0)
      PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay", label: "Lani's pay", required: true)
      owner_item = create(:payroll_item, pay_period: pay_period, employee: owner, employment_type: owner.employment_type)
      avery_item = create(:payroll_item, pay_period: pay_period, employee: avery)

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{owner_item.id}",
        params: { payroll_item: { salary_override: 8807.50 } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      delete "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{avery_item.id}", as: :json
      expect(response).to have_http_status(:no_content), response.body

      saved = AuditLog.find_by!(action: "payroll_items#update")
      expect(saved.metadata).to include("pay_period_id" => pay_period.id, "employee_name" => "Leilani Reyes", "owner_pay" => true)
      expect(saved.metadata.dig("after_values", "salary_override").to_d).to eq(8807.50.to_d)
      removed = AuditLog.find_by!(action: "payroll_items#destroy")
      expect(removed.subject_name).to eq("Avery Monroe")

      actions = headlines.values
      expect(actions).to include("Dana Admin saved owner pay for Leilani Reyes: $8,807.50", "Dana Admin removed Avery Monroe from this run")
    end

    it "requires a reason before changing final FIT withholding" do
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      item = create(:payroll_item, pay_period: pay_period, employee: avery)
      path = "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{item.id}"

      [ nil, "short" ].each do |reason|
        patch path, params: { fit_override_reason: reason, payroll_item: { withholding_tax_override: 25 } }, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(item.reload.withholding_tax_override).to be_nil
      end
    end

    it "keeps the detail of edits to fields outside hours and pay" do
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      item = create(:payroll_item, pay_period: pay_period, employee: avery, check_memo: nil)

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{item.id}",
        params: { fit_override_reason: "Fixture withholding correction", payroll_item: { check_memo: "Final check", withholding_tax_override: 25 } }, as: :json

      expect(response).to have_http_status(:ok), response.body
      override = AuditLog.find_by!(action: "payroll_item#fit_override")
      expect(override.subject_name).to eq(avery.full_name)
      expect(override.metadata).to include("reason" => "Fixture withholding correction",
        "employee_id" => avery.id, "employee_name" => avery.full_name)
      metadata = AuditLog.find_by!(action: "payroll_items#update").metadata
      expect(metadata.fetch("changed_fields")).to include("check_memo", "withholding_tax_override")
      expect(metadata.dig("after_values", "check_memo")).to eq("Final check")
      expect(metadata.dig("before_values", "check_memo")).to be_nil
    end

    it "does not mark job hours or payroll fields changed when they were sent unchanged" do
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      item = create(:payroll_item, pay_period: pay_period, employee: avery)

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{item.id}",
        params: { payroll_item: { check_memo: "Memo only", payroll_field_entries: [] } }, as: :json

      expect(response).to have_http_status(:ok), response.body
      changed = AuditLog.find_by!(action: "payroll_items#update").metadata.fetch("changed_fields")
      expect(changed).to include("check_memo")
      expect(changed).not_to include("payroll_field_entries", "wage_rate_hours")
    end

    it "marks payroll field entries changed when only an entry's notes change" do
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      item = create(:payroll_item, pay_period: pay_period, employee: avery)
      field = PayrollFieldDefinition.create!(company: company, name: "Loan", kind: "deduction",
        tax_treatment: "post_tax_deduction", category: "loan")
      entry = item.payroll_item_field_entries.create!(payroll_field_definition: field, label: "Loan", kind: "deduction",
        tax_treatment: "post_tax_deduction", category: "loan", amount: 10, source: "manual", notes: "Week one")

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{item.id}", params: { payroll_item: {
        payroll_field_entries: [ { id: entry.id, payroll_field_definition_id: field.id, label: "Loan", kind: "deduction",
          tax_treatment: "post_tax_deduction", category: "loan", amount: 10, source: "manual", notes: "Week two", active: true } ]
      } }, as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(entry.reload.notes).to eq("Week two")
      expect(AuditLog.find_by!(action: "payroll_items#update").metadata.fetch("changed_fields")).to include("payroll_field_entries")
    end

    context "with a manual loan entry carrying request intent" do
      let!(:item) { create(:payroll_item, pay_period: pay_period, employee: avery) }
      let!(:field) do
        PayrollFieldDefinition.create!(company: company, name: "Loan", kind: "deduction",
          tax_treatment: "post_tax_deduction", category: "loan")
      end
      let!(:entry) do
        item.payroll_item_field_entries.create!(payroll_field_definition: field, label: "Loan", kind: "deduction",
          tax_treatment: "post_tax_deduction", category: "loan", amount: 10, source: "manual", notes: "Advance",
          metadata: { "loan_requested_amount" => "50.0" })
      end

      def send_entry(extra = {})
        stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
        patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{item.id}", params: { payroll_item: {
          payroll_field_entries: [ { id: entry.id, payroll_field_definition_id: field.id, label: "Loan", kind: "deduction",
            tax_treatment: "post_tax_deduction", category: "loan", amount: 10, source: "manual", notes: "Advance",
            active: true }.merge(extra) ]
        } }, as: :json
        expect(response).to have_http_status(:ok), response.body
        AuditLog.where(action: "payroll_items#update").last.metadata.fetch("changed_fields")
      end

      it "marks payroll field entries changed when a replace request only clears the loan request" do
        changed = send_entry(replace_request: true)

        remaining = item.reload.payroll_item_field_entries.active.sole
        expect(remaining.metadata.to_h).not_to have_key("loan_requested_amount")
        expect(remaining.attributes.slice("label", "amount", "notes", "source")).to eq(entry.attributes.slice("label", "amount", "notes", "source"))
        expect(changed).to include("payroll_field_entries")
      end

      it "does not mark an unchanged entry that is sent back as is" do
        changed = send_entry

        expect(item.reload.payroll_item_field_entries.active.sole.metadata.to_h).to include("loan_requested_amount" => "50.0")
        expect(changed).not_to include("payroll_field_entries")
      end
    end

    it "records text and list fields entered when a row is added" do
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      pay_period.update!(status: "draft")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items",
        params: { employee_id: nadine.id, payroll_item: { hours_worked: 8, check_memo: "Training day",
          custom_earnings: [ { label: "Meal", amount: 12.5 } ] } }, as: :json

      expect(response).to have_http_status(:created), response.body
      metadata = AuditLog.find_by!(action: "payroll_items#create").metadata
      expect(metadata.fetch("changed_fields")).to include("check_memo", "employment_type", "custom_earnings", "hours_worked")
      expect(metadata.dig("after_values", "check_memo")).to eq("Training day")
      expect(metadata.dig("after_values", "employment_type")).to eq(nadine.employment_type)
      expect(metadata.fetch("changed_fields")).not_to include("bonus", "overtime_hours")
    end

    it "names the employee and note when someone is marked Not paid, and when it is undone" do
      stub_portal_user(Api::V1::Admin::PayrollEntryResolutionsController, staff, company)
      url = "/api/v1/admin/pay_periods/#{pay_period.id}/entry_resolutions"

      post url, params: { employee_id: nadine.id, note: "On leave until December" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      delete url, params: { employee_id: nadine.id }, as: :json
      expect(response).to have_http_status(:ok), response.body

      expect(headlines.values).to include(
        "Dana Admin marked Nadine Robles Not paid this period: “On leave until December”",
        "Dana Admin undid Not paid for Nadine Robles"
      )
    end

    it "does not record the report panel's saved-state summary as a report view" do
      stub_portal_user(Api::V1::Admin::ReportsController, staff, company)
      CheckSignoffSheet.create!(company: company, pay_period: pay_period, entries: [], notes: [], generated_at: Time.zone.parse("2026-11-16 09:00"))

      expect do
        get "/api/v1/admin/reports/saved_documents", params: { pay_period_id: pay_period.id }
      end.not_to change(AuditLog, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("transmittal" => nil)
      expect(response.parsed_body.dig("check_signoff", "generated_at")).to be_present
    end

    it "still records opening the transmittal editor as document access" do
      stub_portal_user(Api::V1::Admin::ReportsController, staff, company)

      expect do
        get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: pay_period.id }
      end.to change { AuditLog.where(action: "reports#transmittal_preview").count }.by(1)
    end

    it "refuses another client's run for the saved-state summary" do
      stub_portal_user(Api::V1::Admin::ReportsController, staff, other_company)

      get "/api/v1/admin/reports/saved_documents", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:not_found)
    end
  end
end
