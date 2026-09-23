require "rails_helper"
require "csv"

RSpec.describe "Api::V1::Admin::AuditLogs", type: :request do
  let!(:organization) { create(:organization, name: "Audit Firm") }
  let!(:company) { create(:company, organization: organization, name: "Audit Client") }
  let!(:admin) { create(:user, organization: organization, company: company, role: :admin, name: "Audit Admin") }
  let!(:foreign_organization) { create(:organization, name: "Other Firm") }
  let!(:foreign_company) { create(:company, organization: foreign_organization) }
  let!(:foreign_admin) { create(:user, organization: foreign_organization, company: foreign_company, role: :admin) }

  before do
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user_id).and_return(admin.id)
  end

  it "returns complete paginated organization history without leaking other organizations" do
    second_company = create(:company, organization: organization, name: "Second Audit Client")
    3.times do |index|
      AuditLog.record!(
        user: admin,
        organization_id: organization.id,
        company_id: index.zero? ? second_company.id : company.id,
        action: "users#updated",
        record_type: "users",
        record_id: index + 1
      )
    end
    AuditLog.record!(user: foreign_admin, organization_id: foreign_organization.id, action: "users#updated", record_type: "users")

    get "/api/v1/admin/audit_logs", params: { page: 2, per_page: 2, sort_direction: "asc" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").length).to eq(1)
    expect(response.parsed_body.fetch("meta")).to include("current_page" => 2, "per_page" => 2, "total_count" => 3, "total_pages" => 2)
    expect(response.parsed_body.fetch("data").pluck("organization_id")).to all(eq(organization.id))

    get "/api/v1/admin/audit_logs", headers: { "X-Company-Id" => company.id.to_s }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("company_id")).to include(company.id, second_company.id)
  end

  it "returns plain-English activity and affected-record labels" do
    log = AuditLog.record!(
      user: admin,
      organization_id: organization.id,
      company_id: company.id,
      action: "employees#destroy",
      record_type: "employees",
      record_id: 106,
      subject_name: "Ada Payroll"
    )

    get "/api/v1/admin/audit_logs", params: { record_id: log.record_id, record_type: "employees" }

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch("data").first
    expect(payload).to include(
      "display_action" => "Audit Admin terminated Ada Payroll",
      "display_subject" => "Ada Payroll",
      "summary" => "Audit Admin terminated Ada Payroll · Audit Client"
    )
  end

  it "presents legacy pay-period and report activity without mechanical fallback labels" do
    pay_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 9, 15),
      pay_date: Date.new(2026, 9, 18)
    )
    payroll_log = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "pay_periods#commit",
      record_type: "pay_periods",
      record_id: pay_period.id,
      subject_name: nil
    )
    report_log = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "reports#payroll_register_pdf",
      event_category: "export",
      record_type: "reports",
      subject_name: nil
    )

    expect(AuditLogPresenter.new(payroll_log).headline).to eq(
      "Audit Admin processed payroll for Sep 1, 2026 – Sep 15, 2026"
    )
    expect(AuditLogPresenter.new(report_log).headline).to eq(
      "Audit Admin downloaded the payroll register"
    )
    expect(AuditLogPresenter.new(report_log).subject).to eq("Payroll Register")
  end

  it "preloads legacy pay-period subjects for a page in one query" do
    pay_periods = 2.times.map do |index|
      create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 8, 1) + index.weeks,
        end_date: Date.new(2026, 8, 7) + index.weeks,
        pay_date: Date.new(2026, 8, 10) + index.weeks
      )
    end
    pay_periods.each do |pay_period|
      create(
        :audit_log,
        user: admin,
        organization: organization,
        company: company,
        action: "pay_periods#commit",
        record_type: "pay_periods",
        record_id: pay_period.id,
        subject_name: nil
      )
    end

    expect(PayPeriod).to receive(:where).once.and_call_original

    get "/api/v1/admin/audit_logs", params: { action_filter: "pay_periods#commit" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("display_subject")).to match_array(
      pay_periods.map { |pay_period| AuditRecordSnapshot.subject_name(pay_period) }
    )
  end

  it "preloads legacy pay-period subjects once per CSV batch" do
    pay_periods = 2.times.map do |index|
      create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 7, 1) + index.weeks,
        end_date: Date.new(2026, 7, 7) + index.weeks,
        pay_date: Date.new(2026, 7, 10) + index.weeks
      )
    end
    pay_periods.each do |pay_period|
      create(
        :audit_log,
        user: admin,
        organization: organization,
        company: company,
        action: "pay_periods#commit",
        record_type: "pay_periods",
        record_id: pay_period.id,
        subject_name: nil
      )
    end

    expect(PayPeriod).to receive(:where).once.and_call_original

    get "/api/v1/admin/audit_logs/export", params: { action_filter: "pay_periods#commit" }

    expect(response).to have_http_status(:ok)
    affected_records = CSV.parse(response.body, headers: true).map { |row| row.fetch("Affected record") }
    expect(affected_records).to match_array(
      pay_periods.map { |pay_period| AuditRecordSnapshot.subject_name(pay_period) }
    )
  end

  it "does not describe report workflow mutations as document access" do
    workflow_log = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "reports#update_quarterly_compliance_packet_task",
      event_category: "activity",
      record_type: "reports",
      record_id: 123
    )

    presenter = AuditLogPresenter.new(workflow_log)
    expect(presenter.headline).to eq("Audit Admin update quarterly compliance packet task report record")
    expect(presenter.headline).not_to include("accessed")
  end

  it "filters a user's successful sign-ins by exact security event" do
    signed_in = create(
      :audit_log,
      user: admin,
      organization: organization,
      action: "authentication#signed_in",
      event_category: "security",
      record_type: "users",
      record_id: admin.id,
      ip_address: "192.0.2.15",
      user_agent: "Mozilla/5.0 Test Browser"
    )
    create(
      :audit_log,
      user: admin,
      organization: organization,
      action: "authentication#signed_in_from_link",
      event_category: "security",
      record_type: "users",
      record_id: admin.id
    )
    create(:audit_log, user: admin, organization: organization, action: "users#updated", record_type: "users")
    create(
      :audit_log,
      user: foreign_admin,
      organization: foreign_organization,
      action: "authentication#signed_in",
      event_category: "security",
      record_type: "users",
      record_id: foreign_admin.id
    )

    get "/api/v1/admin/audit_logs", params: {
      user_id: admin.id,
      event_action: "authentication#signed_in",
      event_category: "security"
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ signed_in.id ])
    expect(response.parsed_body.fetch("data").first).to include(
      "ip_address" => "192.0.2.15",
      "user_agent" => "Mozilla/5.0 Test Browser",
      "event_category" => "security"
    )

    get "/api/v1/admin/audit_logs/export", params: {
      user_id: admin.id,
      event_action: "authentication#signed_in",
      event_category: "security"
    }

    expect(response).to have_http_status(:ok)
    exported_rows = CSV.parse(response.body, headers: true)
    expect(exported_rows.length).to eq(1)
    expect(exported_rows.first.to_h).to include(
      "Technical action" => "authentication#signed_in",
      "Category" => "security",
      "IP address" => "192.0.2.15"
    )
  end

  it "filters listing and export by a query-only client selector" do
    second_company = create(:company, organization: organization, name: "Selected Audit Client")
    selected_log = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: second_company,
      action: "employees#updated",
      record_type: "employees",
      subject_name: "Selected employee"
    )
    create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "employees#updated",
      record_type: "employees",
      subject_name: "Excluded employee"
    )

    get "/api/v1/admin/audit_logs", params: { company_id: second_company.id }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json.fetch("data").pluck("id")).to eq([ selected_log.id ])

    get "/api/v1/admin/audit_logs/export", params: { company_id: second_company.id }

    expect(response).to have_http_status(:ok)
    exported_subjects = CSV.parse(response.body, headers: true).map { |row| row.fetch("Affected record") }
    expect(exported_subjects).to include("Selected employee")
    expect(exported_subjects).not_to include("Excluded employee")
  end

  it "can separate document access from higher-signal activity without deleting evidence" do
    activity = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "employees#updated",
      event_category: "activity",
      record_type: "employees"
    )
    document_access = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "reports#payroll_register_pdf",
      event_category: "export",
      record_type: "reports"
    )
    check_print_generation = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "check_print_runs#generated",
      event_category: "export",
      record_type: "check_print_runs"
    )

    get "/api/v1/admin/audit_logs", params: { exclude_event_category: "document_access" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to include(activity.id)
    expect(response.parsed_body.fetch("data").pluck("id")).to include(check_print_generation.id)
    expect(response.parsed_body.fetch("data").pluck("id")).not_to include(document_access.id)

    get "/api/v1/admin/audit_logs", params: { event_category: "document_access" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to include(document_access.id)
    expect(response.parsed_body.fetch("data").pluck("id")).not_to include(activity.id)
    expect(response.parsed_body.fetch("data").pluck("id")).not_to include(check_print_generation.id)
  end

  it "gives accountants history for only the selected client" do
    accountant = create(:user, organization: organization, company: company, role: :accountant)
    second_company = create(:company, organization: organization, name: "Second Audit Client")
    second_actor = create(:user, organization: organization, company: second_company, role: :manager, name: "Second actor")
    unassigned_company = create(:company, organization: organization, name: "Unassigned Audit Client")
    create(:company_assignment, user: accountant, company: company)
    create(:company_assignment, user: accountant, company: second_company)
    selected_log = create(:audit_log, user: admin, organization: organization, company: company, action: "employees#updated", record_type: "employees", subject_name: "Selected client employee")
    create(:audit_log, user: admin, organization: organization, company: second_company, action: "employees#updated", record_type: "employees", subject_name: "Other client employee")
    create(:audit_log, user: second_actor, organization: organization, company: second_company, action: "employees#updated", record_type: "employees", subject_name: "Second actor employee")
    create(:audit_log, user: admin, organization: organization, company: unassigned_company, action: "employees#updated", record_type: "employees", subject_name: "Unassigned client employee")
    create(:audit_log, user: admin, organization: organization, company: nil, action: "users#updated", record_type: "users", subject_name: "Organization user")
    create(:audit_log, user: foreign_admin, organization: foreign_organization, company: foreign_company, action: "users#updated", record_type: "users", subject_name: "Foreign user")
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user_id).and_return(accountant.id)

    get "/api/v1/admin/audit_logs", params: { company_id: second_company.id, user_id: admin.id }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    returned_logs = json.fetch("data")
    expect(returned_logs.pluck("id")).not_to include(selected_log.id)
    expect(returned_logs.pluck("company_id")).to all(eq(second_company.id))
    expect(returned_logs.pluck("subject_name")).to include("Other client employee", "Second actor employee")

    get "/api/v1/admin/audit_logs/export", params: { company_id: second_company.id, user_id: admin.id }

    expect(response).to have_http_status(:ok)
    exported_subjects = CSV.parse(response.body, headers: true).map { |row| row.fetch("Affected record") }
    expect(exported_subjects).to include("Other client employee", "Second actor employee")
    expect(exported_subjects).not_to include("Selected client employee", "Unassigned client employee", "Organization user", "Foreign user")

    get "/api/v1/admin/audit_logs", headers: { "X-Company-Id" => second_company.id.to_s }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json.fetch("data").pluck("company_id")).to all(eq(second_company.id))
    expect(json.fetch("data").pluck("subject_name")).to include("Other client employee", "Second actor employee")
    expect(json.fetch("data").pluck("subject_name")).not_to include(
      "Selected client employee",
      "Unassigned client employee",
      "Organization user",
      "Foreign user"
    )

    get "/api/v1/admin/audit_logs/export", headers: { "X-Company-Id" => second_company.id.to_s }

    expect(response).to have_http_status(:ok)
    header_exported_subjects = CSV.parse(response.body, headers: true).map { |row| row.fetch("Affected record") }
    expect(header_exported_subjects).to include("Other client employee", "Second actor employee")
    expect(header_exported_subjects).not_to include(
      "Selected client employee",
      "Unassigned client employee",
      "Organization user",
      "Foreign user"
    )

    get "/api/v1/admin/audit_logs", headers: { "X-Company-Id" => unassigned_company.id.to_s }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json.fetch("data").pluck("id")).to include(selected_log.id)
    expect(json.fetch("data").pluck("company_id")).to all(eq(company.id))

    get "/api/v1/admin/audit_logs/export", headers: { "X-Company-Id" => unassigned_company.id.to_s }

    expect(response).to have_http_status(:ok)
    fallback_exported_subjects = CSV.parse(response.body, headers: true).map { |row| row.fetch("Affected record") }
    expect(fallback_exported_subjects).to include("Selected client employee")
    expect(fallback_exported_subjects).not_to include(
      "Other client employee",
      "Second actor employee",
      "Unassigned client employee",
      "Organization user",
      "Foreign user"
    )

    get "/api/v1/admin/audit_logs", params: { company_id: second_company.id }, headers: { "X-Company-Id" => company.id.to_s }

    expect(response).to have_http_status(:forbidden)
    json = JSON.parse(response.body)
    expect(json.fetch("error")).to eq("Not authorized")
    expect(json.fetch("details")).to eq("authorization" => [ "Not authorized" ])
  end

  it "keeps security history and its technical telemetry restricted to organization admins" do
    accountant = create(:user, organization: organization, company: company, role: :accountant)
    create(:company_assignment, user: accountant, company: company)
    security_log = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "authentication#signed_in",
      event_category: "security",
      record_type: "users",
      record_id: admin.id,
      ip_address: "192.0.2.15",
      user_agent: "Sensitive browser signature"
    )
    ordinary_log = create(
      :audit_log,
      user: admin,
      organization: organization,
      company: company,
      action: "employees#updated",
      event_category: "data_change",
      record_type: "employees",
      subject_name: "Visible employee update"
    )
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user_id).and_return(accountant.id)

    get "/api/v1/admin/audit_logs", params: { company_id: company.id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to include(ordinary_log.id)
    expect(response.parsed_body.fetch("data").pluck("id")).not_to include(security_log.id)

    get "/api/v1/admin/audit_logs", params: { company_id: company.id, action_filter: "authentication#" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to be_empty

    get "/api/v1/admin/audit_logs/export", params: { company_id: company.id }

    expect(response).to have_http_status(:ok)
    unfiltered_export = CSV.parse(response.body, headers: true)
    expect(unfiltered_export.map { |row| row.fetch("Technical action") }).to include("employees#updated")
    expect(unfiltered_export.map { |row| row.fetch("Technical action") }).not_to include("authentication#signed_in")
    expect(unfiltered_export.map { |row| row.fetch("IP address") }).not_to include("192.0.2.15")

    get "/api/v1/admin/audit_logs/export", params: { company_id: company.id, action_filter: "authentication#" }

    expect(response).to have_http_status(:ok)
    expect(CSV.parse(response.body, headers: true)).to be_empty

    security_params = {
      user_id: admin.id,
      event_action: "authentication#signed_in",
      event_category: "security"
    }

    get "/api/v1/admin/audit_logs", params: security_params

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq(
      "error" => "Organization admin access required for security history",
      "details" => { "authorization" => [ "Organization admin access required for security history" ] }
    )

    get "/api/v1/admin/audit_logs/export", params: security_params

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Organization admin access required for security history")
  end

  it "keeps activity history unavailable to managers" do
    manager = create(:user, organization: organization, company: company, role: :manager)
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user).and_return(manager)
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user_id).and_return(manager.id)

    get "/api/v1/admin/audit_logs"

    expect(response).to have_http_status(:forbidden)
    json = JSON.parse(response.body)
    expect(json.fetch("error")).to eq("Admin or accountant access required")
  end

  it "exports filtered history as CSV and records the export" do
    AuditLog.record!(user: admin, organization_id: organization.id, action: "users#updated", record_type: "users", record_id: admin.id)

    # One populated batch plus one empty sentinel batch. If Auditable reads
    # response.body, the streaming Enumerator is consumed twice (four calls).
    expect_any_instance_of(Api::V1::Admin::AuditLogsController)
      .to receive(:export_batch).twice.and_call_original

    expect {
      get "/api/v1/admin/audit_logs/export", params: { record_type: "users", record_id: admin.id }
    }.to change { AuditLog.where(action: "audit_logs#export").count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include("Audit Admin", "users#updated")
  end

  it "exports in the requested timestamp order and neutralizes spreadsheet formulas" do
    AuditLog.create!(
      user: admin,
      organization: organization,
      action: "users#created",
      record_type: "users",
      created_at: 1.day.ago
    )
    AuditLog.create!(
      user: admin,
      organization: organization,
      action: "users#updated",
      record_type: "users",
      subject_name: "=HYPERLINK(\"https://example.test\",\"open\")",
      created_at: 2.days.ago
    )

    get "/api/v1/admin/audit_logs/export", params: { sort_direction: "asc" }

    expect(response).to have_http_status(:ok)
    expect(response.body.index("users#updated")).to be < response.body.index("users#created")
    expect(response.body).to include("'=HYPERLINK")
    expect(response.body).not_to include(",=HYPERLINK")
  end
end
