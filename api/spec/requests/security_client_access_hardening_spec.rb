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

    it "omits home company metadata and features from /auth/me without a header once the client's last grant expires" do
      ClientOperatingProfile.create!(
        company: home_company,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_portals",
        hours_source: "manual",
        client_portal_enabled: true,
        employee_portal_enabled: true
      )
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      assignment.update!(expires_at: 1.minute.ago)
      client_user.reload

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("user")).to include(
        "company_id" => nil,
        "company_name" => nil,
        "home_company_id" => nil,
        "assigned_company_ids" => []
      )
      expect(response.parsed_body.fetch("features")).to be_nil
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

    it "refuses POST /admin/users/:id/activate when a deactivated client has no effective grant" do
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(admin_user.id)

      post "/api/v1/admin/users/#{client_user.id}/deactivate"
      expect(response).to have_http_status(:ok)

      assignment.destroy!
      post "/api/v1/admin/users/#{client_user.id}/activate"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("client_required")
      expect(client_user.reload.active?).to be(false)

      # Also refuse when the only remaining assignment is expired
      create(:company_assignment, user: client_user, company: assigned_company, expires_at: 1.minute.ago)
      post "/api/v1/admin/users/#{client_user.id}/activate"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(client_user.reload.active?).to be(false)
    end

    it "uses the same effective-grant predicate for demo client readiness on activate and assignment removal" do
      allow(DemoOutbound).to receive(:allowlist).and_return(Set["demo.client@example.test"])
      ready_demo = create_demo_company(organization: organization, name: "Ready Demo", fixture_key: "ready-demo")
      unready_demo = create_demo_company(organization: organization, name: "Unready Demo", fixture_key: "unready-demo")
      unready_demo.update!(migration_rehearsal_status: "failed")

      demo_client = create(:user, organization: organization, company: ready_demo, role: "client",
        email: "demo.client@example.test", active: true)
      ready_grant = create(:company_assignment, user: demo_client, company: ready_demo)
      create(:company_assignment, user: demo_client, company: unready_demo)

      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user_id).and_return(admin_user.id)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(admin_user.id)

      # Removing the only ready demo grant while leaving an unready demo grant must be refused
      delete "/api/v1/admin/company_assignments/#{ready_grant.id}"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(CompanyAssignment.exists?(ready_grant.id)).to be(true)

      # Deactivating, removing the ready grant, then attempting Activate must also be refused
      post "/api/v1/admin/users/#{demo_client.id}/deactivate"
      expect(response).to have_http_status(:ok)
      ready_grant.destroy!

      post "/api/v1/admin/users/#{demo_client.id}/activate"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(demo_client.reload.active?).to be(false)
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

    it "allows deleting expired, archived, or ineffective assignments while still blocking removal of the last effective grant" do
      archived_company = create(:company, organization: organization, name: "Archived Client Co",
        test_workspace_archived_at: 1.hour.ago)
      second_company = create(:company, organization: organization, name: "Expired Client Co")
      admin_user.reload

      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user_id).and_return(admin_user.id)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(admin_user.id)

      # 1. Deleting an already-expired last assignment removes no access and must succeed
      assignment.update!(expires_at: 1.minute.ago)
      expect {
        delete "/api/v1/admin/company_assignments/#{assignment.id}"
      }.to change(CompanyAssignment, :count).by(-1)
      expect(response).to have_http_status(:no_content)

      # 2. Deleting an archived company's last assignment via DELETE, bulk_update, or PATCH /users must succeed
      archived_grant = create(:company_assignment, user: client_user, company: archived_company)
      expect {
        delete "/api/v1/admin/company_assignments/#{archived_grant.id}"
      }.to change(CompanyAssignment, :count).by(-1)
      expect(response).to have_http_status(:no_content)

      expired_for_bulk = create(:company_assignment, user: client_user, company: assigned_company, expires_at: 1.minute.ago)
      put "/api/v1/admin/company_assignments/bulk_update", params: {
        user_id: client_user.id,
        company_ids: []
      }
      expect(response).to have_http_status(:ok), response.body
      expect(CompanyAssignment.exists?(expired_for_bulk.id)).to be(false)

      archived_for_user_patch = create(:company_assignment, user: client_user, company: archived_company)
      patch "/api/v1/admin/users/#{client_user.id}", params: {
        user: { company_ids: [] }
      }
      expect(response).to have_http_status(:ok), response.body
      expect(CompanyAssignment.exists?(archived_for_user_patch.id)).to be(false)

      # 3. Editing a non-assignment field (name) on an active client whose only grant already expired succeeds
      expired_for_name_edit = create(:company_assignment, user: client_user, company: assigned_company, expires_at: 1.minute.ago)
      patch "/api/v1/admin/users/#{client_user.id}", params: {
        user: { name: "Renamed Expired Client" }
      }
      expect(response).to have_http_status(:ok), response.body
      expect(client_user.reload.name).to eq("Renamed Expired Client")
      expired_for_name_edit.destroy!

      # 4. With one effective grant and one expired grant, deleting the expired grant succeeds
      #    while deleting the last effective grant is still blocked with 422.
      effective_grant = create(:company_assignment, user: client_user, company: assigned_company)
      expired_grant = create(:company_assignment, user: client_user, company: second_company, expires_at: 1.minute.ago)

      expect {
        delete "/api/v1/admin/company_assignments/#{expired_grant.id}"
      }.to change(CompanyAssignment, :count).by(-1)
      expect(response).to have_http_status(:no_content)

      expect {
        delete "/api/v1/admin/company_assignments/#{effective_grant.id}"
      }.not_to change(CompanyAssignment, :count)
      expect(response).to have_http_status(:unprocessable_entity)

      # 5. Activating an inactive client via PATCH /users/:id with only an expired grant is still refused
      client_user.update!(active: false)
      effective_grant.update!(expires_at: 1.minute.ago)
      patch "/api/v1/admin/users/#{client_user.id}", params: {
        user: { active: true }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(client_user.reload.active?).to be(false)
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

    it "rejects the entire batch before any write when any row has a stale or missing SSN token, even with incomplete intake enabled" do
      company_a.update!(
        employee_intake_expires_at: 1.hour.from_now,
        employee_intake_reason: "Testing incomplete intake"
      )
      stub_actor(admin_a, company_a)

      post "/api/v1/admin/employee_bulk_imports/preview", params: { file: csv_upload }
      expect(response).to have_http_status(:ok)
      preview_id = response.parsed_body.fetch("preview_id")
      valid_row = response.parsed_body.fetch("rows").first.fetch("data").compact
      stale_row = valid_row.merge(
        "first_name" => "Stale",
        "email" => "stale.worker@example.test",
        "_ssn_token" => "deadbeef" * 4
      )

      expect {
        post "/api/v1/admin/employee_bulk_imports/apply_json", params: {
          preview_id: preview_id,
          employees: [ valid_row, stale_row ]
        }, as: :json
      }.not_to change(Employee, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "purges legacy plaintext Solid Cache entries without touching v2 encrypted or unrelated keys" do
      conn = ActiveRecord::Base.connection
      conn.execute(<<~SQL)
        CREATE TEMP TABLE temp_solid_cache_entries (
          id bigserial PRIMARY KEY,
          key bytea NOT NULL,
          value bytea NOT NULL,
          created_at timestamp NOT NULL DEFAULT NOW(),
          key_hash bigint NOT NULL,
          byte_size integer NOT NULL DEFAULT 10
        )
      SQL

      entry_model = Class.new(ActiveRecord::Base) do
        self.table_name = "temp_solid_cache_entries"
      end

      insert_entry = lambda do |key_bytes, idx|
        entry_model.create!(
          key: key_bytes,
          value: "payload-#{idx}",
          key_hash: idx,
          byte_size: 16
        )
      end

      insert_entry.call("production:bulk_import_ssn:11111111-1111-1111-1111-111111111111", 1)
      insert_entry.call("bulk_import_ssn:22222222-2222-2222-2222-222222222222", 2)
      insert_entry.call("production:bulk_import_ssn:v2:1:2:33333333-3333-3333-3333-333333333333", 3)
      insert_entry.call("bulk_import_ssn:v2:1:2:44444444-4444-4444-4444-444444444444", 4)
      insert_entry.call("production:unrelated_key", 5)
      insert_entry.call("\xFF\xFE\x00\x01".b, 6)

      deleted_first = EmployeeBulkImport::SsnPreviewCache.purge_legacy_entries!(
        entry_class: entry_model,
        namespaces: [ "production" ]
      )
      expect(deleted_first).to eq(2)
      expect(entry_model.order(:key_hash).pluck(:key_hash)).to eq([ 3, 4, 5, 6 ])

      deleted_second = EmployeeBulkImport::SsnPreviewCache.purge_legacy_entries!(
        entry_class: entry_model,
        namespaces: [ "production" ]
      )
      expect(deleted_second).to eq(0)
    ensure
      conn.execute("DROP TABLE IF EXISTS temp_solid_cache_entries")
    end

    it "does not run a boot-time legacy SSN purge initializer and raises on SQL errors in the rake task" do
      expect(Rails.root.join("config/initializers/purge_legacy_ssn_preview_cache.rb")).not_to exist

      require "rake"
      Rails.application.load_tasks unless Rake::Task.task_defined?("bulk_import_ssn_cache:purge_legacy")
      task = Rake::Task["bulk_import_ssn_cache:purge_legacy"]

      broken_entry_class = Class.new do
        def self.table_exists?
          true
        end

        def self.where(*)
          raise ActiveRecord::StatementInvalid, "simulated solid_cache_entries SQL error"
        end
      end
      stub_const("SolidCache::Entry", broken_entry_class)

      task.reenable
      expect { task.invoke }.to raise_error(ActiveRecord::StatementInvalid, /simulated solid_cache_entries SQL error/)

      allow(EmployeeBulkImport::SsnPreviewCache).to receive(:purge_legacy_entries!).and_return(2)
      task.reenable
      expect { task.invoke }.to output("Purged 2 legacy bulk_import_ssn cache entries.\n").to_stdout
    end
  end

  describe "M3: request log parameter filtering covers PII and pay fields" do
    it "filters real PII/pay form fields while keeping non-PII debugging names, rates, and amounts readable" do
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
        "name" => "Pat Kin",
        "relationship" => "Sibling",
        "pay_rate" => "25.50",
        "salary" => "65000",
        "salary_override" => "2500.00",
        "reported_tips" => "140.25",
        "tips_paid_out" => "95.00",
        "service_charge_wages" => "88.00",
        "non_taxable_pay" => "50.00",
        "qualified_overtime_compensation" => "120.00",
        "hourly_rate" => "22.00",
        "gross_pay" => "1200.00",
        "net_pay" => "980.00",
        "employer_identification_number" => "98-7654321",
        "company_address_line1" => "456 Chalan San Antonio",
        "company_address_line2" => "Floor 2",
        "company_city" => "Tamuning",
        "company_state" => "GU",
        "company_zip" => "96913",
        "income_tax_withholding_on_wages" => "1234.56",
        "total_taxes_dollars" => "1234",
        "emergency_contact_name" => "Pat Kin",
        "emergency_contact_phone" => "671-555-0100",
        "emergency_contact" => { "name" => "Pat Kin", "phone" => "671-555-0100", "relationship" => "Sibling" },
        "user" => { "name" => "Jane Doe" },
        "employee_wage_rate" => { "rate" => "24.00", "label" => "Line Cook" },
        "payroll_item" => {
          "salary_override" => "2500.00",
          "reported_tips" => "140.25",
          "wage_rate_hours" => [ { "rate" => "25.00", "label" => "Regular" } ],
          "custom_earnings" => [ { "amount" => "300.00", "label" => "Allowance" } ]
        },
        "ein" => "98-7654321",
        "company_ein" => "98-7654321",
        "employee[phone]" => "671-555-0199",
        "employee%5Bpay_rate%5D" => "25.50",
        "company[ein]" => "98-7654321",
        "form_500[employer_identification_number]" => "98-7654321",
        "form_500[company_address_line1]" => "456 Chalan San Antonio",
        "payroll_item[salary_override]" => "2500.00",
        "payroll_item[reported_tips]" => "140.25",
        "department" => { "name" => "Kitchen" },
        "company" => { "name" => "Example Bakery" },
        "tax_config" => { "rate" => "0.062" },
        "invoice" => { "amount" => "100.00" },
        "company_name" => "Example Bakery",
        "department_name" => "Kitchen",
        "status" => "active",
        "settings" => { "enabled" => true }
      }

      filtered = filter.filter(input)

      %w[
        phone mobile_phone address_line1 address_line2 city zip postal_code
        first_name last_name middle_name name relationship pay_rate salary
        salary_override reported_tips tips_paid_out service_charge_wages
        non_taxable_pay qualified_overtime_compensation hourly_rate
        gross_pay net_pay employer_identification_number company_address_line1
        company_address_line2 company_city company_state company_zip
        income_tax_withholding_on_wages total_taxes_dollars
        emergency_contact_name emergency_contact_phone
        ein company_ein employee[phone] employee%5Bpay_rate%5D company[ein]
        form_500[employer_identification_number] form_500[company_address_line1]
        payroll_item[salary_override] payroll_item[reported_tips]
      ].each do |key|
        expect(filtered[key]).to eq("[FILTERED]"), "expected #{key} to be [FILTERED], got #{filtered[key].inspect}"
      end
      expect(filtered["emergency_contact"]).to eq("[FILTERED]")
      expect(filtered.dig("user", "name")).to eq("[FILTERED]")
      expect(filtered.dig("employee_wage_rate", "rate")).to eq("[FILTERED]")
      expect(filtered.dig("employee_wage_rate", "label")).to eq("Line Cook")
      expect(filtered.dig("payroll_item", "salary_override")).to eq("[FILTERED]")
      expect(filtered.dig("payroll_item", "reported_tips")).to eq("[FILTERED]")
      expect(filtered.dig("payroll_item", "wage_rate_hours", 0, "rate")).to eq("[FILTERED]")
      expect(filtered.dig("payroll_item", "custom_earnings", 0, "amount")).to eq("[FILTERED]")

      # Scoped name/rate/amount must not hide non-PII debugging fields
      expect(filtered.dig("department", "name")).to eq("Kitchen")
      expect(filtered.dig("company", "name")).to eq("Example Bakery")
      expect(filtered.dig("tax_config", "rate")).to eq("0.062")
      expect(filtered.dig("invoice", "amount")).to eq("100.00")
      expect(filtered["company_name"]).to eq("Example Bakery")
      expect(filtered["department_name"]).to eq("Kitchen")
      expect(filtered["status"]).to eq("active")
      expect(filtered["settings"]).to eq("enabled" => true)
    end

    it "filters parsed JSON bodies and query strings in real request logs for Form 500, payroll items, and emergency contacts" do
      company = create(:company)
      admin = create(:user, company: company, organization: company.organization, role: "admin")
      allow_any_instance_of(Api::V1::Form500sController).to receive(:current_user).and_return(admin)
      allow_any_instance_of(Api::V1::Form500sController).to receive(:current_company_id).and_return(company.id)

      reported = []
      callback = ->(*, payload) { reported << payload[:params] }
      ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") do
        post "/api/v1/form_500s/save",
          params: {
            pay_period_id: 999_999,
            form_500: {
              employer_identification_number: "98-1112222",
              company_address_line1: "777 Marine Corps Dr",
              income_tax_withholding_on_wages: "4321.00"
            },
            department: { name: "PayrollOps" }
          },
          as: :json
      end

      logged_params = reported.last
      expect(logged_params.dig("form_500", "employer_identification_number")).to eq("[FILTERED]")
      expect(logged_params.dig("form_500", "company_address_line1")).to eq("[FILTERED]")
      expect(logged_params.dig("form_500", "income_tax_withholding_on_wages")).to eq("[FILTERED]")
      expect(logged_params.dig("department", "name")).to eq("PayrollOps")

      # Query string filtering on ActionDispatch::Request#filtered_path
      env = Rails.application.env_config.merge(
        Rack::MockRequest.env_for(
          "/api/v1/employee/profile/emergency_contacts?name=Pat+Kin&relationship=Spouse&phone=671-555-0100" \
          "&payroll_item[salary_override]=2500&payroll_item%5Breported_tips%5D=140" \
          "&form_500[employer_identification_number]=98-1112222&form_500[company_address_line1]=777+Main" \
          "&department[name]=Kitchen&tax_config[rate]=0.062"
        )
      )
      filtered_path = ActionDispatch::Request.new(env).filtered_path
      expect(filtered_path).not_to include("Pat", "Kin", "Spouse", "671-555-0100", "2500", "140", "98-1112222", "777")
      expect(filtered_path).to include("department[name]=Kitchen", "tax_config[rate]=0.062")
    end

    it "masks bracketed array query keys and employee loan payment amounts in JSON bodies and real Rack query strings" do
      # 1. Real Rack query strings with bracketed [] and indexed [0] array keys (plain + URL-encoded)
      array_qs = "pay_rates[][amount]=25.50&items[0][rate]=22.75" \
                 "&payroll_item[wage_rate_hours][][rate]=24.50" \
                 "&payroll_item[custom_earnings][0][amount]=320.00" \
                 "&emergency_contacts[][name]=Pat+Kin" \
                 "&amount=175.50&employee_loan[amount]=185.50" \
                 "&named_loan_payments[42][7]=95.00&loan_deductions[42]=85.00" \
                 "&tax_config[rate]=0.062&invoice[amount]=100.00&department[name]=Kitchen"
      req_plain = ActionDispatch::Request.new(
        Rails.application.env_config.merge(Rack::MockRequest.env_for("/api/v1/admin/payroll_items?#{array_qs}"))
      )

      expect(req_plain.filtered_path).not_to include(
        "25.50", "22.75", "24.50", "320.00", "Pat", "Kin", "175.50", "185.50", "95.00", "85.00"
      )
      expect(req_plain.filtered_path).to include("tax_config[rate]=0.062", "invoice[amount]=100.00", "department[name]=Kitchen")

      parsed = req_plain.filtered_parameters
      expect(parsed.dig("pay_rates", 0, "amount")).to eq("[FILTERED]")
      expect(parsed.dig("items", "0", "rate")).to eq("[FILTERED]")
      expect(parsed.dig("payroll_item", "wage_rate_hours", 0, "rate")).to eq("[FILTERED]")
      expect(parsed.dig("payroll_item", "custom_earnings", "0", "amount")).to eq("[FILTERED]")
      expect(parsed["emergency_contacts"]).to eq("[FILTERED]")
      expect(parsed["amount"]).to eq("[FILTERED]")
      expect(parsed.dig("employee_loan", "amount")).to eq("[FILTERED]")
      expect(parsed["named_loan_payments"]).to eq("[FILTERED]")
      expect(parsed["loan_deductions"]).to eq("[FILTERED]")
      expect(parsed.dig("tax_config", "rate")).to eq("0.062")
      expect(parsed.dig("invoice", "amount")).to eq("100.00")
      expect(parsed.dig("department", "name")).to eq("Kitchen")

      encoded_qs = "pay_rates%5B%5D%5Bamount%5D=26.50&items%5B0%5D%5Brate%5D=23.75" \
                   "&payroll_item%5Bwage_rate_hours%5D%5B0%5D%5Brate%5D=25.25" \
                   "&payroll_item%5Bcustom_earnings%5D%5B%5D%5Bamount%5D=310.00" \
                   "&employee_loan%5Bamount%5D=195.00"
      req_encoded = ActionDispatch::Request.new(
        Rails.application.env_config.merge(Rack::MockRequest.env_for("/api/v1/admin/payroll_items?#{encoded_qs}"))
      )
      expect(req_encoded.filtered_path).not_to include("26.50", "23.75", "25.25", "310.00", "195.00")
      expect(req_encoded.filtered_parameters.dig("pay_rates", 0, "amount")).to eq("[FILTERED]")
      expect(req_encoded.filtered_parameters.dig("items", "0", "rate")).to eq("[FILTERED]")
      expect(req_encoded.filtered_parameters.dig("payroll_item", "wage_rate_hours", "0", "rate")).to eq("[FILTERED]")
      expect(req_encoded.filtered_parameters.dig("payroll_item", "custom_earnings", 0, "amount")).to eq("[FILTERED]")
      expect(req_encoded.filtered_parameters.dig("employee_loan", "amount")).to eq("[FILTERED]")

      # 2. Real JSON request to EmployeeLoansController#record_payment filters top-level amount
      company = create(:company)
      admin = create(:user, company: company, organization: company.organization, role: "admin")
      allow_any_instance_of(Api::V1::Admin::EmployeeLoansController).to receive(:current_user).and_return(admin)
      allow_any_instance_of(Api::V1::Admin::EmployeeLoansController).to receive(:current_company_id).and_return(company.id)

      reported = []
      callback = ->(*, payload) { reported << payload[:params] }
      ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") do
        post "/api/v1/admin/employee_loans/999999/record_payment",
          params: {
            amount: "175.50",
            date: "2026-11-26",
            pay_rates: [ { amount: "25.50", label: "Base" } ],
            items: [ { rate: "22.75", label: "Shift" } ],
            employee_loan: { amount: "185.50", payment_amount: "50.00" },
            invoice: { amount: "100.00" },
            tax_config: { rate: "0.062" }
          },
          as: :json
      end

      logged = reported.last
      expect(logged["amount"]).to eq("[FILTERED]")
      expect(logged.dig("pay_rates", 0, "amount")).to eq("[FILTERED]")
      expect(logged.dig("items", 0, "rate")).to eq("[FILTERED]")
      expect(logged.dig("employee_loan", "amount")).to eq("[FILTERED]")
      expect(logged.dig("employee_loan", "payment_amount")).to eq("[FILTERED]")
      expect(logged.dig("invoice", "amount")).to eq("100.00")
      expect(logged.dig("tax_config", "rate")).to eq("0.062")
    end
  end

  describe "M1: employee link activation sends notice to email on file before change and shows printed code issuer" do
    include ActiveJob::TestHelper

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

    it "persists the pre-change email on activation, dispatches after commit, and retries with the same idempotency key" do
      attempts = []
      allow(PortalNotifications::Transport).to receive(:deliver) do |payload, idempotency_key:|
        attempts << { payload: payload, idempotency_key: idempotency_key }
        raise StandardError, "transient Resend timeout" if attempts.size == 1

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
        expect {
          EmployeeLinks::Bind.activate!(
            link, pending_user, request: request_double,
            identity: { primary_email: "new.signup@example.test", primary_verified: true, verification_strategies: {} }
          )
        }.to have_enqueued_job(SendEmployeeActivationNoticeJob).with(link.id)
      end

      expect(employee.reload.email).to eq("new.signup@example.test")
      expect(link.reload).to have_attributes(
        activation_notice_email: "onfile.worker@example.test",
        activation_notice_status: "pending"
      )
      expect(attempts).to be_empty

      # First job attempt fails -> records failed state and raises for retry
      expect {
        SendEmployeeActivationNoticeJob.new.perform(link.id)
      }.to raise_error(EmployeeLinks::ActivationNoticeEmail::DeliveryError)
      expect(link.reload).to have_attributes(
        activation_notice_status: "failed",
        activation_notice_attempts: 1
      )

      # Retry succeeds with the exact same pre-change email and idempotency key
      SendEmployeeActivationNoticeJob.new.perform(link.id)
      expect(link.reload).to have_attributes(
        activation_notice_status: "sent",
        activation_notice_attempts: 2
      )
      expect(link.activation_notice_sent_at).to be_present
      expect(attempts.size).to eq(2)
      expect(attempts[0][:idempotency_key]).to eq(attempts[1][:idempotency_key])
      payload = attempts.last[:payload]
      expect(payload[:to]).to eq("onfile.worker@example.test")
      expect(payload[:text]).to include("Your Island Bakery employee app account was set up on November 27, 2026")
      expect(payload[:text]).to include("If this wasn't you, contact Island Bakery or Cornerstone right away.")

      # Subsequent run is a no-op (never sends twice)
      SendEmployeeActivationNoticeJob.new.perform(link.id)
      expect(attempts.size).to eq(2)
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

      perform_enqueued_jobs do
        EmployeeLinks::Bind.activate!(
          link, pending_user, request: request_double,
          identity: { primary_email: "allowed@example.test", primary_verified: true, verification_strategies: {} }
        )
      end
      expect(sent).to be_empty
      expect(link.reload.activation_notice_status).to eq("skipped")

      # And an allowlisted email on file DOES receive the notice when the demo employee app is open
      allowed_emp = create(:employee, company: demo_company, email: "allowed2@example.test")
      pending_user2 = create(:user, organization: organization, company: demo_company, role: "portal_employee",
        email: "allowed2@example.test", invitation_status: "pending", active: true, clerk_id: "pending_demo_2")
      link2 = EmployeeAccountLink.create!(
        company: demo_company, employee: allowed_emp, user: pending_user2, invited_by: staff_user,
        status: "invited", invite_delivery: "code", invite_expires_at: 14.days.from_now, invite_generation: 1
      )
      allow(DemoOutbound).to receive(:employee_app_open?).with(demo_company).and_return(true)

      perform_enqueued_jobs do
        EmployeeLinks::Bind.activate!(
          link2, pending_user2, request: request_double,
          identity: { primary_email: "allowed2@example.test", primary_verified: true, verification_strategies: {} }
        )
      end
      expect(sent.size).to eq(1)
      expect(sent.first[:to]).to eq("allowed2@example.test")
      expect(link2.reload.activation_notice_status).to eq("sent")
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

    it "succeeds on activation when post-commit enqueue raises, logs without PII, keeps notice pending, and lets the sweep send it" do
      pending_user = create(:user, organization: organization, company: company, role: "portal_employee",
        email: "new.signup@example.test", invitation_status: "pending", active: true, clerk_id: "pending_enqueue_err")
      link = EmployeeAccountLink.create!(
        company: company, employee: employee, user: pending_user, invited_by: staff_user,
        status: "invited", invite_delivery: "code", invite_expires_at: 14.days.from_now,
        invite_generation: 1, sign_up_email_for_notices: true
      )
      request_double = instance_double(ActionDispatch::Request, remote_ip: "127.0.0.1", user_agent: "RSpec", request_id: "req-enqueue-err")

      allow(SendEmployeeActivationNoticeJob).to receive(:perform_later)
        .and_raise(ActiveRecord::StatementInvalid, "solid_queue write error for onfile.worker@example.test")

      warnings = []
      allow(Rails.logger).to receive(:warn) { |msg| warnings << msg.to_s }

      # Activation commits inside a transaction and must NOT fail when post-commit enqueue raises
      expect {
        ActiveRecord::Base.transaction do
          EmployeeLinks::Bind.activate!(
            link, pending_user, request: request_double,
            identity: { primary_email: "new.signup@example.test", primary_verified: true, verification_strategies: {} }
          )
        end
      }.not_to raise_error

      expect(link.reload).to have_attributes(
        status: "active",
        activation_notice_email: "onfile.worker@example.test",
        activation_notice_status: "pending",
        activation_notice_attempts: 0,
        activation_notice_sent_at: nil
      )
      expect(warnings.join("\n")).to include("link #{link.id}", "ActiveRecord::StatementInvalid")
      expect(warnings.join("\n")).not_to include("onfile.worker@example.test", "new.signup@example.test", "solid_queue write error")

      # Recurring retry sweep later picks up the pending notice and delivers it
      sent = []
      allow(PortalNotifications::Transport).to receive(:deliver) do |payload, idempotency_key:|
        sent << { payload: payload, idempotency_key: idempotency_key }
        { "id" => "msg_sweep_1" }
      end

      SendEmployeeActivationNoticeJob.new.perform
      expect(sent.size).to eq(1)
      expect(sent.first.dig(:payload, :to)).to eq("onfile.worker@example.test")
      expect(link.reload).to have_attributes(
        activation_notice_status: "sent",
        activation_notice_attempts: 1
      )
      expect(link.activation_notice_sent_at).to be_present
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
