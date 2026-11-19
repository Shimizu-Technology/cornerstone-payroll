# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Year-end checklist", type: :request do
  let!(:company) { create(:company, name: "Tumon Bakery", ein: "98-7654321") }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:acting_user) { admin }
  let(:acting_company) { company }
  let!(:threshold_2026) { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }

  before do
    [
      Api::V1::Admin::YearEndController, Api::V1::Admin::ReportsController,
      Api::V1::Admin::PayrollFilingResponsibilitiesController
    ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(acting_user)
      allow_any_instance_of(controller).to receive(:current_company_id) { acting_company.id }
    end
  end

  def pay(target_company, pay_date, worker:, **amounts)
    period = PayPeriod.find_by(company: target_company, pay_date: pay_date) ||
      create(:pay_period, :committed, company: target_company, start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    create(:payroll_item, {
      company: target_company, employee: worker, pay_period: period,
      gross_pay: 2_000, net_pay: 1_600, withholding_tax: 150,
      social_security_tax: 124, employer_social_security_tax: 124,
      medicare_tax: 29, employer_medicare_tax: 29,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000,
      fit_taxable_wages: amounts.fetch(:gross_pay, 2_000)
    }.merge(amounts))
  end

  def record_decision(filing_types:, party:, **extra)
    put "/api/v1/admin/payroll_filing_responsibilities", params: {
      responsibility: { tax_year: 2026, filing_types: filing_types, responsible_party: party, imported_payroll_inclusion: "included", **extra }
    }
  end

  def checklist_step(key)
    get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.dig("data", "steps").find { |step| step["key"] == key }
  end

  describe "GET /api/v1/admin/year_end/clients" do
    let!(:second) { create(:company, organization: company.organization, name: "Agana Auto", ein: nil) }
    let!(:old_trial) { create(:company, organization: company.organization, name: "Old trial", active: false) }
    let!(:dormant) { create(:company, organization: company.organization, name: "Dormant", active: false) }
    let!(:workspace) do
      create(:company, organization: company.organization, name: "Practice copy", payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox", migration_source_company: company, migration_rehearsal_status: "ready",
        test_workspace_expires_at: 1.day.from_now, migration_rehearsal_created_by: admin)
    end

    before do
      pay(company, Date.new(2026, 3, 6), worker: employee)
      second_worker = create(:employee, company: second, department: create(:department, company: second))
      second_worker.update_columns(city: nil)
      pay(second, Date.new(2026, 3, 6), worker: second_worker)
      trial_worker = create(:employee, company: old_trial, department: create(:department, company: old_trial))
      pay(old_trial, Date.new(2026, 6, 5), worker: trial_worker)
    end

    it "lists live clients worst first, hides test workspaces and idle inactive records" do
      get "/api/v1/admin/year_end/clients", params: { year: 2026 }

      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body.fetch("data")
      names = data.fetch("clients").map { |row| row["name"] }
      expect(names).to contain_exactly("Tumon Bakery", "Agana Auto", "Old trial")
      expect(data.fetch("clients").first(3).map { |row| row["issue_count"] }).to eq([ 2, 2, 2 ])
      expect(data.fetch("hidden")).to eq("test_workspaces" => 1, "inactive_without_payroll" => 1)
      trial = data.fetch("clients").find { |row| row["name"] == "Old trial" }
      expect(trial).to include("active" => false, "status" => "needs_action", "checklist_path" => "/companies/#{old_trial.id}/year-end?year=2026")
    end

    it "counts what is left after the decision and drops a no-forms record from the to-do list without deleting it" do
      [ second, old_trial, company ].each do |target|
        allow_any_instance_of(Api::V1::Admin::PayrollFilingResponsibilitiesController).to receive(:current_company_id).and_return(target.id)
        party = target == old_trial ? "no_filing" : "cornerstone"
        record_decision(filing_types: %w[w2_gu form_1099], party: party, notes: "Year-end setup")
        expect(response).to have_http_status(:ok), response.body
      end

      get "/api/v1/admin/year_end/clients", params: { year: 2026 }

      rows = response.parsed_body.dig("data", "clients").index_by { |row| row["name"] }
      expect(rows.fetch("Agana Auto")).to include("status" => "needs_action", "issue_count" => 3), rows.fetch("Agana Auto")["issue_summary"].inspect
      expect(rows.fetch("Agana Auto")["issue_summary"].map { |item| item["code"] }).to eq(%w[EMPLOYER_EIN_MISSING EMPLOYEE_DETAILS_MISSING W2_NOT_MARKED_READY])
      expect(rows.fetch("Agana Auto")["employee_details"]).to eq("missing_ssn" => 0, "missing_address" => 1)
      expect(rows.fetch("Tumon Bakery")).to include("status" => "needs_action", "issue_count" => 1)
      expect(rows.fetch("Tumon Bakery")["issue_summary"].first["code"]).to eq("W2_NOT_MARKED_READY")
      expect(rows.fetch("Old trial")).to include("status" => "not_filing", "issue_count" => 0)
      expect(rows.fetch("Old trial").dig("w2", "label")).to eq("No forms this year")
      expect(response.parsed_body.dig("data", "clients").last["name"]).to eq("Old trial")
      expect(PayPeriod.where(company: old_trial).count).to eq(1)

      # The list and the client's own checklist count the same things.
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      expect(response.parsed_body.dig("data", "issue_count")).to eq(rows.fetch("Tumon Bakery")["issue_count"])
    end

    it "keeps a fixed number of queries as the client list grows" do
      # Each client in both cohorts files W-2s and 1099s here, with W-2
      # payroll, a payroll contractor and a one-off payee, so the employee
      # and 1099 checks all run.
      decide_everything = lambda do |target|
        %w[w2_gu form_1099].each do |filing_type|
          create(:payroll_filing_responsibility, :annual, company: target, filing_type: filing_type, source_cutoff_date: nil)
        end
        contractor = create(:employee, :contractor, company: target, department: target.departments.first || create(:department, company: target))
        pay(target, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 2_500)
        create(:non_employee_check, company: target, check_type: "contractor", payable_to: "Synthetic Roofing", amount: 2_500,
          check_number: "9#{target.id}", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2), printed_at: Time.current)
      end
      [ company, second ].each(&decide_everything)
      # A fresh user per request, so the clients added below are visible
      # (User memoizes its accessible company ids).
      allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user) { User.find(admin.id) }
      count_queries = lambda do
        queries = 0
        callback = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          get "/api/v1/admin/year_end/clients", params: { year: 2026 }
        end
        expect(response).to have_http_status(:ok), response.body
        queries
      end
      baseline = count_queries.call
      extras = Array.new(4) do |index|
        extra = create(:company, organization: company.organization, name: "Extra #{index}")
        pay(extra, Date.new(2026, 3, 6), worker: create(:employee, company: extra, department: create(:department, company: extra)))
        decide_everything.call(extra)
        extra
      end

      expect(count_queries.call).to be <= baseline + 2
      rows = response.parsed_body.dig("data", "clients").index_by { |row| row["name"] }
      extras.each do |extra|
        expect(rows.fetch(extra.name)["issue_summary"].map { |item| item["code"] }).to include("PAYEE_IDENTITY_UNRESOLVED", "W2_NOT_MARKED_READY")
      end
    end

    it "keeps an inactive record with a reportable one-off contractor check and nothing else on the list" do
      create(:non_employee_check, company: dormant, check_type: "contractor", payable_to: "Synthetic Roofing", amount: 2_500,
        check_number: "9001", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2), printed_at: Time.current)
      idle = create(:company, organization: company.organization, name: "Idle", active: false)
      create(:non_employee_check, company: idle, check_type: "contractor", payable_to: "Draft Only", amount: 2_500,
        check_number: "9002", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2))

      get "/api/v1/admin/year_end/clients", params: { year: 2026 }

      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body.fetch("data")
      expect(data.fetch("clients").map { |row| row["name"] }).to include("Dormant")
      expect(data.fetch("clients").map { |row| row["name"] }).not_to include("Idle")
      expect(data.dig("hidden", "inactive_without_payroll")).to eq(1)
    end
  end

  describe "the clients list status agrees with the checklist" do
    include ActiveSupport::Testing::TimeHelpers

    let(:start) { 1.hour.from_now.change(usec: 0) }
    def list_row
      get "/api/v1/admin/year_end/clients", params: { year: 2026 }
      expect(response).to have_http_status(:ok), response.body
      response.parsed_body.dig("data", "clients").find { |row| row["company_id"] == company.id }
    end

    def mark_ready
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2026 }
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2026, notes: "Year-end review" }
      expect(response).to have_http_status(:ok), response.body
    end

    before do
      pay(company, Date.new(2026, 3, 6), worker: employee)
      record_decision(filing_types: %w[w2_gu], party: "cornerstone")
      record_decision(filing_types: %w[form_1099], party: "no_filing")
    end

    it "shows Check needed, not Ready, after an employee address changes once the W-2s are marked ready" do
      travel_to(start + 0.hours) { mark_ready }
      travel_to(start + 1.hours) do
        expect(list_row).to include("status" => "ready", "check_reason" => nil)

        employee.update!(address_line1: "200 New Street")

        expect(list_row).to include("status" => "check_needed", "check_reason" => a_string_including("changed since the W-2s were marked ready"))
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("needs_action")
        expect(list_row["status"]).to eq("check_needed")
      end
      travel_to(start + 2.hours) do
        mark_ready
        expect(list_row["status"]).to eq("ready")
      end
    end

    it "returns to Ready once the full checklist re-checks an unrelated change" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      travel_to(start + 0.hours) { mark_ready }
      travel_to(start + 1.hours) do
        employee.touch
        expect(list_row["status"]).to eq("check_needed")
      end
      travel_to(start + 2.hours) do
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("ready")
        expect(list_row["status"]).to eq("ready")
      end
    end

    it "does not call a 1099-only client Ready while a reportable contractor has no TIN" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department)
      contractor.update_columns(ssn_encrypted: nil, contractor_ein: nil)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 2_500)

      row = list_row
      expect(row).to include("status" => "needs_action")
      expect(row["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_DETAILS_MISSING])
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      expect(response.parsed_body.dig("data", "issue_count")).to eq(row["issue_count"])

      contractor.update_columns(ssn_encrypted: "900-70-4321")
      expect(list_row["status"]).to eq("ready")
    end

    it "keeps a 1099 client off Ready until a one-off contractor payee is identified through the endpoint" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Synthetic Roofing", amount: 2_500,
        check_number: "9001", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2), printed_at: Time.current)

      expect(list_row["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_IDENTITY_UNRESOLVED])
      payee = checklist_step("people").dig("data", "one_off_payees").sole
      expect(payee).to include("status" => "needs_identity", "name" => "Synthetic Roofing")

      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: payee["code"], warning_digest: payee["digest"], note: "Synthetic Roofing LLC; W-9 and EIN in the client folder."
      } }
      expect(response).to have_http_status(:created), response.body

      expect(checklist_step("people")["status"]).to eq("done")
      expect(list_row["status"]).to eq("ready")
    end
  end

  describe "GET /api/v1/admin/year_end/checklist" do
    it "rejects years before the checklist starts" do
      get "/api/v1/admin/year_end/checklist", params: { year: 2025 }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    context "for a user without access to the client" do
      let(:other_company) { create(:company) }
      let(:acting_user) { create(:user, company: other_company, organization: other_company.organization, role: "accountant") }

      it "refuses the checklist" do
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }

        expect(response).to have_http_status(:forbidden)
      end
    end

    it "lists a missing EIN and clears it once the EIN is saved" do
      company.update_columns(ein: nil)
      pay(company, Date.new(2026, 3, 6), worker: employee)
      record_decision(filing_types: %w[w2_gu form_1099], party: "cornerstone")

      expect(checklist_step("employer")["issues"].map { |issue| issue["code"] }).to eq(%w[EMPLOYER_EIN_MISSING])

      company.update!(ein: "98-7654321")
      expect(checklist_step("employer")["status"]).to eq("done")
    end
  end

  describe "filing decisions" do
    it "records the client, no-forms and prior-provider options with an audit entry" do
      record_decision(filing_types: %w[form_1099], party: "client")
      expect(response).to have_http_status(:ok), response.body

      record_decision(filing_types: %w[w2_gu], party: "cornerstone", prior_provider_through: "2026-03-31")
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("data", 0, "prior_provider_through")).to eq("2026-03-31")

      audit = AuditLog.where(action: "payroll_filing_responsibilities#recorded", company_id: company.id).order(:id).last
      expect(audit.metadata.dig("after", "w2_gu", "prior_provider_through")).to eq("2026-03-31")

      record_decision(filing_types: %w[form_1099], party: "client", prior_provider_through: "2026-03-31")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    def record_both(w2:, form_1099:)
      put "/api/v1/admin/payroll_filing_responsibilities", params: { responsibility: {
        tax_year: 2026, imported_payroll_inclusion: "included", notes: "Year-end setup",
        decisions: [ { filing_type: "w2_gu", **w2 }, { filing_type: "form_1099", **form_1099 } ]
      } }, as: :json
    end

    def saved_decisions
      company.payroll_filing_responsibilities.where(tax_year: 2026, quarter: nil).order(:filing_type)
        .pluck(:filing_type, :responsible_party, :prior_provider_through)
    end

    it "saves the W-2 and 1099 decisions in one request with one audit entry" do
      record_both(w2: { responsible_party: "cornerstone", prior_provider_through: "2026-03-31" }, form_1099: { responsible_party: "client" })

      expect(response).to have_http_status(:ok), response.body
      expect(saved_decisions).to eq([ [ "form_1099", "client", nil ], [ "w2_gu", "cornerstone", Date.new(2026, 3, 31) ] ])
      audit = AuditLog.where(action: "payroll_filing_responsibilities#recorded", company_id: company.id).sole
      expect(audit.metadata["filing_types"]).to eq(%w[w2_gu form_1099])
    end

    it "leaves both decisions unchanged when either one is refused" do
      record_decision(filing_types: %w[w2_gu form_1099], party: "no_filing")
      before = saved_decisions
      audits = AuditLog.where(action: "payroll_filing_responsibilities#recorded").count

      # The 1099 decision is refused after the W-2 decision was written.
      record_both(w2: { responsible_party: "cornerstone" }, form_1099: { responsible_party: "client", prior_provider_through: "2026-03-31" })
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(saved_decisions).to eq(before)

      # The W-2 decision is refused (a date outside the tax year).
      record_both(w2: { responsible_party: "cornerstone", prior_provider_through: "2025-12-31" }, form_1099: { responsible_party: "cornerstone" })
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(saved_decisions).to eq(before)
      expect(AuditLog.where(action: "payroll_filing_responsibilities#recorded").count).to eq(audits)
    end

    context "for a user who cannot record filing decisions" do
      let(:acting_user) { create(:user, company: company, organization: company.organization, role: "client") }

      it "refuses both" do
        record_both(w2: { responsible_party: "cornerstone" }, form_1099: { responsible_party: "cornerstone" })

        expect(response).to have_http_status(:forbidden), response.body
        expect(saved_decisions).to be_empty
      end
    end
  end

  describe "POST /api/v1/admin/year_end/acknowledgements" do
    before do
      pay(company, Date.new(2026, 4, 3), worker: employee, overtime_hours: 4, qualified_overtime_compensation: nil)
      record_decision(filing_types: %w[w2_gu form_1099], party: "cornerstone")
    end

    def overtime_warning
      checklist_step("review_warnings").dig("data", "warnings").find { |warning| warning["code"] == "qualified_overtime_unreviewed" }
    end

    it "records an audited review that clears the warning" do
      warning = overtime_warning
      expect(warning).to include("kind" => "acknowledge", "status" => "needs_review")

      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "qualified_overtime_unreviewed", warning_digest: warning["digest"],
        note: "Overtime was for a salaried manager; not qualified."
      } }

      expect(response).to have_http_status(:created), response.body
      expect(overtime_warning["status"]).to eq("reviewed")
      audit = AuditLog.find_by!(action: "year_end_acknowledgements#recorded", company_id: company.id)
      expect(audit.user).to eq(admin)
      expect(audit.metadata).to include("tax_year" => 2026, "warning_code" => "qualified_overtime_unreviewed")
      expect(audit.metadata.dig("after", "note")).to eq("Overtime was for a salaried manager; not qualified.")
    end

    it "refuses a review made on data that has since changed, a blank note, and a blocker" do
      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "qualified_overtime_unreviewed", warning_digest: "0" * 64, note: "Looked at it"
      } }
      expect(response).to have_http_status(:conflict)

      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "qualified_overtime_unreviewed", warning_digest: overtime_warning["digest"], note: " "
      } }
      expect(response).to have_http_status(:unprocessable_entity)

      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "negative_box12_amounts", warning_digest: "0" * 64, note: "Fine"
      } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(YearEndAcknowledgement.count).to eq(0)
    end
  end

  describe "a 941 residual review after another paycheck" do
    it "asks for the review again and refuses the old digest with 409" do
      pay(company, Date.new(2026, 5, 8), worker: employee, employer_social_security_tax: 124.03)
      record_decision(filing_types: %w[w2_gu form_1099], party: "cornerstone")
      residual = -> { checklist_step("review_warnings").dig("data", "warnings").find { |warning| warning["code"] == "form_941_liability_residual" } }
      seen = residual.call
      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "form_941_liability_residual", warning_digest: seen["digest"], note: "Employer rounding on one paycheck."
      } }
      expect(response).to have_http_status(:created), response.body
      expect(residual.call["status"]).to eq("reviewed")

      # Same $0.03 residual and no employee difference; the quarter's taxes double.
      pay(company, Date.new(2026, 6, 5), worker: employee)

      expect(residual.call).to include("status" => "needs_review", "acknowledgement_stale" => true)
      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "form_941_liability_residual", warning_digest: seen["digest"], note: "Employer rounding on one paycheck."
      } }
      expect(response).to have_http_status(:conflict), response.body
      expect(response.parsed_body["error"]).to include("changed")
    end
  end

  describe "POST /api/v1/admin/reports/w2_gu_mark_ready for 2026" do
    def mark_ready
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2026 }
      expect(response).to have_http_status(:ok), response.body
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2026, notes: "Year-end review" }
    end

    it "requires the year-end filing decision" do
      pay(company, Date.new(2026, 3, 6), worker: employee)

      mark_ready

      expect(response).to have_http_status(:unprocessable_entity)
      codes = response.parsed_body["year_end_blockers"].map { |blocker| blocker["code"] }
      expect(codes).to include("W2_FILER_NOT_CHOSEN")
      expect(codes).not_to include("FORM_1099_FILER_NOT_CHOSEN")
    end

    context "with the W-2 decision recorded and no 1099 decision" do
      before do
        pay(company, Date.new(2026, 3, 6), worker: employee)
        record_decision(filing_types: %w[w2_gu], party: "cornerstone")
      end

      it "marks the W-2s ready and keeps the 1099 decision on the checklist" do
        mark_ready

        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.dig("filing", "status")).to eq("filing_ready")
        decision = checklist_step("filing_decision")
        expect(decision["issues"].map { |issue| issue["code"] }).to eq(%w[FORM_1099_FILER_NOT_CHOSEN])
        expect(checklist_step("reconciliation")["status"]).to eq("done")
        expect(response.parsed_body.dig("data", "status")).to eq("needs_action")
      end

      it "still runs the W-2 checks and blocks on a real W-2 problem" do
        company.update_columns(phone: nil)

        mark_ready

        expect(response).to have_http_status(:unprocessable_entity), response.body
        expect(response.parsed_body["year_end_blockers"].map { |blocker| blocker["code"] }).to eq(%w[EMPLOYER_PHONE_MISSING])
        expect(W2FilingReadiness.find_by!(company: company, year: 2026).status).not_to eq("filing_ready")

        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        checklist_count = response.parsed_body.dig("data", "issue_count")
        get "/api/v1/admin/year_end/clients", params: { year: 2026 }
        row = response.parsed_body.dig("data", "clients").find { |entry| entry["company_id"] == company.id }
        expect(row["issue_summary"].map { |issue| issue["code"] }).to contain_exactly("FILER_NOT_CHOSEN", "EMPLOYER_PHONE_MISSING", "W2_NOT_MARKED_READY")
        expect(row["issue_count"]).to eq(checklist_count).and eq(3)
      end
    end

    it "refuses to mark ready when the inputs change while the checklist is checked" do
      pay(company, Date.new(2026, 3, 6), worker: employee)
      record_decision(filing_types: %w[w2_gu form_1099], party: "cornerstone")
      allow_any_instance_of(YearEnd::Checklist).to receive(:w2_mark_ready_blockers).and_wrap_original do |original|
        blockers = original.call
        # A paycheck committed outside the company lock mid-check.
        pay(company, Date.new(2026, 4, 3), worker: employee)
        blockers
      end

      mark_ready

      expect(response).to have_http_status(:conflict), response.body
      expect(response.parsed_body["error"]).to include("changed while the year-end checklist was checked")
      expect(W2FilingReadiness.find_by!(company: company, year: 2026)).to have_attributes(status: be_present, ready_fingerprint: nil)
    end

    it "blocks a Social Security wage mismatch, names the quarter, and allows ready once the payroll is fixed" do
      pay(company, Date.new(2026, 2, 6), worker: employee)
      item = pay(company, Date.new(2026, 5, 8), worker: employee, social_security_taxable_wages: 1_800, social_security_taxable_tips: nil,
        social_security_tax: 111.60, employer_social_security_tax: 111.60)
      record_decision(filing_types: %w[w2_gu form_1099], party: "cornerstone")

      mark_ready

      expect(response).to have_http_status(:unprocessable_entity), response.body
      mismatch = response.parsed_body["year_end_blockers"].find { |blocker| blocker["code"] == "RECONCILIATION_MISMATCH" }
      expect(mismatch).to include("line" => "social_security_wages")
      expect(mismatch["message"]).to include("Q2 941")
      expect(W2FilingReadiness.find_by!(company: company, year: 2026).status).not_to eq("filing_ready")

      item.update_columns(social_security_taxable_tips: 0)
      mark_ready

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("filing", "status")).to eq("filing_ready")
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      expect(response.parsed_body.dig("data", "status")).to eq("ready"), response.parsed_body.dig("data", "steps").flat_map { |s| s["issues"] }.inspect
    end

    it "blocks ready when imported history overlaps the prior provider's period" do
      create_historical_filing_source(
        company: company, employee: employee, pay_date: Date.new(2026, 6, 30),
        gross_pay: 12_000, federal_income_tax: 900, social_security_tax: 744, medicare_tax: 174,
        employer_social_security_tax: 744, employer_medicare_tax: 174,
        period_type: "opening_summary", period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 6, 30)
      )
      pay(company, Date.new(2026, 8, 7), worker: employee)
      record_decision(filing_types: %w[form_1099], party: "no_filing")
      record_decision(filing_types: %w[w2_gu], party: "cornerstone", prior_provider_through: "2026-03-31")

      mark_ready

      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(response.parsed_body["year_end_blockers"].map { |blocker| blocker["code"] }).to include("PRIOR_PROVIDER_OVERLAP")
    end
  end
end
