# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Security client access & API hardening", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  describe "H1: client users never fall back to home company when assignments are empty" do
    let!(:organization) { create(:organization, name: "Firm Org") }
    let!(:home_company) { create(:company, organization: organization, name: "Firm Home Co") }
    let!(:assigned_company) { create(:company, organization: organization, name: "Client B Co") }
    let!(:home_employee) { create(:employee, company: home_company, first_name: "Home", last_name: "Worker") }
    let!(:assigned_employee) { create(:employee, company: assigned_company, first_name: "ClientB", last_name: "Worker") }
    let!(:admin_user) { create(:user, organization: organization, company: home_company, role: "admin", active: true) }
    let!(:client_user) { create(:user, organization: organization, company: home_company, role: "client", active: true) }
    let!(:assignment) { create(:company_assignment, user: client_user, company: assigned_company) }

    it "returns 403 on GET /api/v1/client/employees when the client's only assignment expires or is removed" do
      allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user_id).and_return(client_user.id)

      # Expire the sole assignment to B
      assignment.update!(expires_at: 1.minute.ago)
      client_user.reload

      expect(client_user.accessible_company_ids).to eq([])

      get "/api/v1/client/employees"
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("Home", "Worker")

      # Also verify after direct DB removal of the assignment
      assignment.delete
      client_user.reload
      expect(client_user.accessible_company_ids).to eq([])

      get "/api/v1/client/employees"
      expect(response).to have_http_status(:forbidden)
    end

    it "sets a new client user's company_id to their first assigned client company on create" do
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(admin_user.id)

      post "/api/v1/admin/users", params: {
        user: {
          email: "new-client-b@example.test",
          name: "New Client B",
          role: "client",
          company_ids: [ assigned_company.id ]
        }
      }

      expect(response).to have_http_status(:created), response.body
      created = User.find_by!(email: "new-client-b@example.test")
      expect(created.company_id).to eq(assigned_company.id)
      expect(created.accessible_company_ids).to eq([ assigned_company.id ])
    end

    it "refuses removing an active client's last assignment on PATCH /admin/users/:id unless deactivated in the same action" do
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(admin_user.id)

      patch "/api/v1/admin/users/#{client_user.id}", params: {
        user: { company_ids: [] }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(client_user.company_assignments.reload.pluck(:company_id)).to eq([ assigned_company.id ])

      patch "/api/v1/admin/users/#{client_user.id}", params: {
        user: { active: false, company_ids: [] }
      }

      expect(response).to have_http_status(:ok), response.body
      expect(client_user.reload.active?).to be(false)
      expect(client_user.company_assignments.reload).to be_empty
    end

    it "refuses deleting an active client's last assignment via DELETE /admin/company_assignments/:id" do
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user_id).and_return(admin_user.id)

      expect {
        delete "/api/v1/admin/company_assignments/#{assignment.id}"
      }.not_to change(CompanyAssignment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses emptying an active client's assignments via PUT /admin/company_assignments/bulk_update" do
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user_id).and_return(admin_user.id)

      put "/api/v1/admin/company_assignments/bulk_update", params: {
        user_id: client_user.id,
        company_ids: []
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(client_user.company_assignments.reload.pluck(:company_id)).to eq([ assigned_company.id ])
    end
  end

  describe "H2: employee bulk import SSN preview cache is encrypted, bound to company+user+preview_id, and deleted on cancel/apply" do
    let!(:organization) { create(:organization) }
    let!(:company_a) { create(:company, organization: organization) }
    let!(:company_b) { create(:company, organization: organization) }
    let!(:admin_a) { create(:user, organization: organization, company: company_a, role: "admin", active: true) }
    let!(:admin_b) { create(:user, organization: organization, company: company_a, role: "admin", active: true) }
    let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }
    let(:raw_ssn) { "123-45-6789" }
    let(:raw_ssn_digits) { "123456789" }

    before do
      allow(Rails).to receive(:cache).and_return(memory_store)
    end

    def csv_upload
      csv = <<~CSV
        first_name,last_name,email,ssn,date_of_birth,hire_date,employment_type,pay_rate,pay_frequency,filing_status,w4_effective_on,address_line1,city,state,zip
        Alex,Tester,alex.tester@example.test,#{raw_ssn},1990-01-15,2026-01-01,hourly,20.00,biweekly,single,2026-01-01,123 Main St,Hagatna,GU,96910
      CSV
      file = Tempfile.new([ "bulk_import", ".csv" ])
      file.write(csv)
      file.rewind
      Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: "employees.csv")
    end

    def stub_actor(user, company)
      allow_any_instance_of(Api::V1::Admin::EmployeeBulkImportsController).to receive(:current_user).and_return(user)
      allow_any_instance_of(Api::V1::Admin::EmployeeBulkImportsController).to receive(:current_user_id).and_return(user.id)
      allow_any_instance_of(Api::V1::Admin::EmployeeBulkImportsController).to receive(:current_company_id).and_return(company.id)
    end

    it "encrypts cached SSNs, rejects cross-user/cross-company apply, and deletes on cancel" do
      stub_actor(admin_a, company_a)

      post "/api/v1/admin/employee_bulk_imports/preview", params: { file: csv_upload }
      expect(response).to have_http_status(:ok), response.body

      body = response.parsed_body
      preview_id = body.fetch("preview_id")
      row_data = body.fetch("rows").first.fetch("data")
      expect(row_data["_ssn_token"]).to be_present

      # Cache must NOT store plaintext SSN or use an unbound key
      expect(memory_store.read("bulk_import_ssn:#{preview_id}")).to be_nil
      raw_entries = memory_store.instance_variable_get(:@data).values.map(&:value).inspect
      expect(raw_entries).not_to include(raw_ssn_digits)
      expect(raw_entries).not_to include(raw_ssn)

      # Another user in the same company cannot apply with admin_a's preview_id
      stub_actor(admin_b, company_a)
      post "/api/v1/admin/employee_bulk_imports/apply_json", params: {
        preview_id: preview_id,
        employees: [ row_data ]
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      # Same user switched to another company cannot apply with company_a's preview_id
      stub_actor(admin_a, company_b)
      post "/api/v1/admin/employee_bulk_imports/apply_json", params: {
        preview_id: preview_id,
        employees: [ row_data ]
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      # Cancel deletes the cached payload
      stub_actor(admin_a, company_a)
      delete "/api/v1/admin/employee_bulk_imports/preview/#{preview_id}"
      expect(response).to have_http_status(:no_content)

      post "/api/v1/admin/employee_bulk_imports/apply_json", params: {
        preview_id: preview_id,
        employees: [ row_data ]
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "applies successfully for the matching user and company and deletes cache afterward" do
      stub_actor(admin_a, company_a)

      post "/api/v1/admin/employee_bulk_imports/preview", params: { file: csv_upload }
      expect(response).to have_http_status(:ok)
      preview_id = response.parsed_body.fetch("preview_id")
      row_data = response.parsed_body.fetch("rows").first.fetch("data")

      post "/api/v1/admin/employee_bulk_imports/apply_json", params: {
        preview_id: preview_id,
        employees: [ row_data.compact ]
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("created")).to eq(1), response.body
      created_emp = company_a.employees.find_by!(email: "alex.tester@example.test")
      expect(created_emp.ssn_encrypted).to eq(raw_ssn_digits)

      # Reusing the same preview_id fails because cache entry was deleted after apply
      post "/api/v1/admin/employee_bulk_imports/apply_json", params: {
        preview_id: preview_id,
        employees: [ row_data.compact.merge("email" => "alex2@example.test") ]
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "M3: request log parameter filtering covers PII and pay fields" do
    it "filters phone, address, personal names, pay rates/amounts, emergency contact fields, and company EIN while leaving harmless params readable" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      input = {
        "phone" => "671-555-0199",
        "mobile_phone" => "671-555-0188",
        "address_line1" => "123 Marine Corps Dr",
        "address_line2" => "Suite 4B",
        "city" => "Hagatna",
        "zip" => "96910",
        "postal_code" => "96910",
        "first_name" => "Sample",
        "last_name" => "Worker",
        "middle_name" => "M",
        "name" => "Sample Worker",
        "pay_rate" => "25.50",
        "salary" => "65000",
        "amount" => "500.00",
        "hourly_rate" => "22.00",
        "gross_pay" => "1200.00",
        "net_pay" => "980.00",
        "emergency_contact_name" => "Pat Kin",
        "emergency_contact_phone" => "671-555-0100",
        "emergency_contact" => { "name" => "Pat Kin", "phone" => "671-555-0100", "relationship" => "Sibling" },
        "ein" => "98-7654321",
        "company_ein" => "98-7654321",
        "employee[phone]" => "671-555-0199",
        "employee%5Bpay_rate%5D" => "25.50",
        "company[ein]" => "98-7654321",
        "company_name" => "Example Bakery",
        "department_name" => "Kitchen",
        "status" => "active",
        "settings" => { "enabled" => true }
      }

      filtered = filter.filter(input)

      %w[
        phone mobile_phone address_line1 address_line2 city zip postal_code
        first_name last_name middle_name name pay_rate salary amount hourly_rate
        gross_pay net_pay emergency_contact_name emergency_contact_phone
        ein company_ein employee[phone] employee%5Bpay_rate%5D company[ein]
      ].each do |key|
        expect(filtered[key]).to eq("[FILTERED]"), "expected #{key} to be [FILTERED], got #{filtered[key].inspect}"
      end
      expect(filtered["emergency_contact"]).to eq("[FILTERED]")

      expect(filtered["company_name"]).to eq("Example Bakery")
      expect(filtered["department_name"]).to eq("Kitchen")
      expect(filtered["status"]).to eq("active")
      expect(filtered["settings"]).to eq("enabled" => true)
    end
  end

  describe "M1: employee link activation sends notice to email on file before change and shows printed code issuer" do
    let!(:organization) { create(:organization) }
    let!(:company) { create(:company, organization: organization, name: "Island Bakery", subdomain_slug: "island-bakery") }
    let!(:staff_user) { create(:user, organization: organization, company: company, role: "admin", name: "Pat Issuer", active: true) }
    let!(:other_staff) { create(:user, organization: organization, company: company, role: "admin", name: "Sam Reissuer", active: true) }
    let!(:employee) do
      create(:employee, company: company, first_name: "Chris", last_name: "Santos",
        email: "onfile.worker@example.test", date_of_birth: Date.new(1992, 4, 10), ssn_encrypted: "123456789")
    end

    before do
      company.client_operating_profiles.create!(
        effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service",
        hours_source: "manual", employee_portal_enabled: true, options: { subdomain_enabled: true }
      )
      activate_employee_app!(company)
      allow(PortalNotifications).to receive(:delivery_enabled?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:from_email).and_return("noreply@example.test")
    end

    it "emails the employee's email on file (before any change) on activation with Guam-time date" do
      sent_payloads = []
      allow(PortalNotifications::Transport).to receive(:deliver) do |payload, **_opts|
        sent_payloads << payload
        { "id" => "msg_123" }
      end

      pending_user = create(:user, organization: organization, company: company, role: "portal_employee",
        email: "new.signup@example.test", invitation_status: "pending", active: true, clerk_id: "pending_123")
      link = EmployeeAccountLink.create!(
        company: company, employee: employee, user: pending_user, invited_by: staff_user,
        status: "invited", invite_delivery: "code", invite_expires_at: 14.days.from_now,
        invite_generation: 1, sign_up_email_for_notices: true
      )
      request_double = instance_double(ActionDispatch::Request, remote_ip: "127.0.0.1", user_agent: "RSpec", request_id: "req-1")

      # 2026-11-26 20:00 UTC is 2026-11-27 06:00 Pacific/Guam (+10)
      travel_to Time.utc(2026, 11, 26, 20, 0, 0) do
        EmployeeLinks::Bind.activate!(
          link, pending_user, request: request_double,
          identity: { primary_email: "new.signup@example.test", primary_verified: true, verification_strategies: {} }
        )
      end

      expect(employee.reload.email).to eq("new.signup@example.test")
      expect(sent_payloads.size).to eq(1)
      payload = sent_payloads.first
      expect(payload[:to]).to eq("onfile.worker@example.test")
      expect(payload[:text]).to include("Your Island Bakery employee app account was set up on November 27, 2026")
      expect(payload[:text]).to include("If this wasn't you, contact Island Bakery/Cornerstone.")
    end

    it "respects DemoOutbound allowlist for activation notices on demo companies" do
      allow(DemoOutbound).to receive(:allowlist).and_return(Set["allowed@example.test", "allowed2@example.test"])
      demo_company = create_demo_company(organization: organization, name: "Demo Bakery")
      demo_emp = create(:employee, company: demo_company, email: "blocked.worker@example.test")
      pending_user = create(:user, organization: organization, company: demo_company, role: "portal_employee",
        email: "allowed@example.test", invitation_status: "pending", active: true, clerk_id: "pending_demo")
      link = EmployeeAccountLink.create!(
        company: demo_company, employee: demo_emp, user: pending_user, invited_by: staff_user,
        status: "invited", invite_delivery: "code", invite_expires_at: 14.days.from_now, invite_generation: 1
      )
      request_double = instance_double(ActionDispatch::Request, remote_ip: "127.0.0.1", user_agent: "RSpec", request_id: "req-2")

      sent = []
      allow(PortalNotifications::Transport).to receive(:deliver) { |payload, **| sent << payload; { "id" => "msg_demo" } }

      EmployeeLinks::Bind.activate!(
        link, pending_user, request: request_double,
        identity: { primary_email: "allowed@example.test", primary_verified: true, verification_strategies: {} }
      )
      expect(sent).to be_empty

      # And an allowlisted email on file DOES receive the notice when the demo employee app is open
      allowed_emp = create(:employee, company: demo_company, email: "allowed2@example.test")
      pending_user2 = create(:user, organization: organization, company: demo_company, role: "portal_employee",
        email: "allowed2@example.test", invitation_status: "pending", active: true, clerk_id: "pending_demo_2")
      link2 = EmployeeAccountLink.create!(
        company: demo_company, employee: allowed_emp, user: pending_user2, invited_by: staff_user,
        status: "invited", invite_delivery: "code", invite_expires_at: 14.days.from_now, invite_generation: 1
      )
      allow(DemoOutbound).to receive(:employee_app_open?).with(demo_company).and_return(true)

      EmployeeLinks::Bind.activate!(
        link2, pending_user2, request: request_double,
        identity: { primary_email: "allowed2@example.test", primary_verified: true, verification_strategies: {} }
      )
      expect(sent.size).to eq(1)
      expect(sent.first[:to]).to eq("allowed2@example.test")
    end

    it "records who issued a resent printed code and exposes invited_by_name and activated_at to staff" do
      link = EmployeeAccountLink.create!(
        company: company, employee: employee, invited_by: staff_user,
        status: "invited", invite_delivery: "email", invite_email: employee.email,
        invite_expires_at: 14.days.from_now, invite_generation: 1
      )

      EmployeeLinks::Resend.call(link: link, actor: other_staff, delivery: "code")
      expect(link.reload.invited_by_id).to eq(other_staff.id)

      link.update!(status: "active", user: create(:user, organization: organization, company: company, role: "portal_employee"),
        activated_at: Time.utc(2026, 11, 26, 10, 0, 0))

      allow_any_instance_of(Api::V1::Admin::EmployeeAppRolloutsController).to receive(:current_user).and_return(staff_user)
      allow_any_instance_of(Api::V1::Admin::EmployeeAppRolloutsController).to receive(:current_user_id).and_return(staff_user.id)
      allow_any_instance_of(Api::V1::Admin::EmployeeAppRolloutsController).to receive(:current_company_id).and_return(company.id)

      get "/api/v1/admin/employees/#{employee.id}/employee_app"
      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body.fetch("data")
      expect(data["activated_at"]).to be_present
      expect(data["invited_by_name"]).to eq("Sam Reissuer")
    end
  end

  describe "Low 1: client cannot delete their own upload after staff hides it" do
    let!(:company) { create(:company) }
    let!(:client_user) { create(:user, company: company, role: "client", active: true) }
    let!(:assignment) { create(:company_assignment, user: client_user, company: company) }

    it "returns 404 when a client tries to delete a hidden document they uploaded" do
      hidden_doc = create(:client_document, company: company, uploaded_by: client_user, visible_to_client: false)
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user_id).and_return(client_user.id)
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_company_id).and_return(company.id)

      expect {
        delete "/api/v1/client/documents/#{hidden_doc.id}"
      }.not_to change(ClientDocument, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Low 2: clients cannot rename staff-created threads" do
    let!(:company) { create(:company) }
    let!(:client_user) { create(:user, company: company, role: "client", active: true) }
    let!(:staff_user) { create(:user, company: company, role: "accountant", active: true) }
    let!(:assignment) { create(:company_assignment, user: client_user, company: company) }

    before do
      allow_any_instance_of(Api::V1::Client::PortalThreadsController).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(Api::V1::Client::PortalThreadsController).to receive(:current_user_id).and_return(client_user.id)
      allow_any_instance_of(Api::V1::Client::PortalThreadsController).to receive(:current_company_id).and_return(company.id)
      allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
    end

    it "forbids a client from renaming a thread created by staff" do
      staff_thread = create(:client_portal_thread, company: company, created_by: staff_user, subject: "Staff Topic")

      patch "/api/v1/client/portal_threads/#{staff_thread.id}", params: { subject: "Renamed by client" }

      expect(response).to have_http_status(:forbidden)
      expect(staff_thread.reload.subject).to eq("Staff Topic")
    end
  end

  describe "Low 3: generic error messages instead of raw exception messages" do
    let!(:company) { create(:company) }
    let!(:client_user) { create(:user, company: company, role: "client", active: true) }
    let!(:admin_user) { create(:user, company: company, role: "admin", active: true) }
    let!(:assignment) { create(:company_assignment, user: client_user, company: company) }

    it "does not leak raw ActiveRecord::RecordNotFound SQL/message on client payroll submission decision" do
      allow_any_instance_of(Api::V1::Client::PayrollSubmissionPeriodsController).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(Api::V1::Client::PayrollSubmissionPeriodsController).to receive(:current_user_id).and_return(client_user.id)
      allow_any_instance_of(Api::V1::Client::PayrollSubmissionPeriodsController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(Api::V1::Client::PayrollSubmissionPeriodsController).to receive(:set_period_entry)
      allow_any_instance_of(Api::V1::Client::PayrollSubmissionPeriodsController).to receive(:saved_period!)
        .and_raise(ActiveRecord::RecordNotFound, "Couldn't find PayrollSubmissionPeriod with 'id'=999 [WHERE \"company_id\" = 1]")

      post "/api/v1/client/payroll_submission_periods/999/decision", params: { decision: "approve" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.fetch("error")).not_to include("WHERE", "PayrollSubmissionPeriod")
    end

    it "does not leak raw ActiveRecord::RecordNotFound message in PortalFileRequestActions" do
      allow_any_instance_of(Api::V1::Client::PortalFileRequestsController).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(Api::V1::Client::PortalFileRequestsController).to receive(:current_user_id).and_return(client_user.id)
      allow_any_instance_of(Api::V1::Client::PortalFileRequestsController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(Api::V1::Client::PortalFileRequestsController).to receive(:set_file_request)
      allow_any_instance_of(PortalFileRequests::Actions).to receive(:respond!)
        .and_raise(ActiveRecord::RecordNotFound, "Couldn't find ClientDocument with 'id'=777 [WHERE \"secret_col\" = 1]")

      post "/api/v1/client/portal_file_requests/123/respond"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.fetch("error")).not_to include("WHERE", "ClientDocument", "secret_col")
    end

    it "does not expose raw AWS S3 error messages in R2StorageService::UploadError" do
      service = R2StorageService.new
      allow(service).to receive(:configured?).and_return(true)
      fake_client = instance_double(Aws::S3::Client)
      allow(service).to receive(:client).and_return(fake_client)
      allow(fake_client).to receive(:put_object).and_raise(
        Aws::S3::Errors::ServiceError.new(nil, "Internal R2 bucket secret-bucket-123 access denied")
      )

      expect {
        service.upload("docs/test.pdf", "bytes")
      }.to raise_error(R2StorageService::UploadError) do |error|
        expect(error.message).not_to include("secret-bucket-123", "access denied")
      end
    end

    it "does not expose raw exception details in admin ChecksController#test_check_pdf" do
      allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:current_user_id).and_return(admin_user.id)
      allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(CheckGenerator).to receive(:generate).and_raise(RuntimeError, "internal prawn font path /var/secret/font.ttf")

      post "/api/v1/admin/companies/test_check_pdf", params: { sample_type: "payroll" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).not_to include("/var/secret/font.ttf")
    end
  end

  describe "Low 4: Rack::Attack.request_origin ignores client-supplied X-Origin" do
    it "uses only Origin and never falls back to X-Origin" do
      req_with_x_origin = Rack::Request.new("HTTP_X_ORIGIN" => "https://mosas.shimizu-technology.com")
      req_with_origin = Rack::Request.new(
        "HTTP_ORIGIN" => "https://payroll.shimizu-technology.com",
        "HTTP_X_ORIGIN" => "https://mosas.shimizu-technology.com"
      )

      expect(Rack::Attack.request_origin(req_with_x_origin)).to be_nil
      expect(Rack::Attack.request_origin(req_with_origin)).to eq("https://payroll.shimizu-technology.com")
    end
  end

  describe "Low 5: /health/dependencies is throttled per IP while /up remains untouched" do
    it "throttles /health/dependencies after the per-IP limit without throttling /up" do
      previously_enabled = Rack::Attack.enabled
      Rack::Attack.enabled = true
      report = instance_double(DependencyHealth::Report, ready?: true, as_json: { status: "ok" })
      allow(DependencyHealth).to receive(:new).and_return(instance_double(DependencyHealth, run: report))

      expect(Rack::Attack.throttles).to have_key("health_dependencies/ip")
      limit = Rack::Attack.throttles.fetch("health_dependencies/ip").limit
      address = { "REMOTE_ADDR" => "203.0.113.99" }

      freeze_time do
        limit.times do
          get "/health/dependencies", env: address
          expect(response).to have_http_status(:ok)
        end

        get "/health/dependencies", env: address
        expect(response).to have_http_status(:too_many_requests)

        get "/up", env: address
        expect(response).to have_http_status(:ok)
      end
    ensure
      Rack::Attack.enabled = previously_enabled
    end
  end

  describe "Low 6: employee_web does not grant staff origin credentialed CORS" do
    let(:staff_origin) { "https://payroll.shimizu-technology.com" }

    it "omits Access-Control-Allow-Origin and credentials for staff origin on employee_web" do
      stub_const("PayrollCors::STATIC_ORIGINS", [ staff_origin ])
      allow(ProcessRole).to receive(:current).and_return(ProcessRole::EMPLOYEE_WEB)

      %w[/api/v1/auth/me /api/v1/employee/context /health/dependencies].each do |path|
        options path, headers: { "Origin" => staff_origin, "Access-Control-Request-Method" => "GET" }
        expect(response.headers["Access-Control-Allow-Origin"]).to be_nil, "expected no CORS on #{path}"
        expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil
      end
    end
  end
end
