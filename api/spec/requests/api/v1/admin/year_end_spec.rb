# frozen_string_literal: true

require "rails_helper"
require "benchmark"

RSpec.describe "Year-end checklist", type: :request do
  let!(:company) { create(:company, name: "Tumon Bakery", ein: "98-7654321") }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  let(:acting_user) { admin }
  let(:acting_company) { company }
  let!(:threshold_2026) { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }

  before do
    [
      Api::V1::Admin::YearEndController, Api::V1::Admin::ReportsController,
      Api::V1::Admin::PayrollFilingResponsibilitiesController, Api::V1::Admin::EmployeeTippedOccupationsController
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

      [ company, second ].each { |target| YearEnd::Checklist.new(company: target, year: 2026).call }
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

    it "does not aggregate and keeps query count constant with 26 periods and many employees" do
      create(:payroll_filing_responsibility, :annual, company: company, filing_type: "w2_gu", source_cutoff_date: nil)
      expect(W2GuAggregator).not_to receive(:new)
      measure = lambda do
        count = 0
        callback = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
        elapsed = Benchmark.realtime do
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            get "/api/v1/admin/year_end/clients", params: { year: 2026 }
          end
        end
        expect(response).to have_http_status(:ok)
        [ count, elapsed ]
      end
      refresh_cache = -> { YearEnd::EfileCheck.record(company.id, 2026, YearEnd::InputRevision.for(company.id, 2026)[company.id], []) }
      refresh_cache.call
      baseline, before_time = measure.call
      workers = create_list(:employee, 30, company: company, department: department)
      26.times do |index|
        date = Date.new(2026, 1, 9) + index * 14
        workers.each { |worker| pay(company, date, worker: worker) }
      end
      refresh_cache.call
      after_count, after_time = measure.call
      warn "Overview 26 periods x 30 employees: #{after_time.round(3)}s / #{after_count} queries; small baseline #{before_time.round(3)}s / #{baseline} queries"
      expect(after_count).to be <= baseline
      row = response.parsed_body.dig("data", "clients").find { |entry| entry["company_id"] == company.id }
      expect(row["issue_count"]).to be_a(Integer)
      Rails.cache.delete(YearEnd::EfileCheck.key(company.id, 2026))
      measure.call
      row = response.parsed_body.dig("data", "clients").find { |entry| entry["company_id"] == company.id }
      expect(row).to include("status" => "needs_action", "efile_check_pending" => true)
    end

    it "keeps the query count flat as W-2 clients are added" do
      count_queries = lambda do
        # The stubbed user memoizes its company list; clear it so every request sees the clients added since.
        acting_user.instance_variable_set(:@accessible_company_ids, nil)
        count = 0
        callback = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          get "/api/v1/admin/year_end/clients", params: { year: 2026 }
        end
        expect(response).to have_http_status(:ok)
        count
      end
      add_w2_client = lambda do |name|
        client = create(:company, organization: company.organization, name: name, ein: nil)
        worker = create(:employee, company: client, department: create(:department, company: client))
        pay(client, Date.new(2026, 3, 6), worker: worker)
        create(:payroll_filing_responsibility, :annual, company: client, filing_type: "w2_gu", source_cutoff_date: nil)
      end
      add_w2_client.call("Client 1")
      baseline = count_queries.call
      4.times { |index| add_w2_client.call("Client #{index + 2}") }

      expect(count_queries.call).to be <= baseline
      names = response.parsed_body.dig("data", "clients").map { |row| row["name"] }
      expect(names).to include("Client 1", "Client 2", "Client 3", "Client 4", "Client 5")
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
    # The list's Ready rests on the last successful check, kept in the cache.
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }
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
      allow(Rails).to receive(:cache).and_return(cache)
      pay(company, Date.new(2026, 3, 6), worker: employee)
      record_decision(filing_types: %w[w2_gu], party: "cornerstone")
      record_decision(filing_types: %w[form_1099], party: "no_filing")
    end

    it "invalidates ready and e-file checks when the accepted legacy review is reopened" do
      employee.payroll_items.sole.update_columns(fit_taxable_wages: nil)
      detector = PayrollHistoryReview::Detector.new(company: company, tax_year: 2026)
      item, subject = detector.call.fetch(:items).sole
      resolution = PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
        subject_key: subject.route_key, user: admin, actor: AuditActor.for_user(admin))
      resolution.resolve!(code: "legacy_basis_accepted", reference: "Reviewed archived wage statements", expected_digest: item.subject_digest)
      mark_ready
      expect(list_row).to include("status" => "ready")
      accepted_revision = YearEnd::InputRevision.for(company.id, 2026)[company.id]

      resolution.reopen!(reason: "More evidence arrived", expected_digest: item.subject_digest)

      expect(YearEnd::InputRevision.for(company.id, 2026)[company.id]).not_to eq(accepted_revision)
      expect(list_row.fetch("status")).not_to eq("ready")
      expect(checklist_step("review_warnings").dig("data", "warnings")).to include(
        a_hash_including("code" => "legacy_tax_bases", "status" => "needs_review"))
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2026, notes: "Attempt a second sign-off" }
      expect(response).not_to have_http_status(:ok)
    end

    it "keeps known issues visible while a stale check is queued only once" do
      mark_ready
      company.update!(ein: nil)
      row = nil
      expect {
        2.times { row = list_row }
      }.to have_enqueued_job(YearEndEfileCheckJob).exactly(:once)
      expect(row).to include("status" => "needs_action", "issue_count" => 1, "efile_check_pending" => true)
      expect(row["issue_summary"]).to include(a_hash_including("code" => "EMPLOYER_EIN_MISSING"))
      YearEndEfileCheckJob.perform_now(company.id, 2026, YearEnd::InputRevision.for(company.id, 2026)[company.id])
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      result = response.parsed_body.fetch("data")
      expect(list_row).to include("status" => result["status"], "issue_count" => result["issue_count"], "efile_check_pending" => false)
    end

    it "never shows Ready while the W-2s are not marked, whatever a cached check says" do
      revision = YearEnd::InputRevision.for(company.id, 2026)[company.id]
      YearEnd::EfileCheck.record(company.id, 2026, revision, [], sign_off_needed: false)

      row = list_row

      expect(row["status"]).to eq("needs_action")
      expect(row["issue_summary"]).to include(a_hash_including("code" => "W2_NOT_MARKED_READY"))
    end

    it "shows Check needed, not Ready, after an employee address changes once the W-2s are marked ready" do
      travel_to(start + 0.hours) { mark_ready }
      travel_to(start + 1.hours) do
        expect(list_row).to include("status" => "ready", "check_reason" => nil)

        employee.update!(address_line1: "200 New Street")

        expect(list_row).to include("status" => "check_needed", "issue_count" => nil, "efile_check_pending" => true, "check_reason" => a_string_including("changed since the W-2s were marked ready"))
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("needs_action")
        checklist_count = response.parsed_body.dig("data", "issue_count")
        expect(list_row["status"]).to eq("needs_action")
        expect(list_row["issue_count"]).to eq(checklist_count)
      end
      travel_to(start + 2.hours) do
        mark_ready
        expect(list_row["status"]).to eq("ready")
      end
    end

    it "returns to Ready once the full checklist re-checks an unrelated change" do
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

    it "shows Check needed, not Ready, after a tipped employee's only occupation code is deleted" do
      occupation = create(:employee_tipped_occupation, employee: employee)
      pay(company, Date.new(2026, 5, 8), worker: employee, reported_tips: 200, cash_tips_reported: 200,
        social_security_taxable_wages: 1_800, social_security_taxable_tips: 200)
      travel_to(start + 0.hours) { mark_ready }
      travel_to(start + 1.hours) do
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("ready")
        expect(list_row["status"]).to eq("ready")

        # Nothing left gets a newer timestamp: only the row count changes.
        occupation.destroy!

        expect(list_row).to include("status" => "check_needed", "issue_count" => nil)
        expect(list_row["issue_summary"]).not_to include(a_hash_including("code" => "EMPLOYEE_EFILE_INVALID"))
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("needs_action")
        expect(list_row["status"]).to eq("needs_action")
      end
    end

    # IRS General Instructions for Forms W-2 and W-3 (2026), Box 14b: tips
    # from more than two occupations get any two codes, so this is a warning
    # to confirm, never a blocker the list can't see.
    it "agrees with the checklist for an employee with three tipped occupation codes, before and after marking ready" do
      %w[101 202 303].each { |code| create(:employee_tipped_occupation, employee: employee, occupation_code: code) }
      checklist = lambda do
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response).to have_http_status(:ok), response.body
        response.parsed_body["data"]
      end

      travel_to(start + 0.hours) do
        data = checklist.call
        expect(data).to include("status" => "needs_action", "issue_count" => 1)
        expect(list_row).to include("status" => "needs_action", "issue_count" => 1)

        warning = data["steps"].find { |step| step["key"] == "review_warnings" }.dig("data", "warnings").find { |entry| entry["code"] == "box14b_more_than_two_codes" }
        post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
          tax_year: 2026, warning_code: "box14b_more_than_two_codes", warning_digest: warning["digest"],
          note: "Tips came from three occupations; 101 and 202 are right."
        } }
        expect(response).to have_http_status(:created), response.body
        expect(checklist.call).to include("status" => "needs_action", "issue_count" => 1)
        expect(list_row).to include("status" => "needs_action", "issue_count" => 1)

        mark_ready
      end
      travel_to(start + 1.hours) do
        expect(list_row).to include("status" => "ready", "issue_count" => 0)
        expect(checklist.call).to include("status" => "ready", "issue_count" => 0)
        expect(list_row).to include("status" => "ready", "issue_count" => 0)
      end
    end

    it "shows Check needed after retirement-year evidence or an import source file is added" do
      travel_to(start + 0.hours) { mark_ready }
      travel_to(start + 1.hours) do
        expect(list_row["status"]).to eq("ready")
        before = YearEnd::InputRevision.for(company.id, 2026)[company.id]
        EmployeeRetirementYearInput.insert_all!([ { company_id: company.id, employee_id: employee.id, tax_year: 2026,
          prior_year_wage_status: "unknown", reason: "Synthetic evidence", source_reference: "Synthetic source",
          created_at: Time.current, updated_at: Time.current } ])
        expect(YearEnd::InputRevision.for(company.id, 2026)[company.id]).not_to eq(before)
        expect(list_row["status"]).to eq("check_needed")
      end
    end

    it "stops showing Ready once a checklist run finds a blocker or fails" do
      travel_to(start + 0.hours) { mark_ready }
      travel_to(start + 1.hours) do
        expect(list_row["status"]).to eq("ready")

        # Something the input revision does not see makes the totals uncomparable.
        allow_any_instance_of(YearEnd::Reconciliation).to receive(:call).and_return(YearEnd::Reconciliation.unavailable("synthetic outage"))
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("needs_action")
        checklist_count = response.parsed_body.dig("data", "issue_count")
        expect(list_row["status"]).to eq("needs_action")
        expect(list_row["issue_count"]).to eq(checklist_count)

        allow_any_instance_of(YearEnd::Reconciliation).to receive(:call).and_call_original
        get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
        expect(response.parsed_body.dig("data", "status")).to eq("ready")
        expect(list_row["status"]).to eq("ready")

        allow_any_instance_of(YearEnd::Reconciliation).to receive(:call).and_raise(RuntimeError, "synthetic failure")
        expect { YearEnd::Checklist.new(company: company, year: 2026, user: admin).call }.to raise_error(RuntimeError, "synthetic failure")
        expect(list_row["status"]).to eq("check_needed")
      end
    end

    it "does not call a 1099-only client Ready while a reportable contractor has no TIN" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, w9_on_file: true)
      contractor.update_columns(ssn_encrypted: nil, contractor_ein: nil)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 2_500, withholding_tax: 0)

      row = list_row
      expect(row).to include("status" => "needs_action")
      expect(row["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_DETAILS_MISSING FORM_1099_NOT_MARKED_READY])
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      expect(response.parsed_body.dig("data", "issue_count")).to eq(row["issue_count"])

      contractor.update_columns(ssn_encrypted: "900-70-4321")
      # A payee now gets a 1099, so the 1099 sign-off is all that's left.
      expect(list_row).to include("status" => "needs_action", "issue_count" => 1)
      step = checklist_step("form_1099_ready")
      post "/api/v1/admin/year_end/form_1099_mark_ready", params: { form_1099: { tax_year: 2026, inputs_fingerprint: step.dig("data", "inputs_fingerprint") } }
      expect(response).to have_http_status(:ok), response.body
      expect(list_row["status"]).to eq("ready")
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      expect(response.parsed_body.dig("data", "status")).to eq("ready")
    end

    def expect_parity
      row = list_row
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      result = response.parsed_body.fetch("data")
      expect(row).to include("status" => result["status"], "issue_count" => result["issue_count"])
      row
    end

    def mark_1099s_ready
      post "/api/v1/admin/year_end/form_1099_mark_ready", params: { form_1099: {
        tax_year: 2026, inputs_fingerprint: checklist_step("form_1099_ready").dig("data", "inputs_fingerprint")
      } }
      expect(response).to have_http_status(:ok), response.body
    end

    it "agrees with the checklist on a one-off payee linked to a contractor, the 1099 sign-off and a later change" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, first_name: "Ana", last_name: "Cruz", w9_on_file: true)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 1_200, withholding_tax: 0)
      create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Ana Cruz", amount: 1_000,
        check_number: "9001", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2), printed_at: Time.current)
      create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Ana Cruz", amount: 1_000,
        check_number: "9002", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 6, 2), printed_at: Time.current)

      # Below the threshold on payroll alone: only the one-off payee counts.
      expect(expect_parity["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_IDENTITY_UNRESOLVED FORM_1099_NOT_MARKED_READY])

      payee = checklist_step("people").dig("data", "one_off_payees").sole
      post "/api/v1/admin/year_end/one_off_payees/link", params: { payee: { tax_year: 2026, code: payee["code"], digest: payee["digest"], employee_id: contractor.id } }
      expect(response).to have_http_status(:ok), response.body
      # Linked, the contractor reaches the threshold and needs the sign-off.
      expect(expect_parity["issue_summary"].map { |item| item["code"] }).to eq(%w[FORM_1099_NOT_MARKED_READY])

      mark_1099s_ready
      expect(expect_parity["status"]).to eq("ready")

      contractor.update!(address_line1: "9 New Road")
      expect(expect_parity).to include("status" => "needs_action", "issue_count" => 1)
    end

    it "agrees with the checklist on a reportable payee whose W-9 is not on file" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, ssn_encrypted: "900-70-4321", w9_on_file: false)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 2_500, withholding_tax: 0)

      row = expect_parity
      expect(row["issue_summary"]).to eq([
        { "code" => "PAYEE_W9_MISSING", "label" => "W-9 not on file", "count" => 1 },
        { "code" => "FORM_1099_NOT_MARKED_READY", "label" => "Mark 1099s ready", "count" => 1 }
      ])

      contractor.update!(w9_on_file: true)
      expect(expect_parity["issue_summary"].map { |item| item["code"] }).to eq(%w[FORM_1099_NOT_MARKED_READY])
      mark_1099s_ready
      expect(expect_parity["status"]).to eq("ready")
    end

    it "agrees with the checklist on a smaller unlinked check: never a blocker, but it expires a 1099 sign-off" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, first_name: "Ana", last_name: "Cruz", w9_on_file: true)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 3_000, withholding_tax: 0)
      mark_1099s_ready
      expect(expect_parity["status"]).to eq("ready")

      create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Ana Cruz", amount: 1_000,
        check_number: "9001", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 6, 2), printed_at: Time.current)

      expect(expect_parity["issue_summary"].map { |item| item["code"] }).to eq(%w[FORM_1099_NOT_MARKED_READY])
      mark_1099s_ready
      expect(expect_parity["status"]).to eq("ready")
    end

    it "agrees with the checklist on two contractor records that share a TIN" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      first = create(:employee, :contractor, company: company, department: department, ssn_encrypted: "900-70-1111", w9_on_file: true)
      second = create(:employee, :contractor, company: company, department: department, ssn_encrypted: "900701111", w9_on_file: true)
      [ first, second ].each { |worker| pay(company, Date.new(2026, 5, 8), worker: worker, employment_type: "contractor", gross_pay: 2_500, withholding_tax: 0) }

      row = expect_parity
      expect(row["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_DUPLICATE_TIN FORM_1099_NOT_MARKED_READY])
      issue = checklist_step("people")["issues"].sole
      expect(issue).to include("code" => "PAYEE_DUPLICATE_TIN", "employee_ids" => [ first, second ].sort_by { |worker| [ worker.last_name.downcase, worker.first_name.downcase, worker.id ] }.map(&:id))

      second.update_columns(ssn_encrypted: "900-70-2222")
      expect(expect_parity["issue_summary"].map { |item| item["code"] }).to eq(%w[FORM_1099_NOT_MARKED_READY])
    end

    it "counts the 1099 sign-off for a client whose W-2s are marked ready, and never the other way round" do
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, w9_on_file: true)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 2_500, withholding_tax: 0)
      mark_ready
      YearEndEfileCheckJob.perform_now(company.id, 2026, YearEnd::InputRevision.for(company.id, 2026)[company.id])

      row = expect_parity
      expect(row["issue_summary"].map { |item| item["code"] }).to eq(%w[FORM_1099_NOT_MARKED_READY])
      steps = response.parsed_body.dig("data", "steps")
      expect(steps.map { |entry| entry["key"] }).to eq(%w[filing_decision employer people form_1099_ready reconciliation review_warnings prior_provider mark_ready print_and_file])
      expect(steps.map { |entry| entry["number"] }).to eq((1..9).to_a)
      expect(steps.find { |entry| entry["key"] == "mark_ready" }["status"]).to eq("done")

      mark_1099s_ready
      expect(expect_parity["status"]).to eq("ready")
    end

    it "does not call a 1099-only client Ready while a below-threshold contractor with withholding has no TIN" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, w9_on_file: true)
      contractor.update_columns(ssn_encrypted: nil, contractor_ein: nil)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 500, net_pay: 450, withholding_tax: 50)

      row = list_row
      expect(row).to include("status" => "needs_action")
      expect(row["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_DETAILS_MISSING FORM_1099_NOT_MARKED_READY])
      get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
      expect(response.parsed_body.dig("data", "issue_count")).to eq(row["issue_count"])

      contractor.update_columns(ssn_encrypted: "900-70-4321")
      # Withholding makes the 1099 due at any amount, so it needs the sign-off.
      expect(list_row).to include("status" => "needs_action", "issue_count" => 1)
      mark_1099s_ready
      expect(list_row["status"]).to eq("ready")
    end

    it "agrees with the checklist on a $500 payee with $50 withheld and no W-9 on file" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      contractor = create(:employee, :contractor, company: company, department: department, ssn_encrypted: "900-70-4321",
        address_line1: "7 Route 8", city: "Maite", state: "GU", zip: "96910", w9_on_file: false)
      pay(company, Date.new(2026, 5, 8), worker: contractor, employment_type: "contractor", gross_pay: 500, net_pay: 450, withholding_tax: 50)

      expect(expect_parity["issue_summary"]).to eq([
        { "code" => "PAYEE_W9_MISSING", "label" => "W-9 not on file", "count" => 1 },
        { "code" => "FORM_1099_NOT_MARKED_READY", "label" => "Mark 1099s ready", "count" => 1 }
      ])
      expect(checklist_step("people")["issues"].map { |issue| issue["code"] }).to eq(%w[PAYEE_W9_MISSING])

      contractor.update!(w9_on_file: true)
      expect(expect_parity["issue_summary"].map { |item| item["code"] }).to eq(%w[FORM_1099_NOT_MARKED_READY])
      mark_1099s_ready
      expect(expect_parity["status"]).to eq("ready")
    end

    # Who a payee is gets settled by linking the checks to a contractor (the
    # form_1099_year_end_spec covers that); an acknowledgement here records
    # that no 1099 is due, for example a payment to a utility for goods.
    it "keeps a 1099 client off Ready until a one-off payee is decided no 1099 due through the endpoint" do
      record_decision(filing_types: %w[w2_gu], party: "client")
      record_decision(filing_types: %w[form_1099], party: "cornerstone")
      create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Guam Power Authority", amount: 2_500,
        check_number: "9001", payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2), printed_at: Time.current)

      expect(list_row["issue_summary"].map { |item| item["code"] }).to eq(%w[PAYEE_IDENTITY_UNRESOLVED FORM_1099_NOT_MARKED_READY])
      payee = checklist_step("people").dig("data", "one_off_payees").sole
      expect(payee).to include("status" => "needs_identity", "name" => "Guam Power Authority")

      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: payee["code"], warning_digest: payee["digest"],
        note: "Power bill for the shop, a utility paid for service to the premises, not for a contractor's services. No 1099 is due."
      } }
      expect(response).to have_http_status(:created), response.body

      expect(checklist_step("people")["status"]).to eq("done")
      expect(checklist_step("form_1099_ready").dig("data", "no_1099_due_count")).to eq(1)
      expect(checklist_step("form_1099_ready").dig("data", "payee_count")).to eq(0)
      expect(Form1099NecAggregator.new(company, 2026).generate[:reportable_contractors].sole[:employee_id]).to be_nil
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
    it "requires recording legacy taxable-wage decisions from Payroll history review" do
      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: "legacy_tax_bases", warning_digest: "a" * 64, note: "Attempt direct acknowledgement"
      } }

      expect(response.status).to eq(422)
      expect(response.parsed_body.fetch("error")).to include("Payroll history review")
      expect(YearEndAcknowledgement.exists?(company: company, warning_code: "legacy_tax_bases")).to be(false)
    end

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

    it "uses role defaults only after an explicit bulk write and accepts a per-employee override" do
      role = CompanyJobRole.create!(company: company, name: "Server", occupation_code: "102")
      employee.update!(company_job_role: role, job_title: role.name)
      second = create(:employee, company: company)
      [ employee, second ].each do |worker|
        pay(company, Date.new(2026, 5, 8), worker: worker, reported_tips: 200, cash_tips_reported: 200,
          social_security_taxable_wages: 1_800, social_security_taxable_tips: 200)
      end
      path = "/api/v1/admin/year_end/tipped_occupations"
      input = { tax_year: 2026, use_role_code: true, employee_ids: [ employee.id, second.id ] }
      post path, params: input, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_tipped_occupations).to be_empty
      expect(response.parsed_body.fetch("error")).to include(second.full_name)
      post path, params: input.merge(overrides: { second.id.to_s => "000" },
        expected_role_codes: { employee.id.to_s => "000" }), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Role codes changed", employee.full_name)

      post path, params: input.merge(overrides: { second.id.to_s => "000" }), as: :json
      expect(response).to have_http_status(:created), response.body
      expect(employee.employee_tipped_occupations.sole.occupation_code).to eq("102")
      expect(second.employee_tipped_occupations.sole.occupation_code).to eq("000")
      expect(second.employee_tipped_occupations.sole.effective_to).to be_nil
    end

    it "sets an audited Box 14b code in bulk, enables sign-off, and invalidates readiness after a change" do
      item = pay(company, Date.new(2026, 5, 8), worker: employee, reported_tips: 200, cash_tips_reported: 200,
        social_security_taxable_wages: 1_800, social_security_taxable_tips: 200)
      original_payroll = item.attributes
      record_decision(filing_types: %w[w2_gu], party: "cornerstone")
      mark_ready
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(response.parsed_body["year_end_blockers"]).to include(hash_including("warning_code" => "tipped_occupation_code_missing"))

      bulk = "/api/v1/admin/year_end/tipped_occupations"
      post bulk, params: { tax_year: 2026, occupation_code: "102", employee_ids: [ employee.id, -1 ] }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_tipped_occupations).to be_empty

      post bulk, params: { tax_year: 2026, occupation_code: "102", employee_ids: [ employee.id ] }
      expect(response).to have_http_status(:created), response.body
      occupation = employee.employee_tipped_occupations.sole
      expect(occupation.effective_from).to eq(Date.new(2026, 1, 1))
      expect(occupation.effective_to).to be_nil
      expect(checklist_step("review_warnings").dig("data", "warnings")).not_to include(hash_including("code" => "tipped_occupation_code_missing"))
      mark_ready
      expect(response).to have_http_status(:ok), response.body

      path = "/api/v1/admin/employees/#{employee.id}/tipped_occupations"
      post path, params: { occupation_code: "102", effective_from: "2026-06-01" }
      expect(response).to have_http_status(:unprocessable_entity)
      post path, params: { occupation_code: "101", effective_from: "2026-06-01", effective_to: "2026-12-31", replace_id: occupation.id }
      expect(response).to have_http_status(:created), response.body
      expect(occupation.reload.effective_to).to eq(Date.new(2026, 5, 31))

      replacement_row = response.parsed_body.fetch("data").first
      expect(replacement_row.fetch("effective_to")).to eq("2026-12-31")
      replacement_id = replacement_row.fetch("id")
      expect(checklist_step("mark_ready").dig("data", "filing", "stale")).to be(true)
      post path, params: { occupation_code: "000", effective_from: "2026-09-01", replace_id: replacement_id }
      expect(response).to have_http_status(:created), response.body
      row = W2GuAggregator.new(company, 2026).generate.fetch(:employees).sole
      expect(row.fetch(:box14b_tipped_occupation_codes)).to include("000")
      expect(row.fetch(:box14b_tipped_occupation_codes).size).to eq(2)
      expect(item.reload.attributes).to eq(original_payroll)
      expect(checklist_step("review_warnings").dig("data", "warnings")).to include(hash_including("code" => "box14b_more_than_two_codes"))

      delete "#{path}/#{occupation.id}"
      expect(response).to have_http_status(:ok), response.body
      expect(employee.employee_tipped_occupations.exists?(occupation.id)).to be(false)
      expect(AuditLog.where(user: admin, company: company, record_type: "Employee", record_id: employee.id)
        .where("action LIKE ?", "employee_tipped_occupation#%").order(:id).pluck(:action))
        .to eq(%w[employee_tipped_occupation#add employee_tipped_occupation#change employee_tipped_occupation#change employee_tipped_occupation#remove])
    end

    it "ends a bulk assignment immediately before a later scheduled occupation" do
      pay(company, Date.new(2026, 5, 8), worker: employee, reported_tips: 200, cash_tips_reported: 200,
        social_security_taxable_wages: 1_800, social_security_taxable_tips: 200)
      scheduled = create(:employee_tipped_occupation, employee: employee, occupation_code: "101", effective_from: Date.new(2027, 3, 1))

      post "/api/v1/admin/year_end/tipped_occupations", params: { tax_year: "02026", occupation_code: "102", employee_ids: [ employee.id ] }
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body).to eq("count" => 1, "capped_count" => 1)
      expect(employee.employee_tipped_occupations.find_by!(occupation_code: "102").effective_to).to eq(Date.new(2027, 2, 28))
      expect(scheduled.reload.effective_from).to eq(Date.new(2027, 3, 1))
    end

    it "changes and ends an occupation while preserving a concurrent code and its own history" do
      original = create(:employee_tipped_occupation, employee: employee, occupation_code: "101",
        effective_from: Date.new(2026, 1, 1), effective_to: Date.new(2026, 12, 31))
      path = "/api/v1/admin/employees/#{employee.id}/tipped_occupations"
      post path, params: { occupation_code: "102", effective_from: "2026-01-01" }
      expect(response).to have_http_status(:created), response.body

      post path, params: { occupation_code: "000", effective_from: "2026-06-01", effective_to: "", replace_id: original.id }
      expect(response).to have_http_status(:created), response.body
      replacement = employee.employee_tipped_occupations.find_by!(occupation_code: "000")
      expect(replacement.effective_to).to be_nil
      expect(original.reload.effective_to).to eq(Date.new(2026, 5, 31))

      patch "#{path}/#{replacement.id}", params: { effective_to: "2026-05-01" }
      expect(response).to have_http_status(:unprocessable_entity)
      patch "#{path}/#{replacement.id}", params: { effective_to: "2026-08-31" }
      expect(response).to have_http_status(:ok), response.body
      expect(replacement.reload.effective_to).to eq(Date.new(2026, 8, 31))
      expect(employee.employee_tipped_occupations.count).to eq(3)
      expect(AuditLog.where(user: admin, record_id: employee.id, action: "employee_tipped_occupation#end")).to exist
    end

    it "blocks removal for a filed W-2 year within the entry's range" do
      open_entry = create(:employee_tipped_occupation, employee: employee, occupation_code: "101", effective_from: Date.new(2025, 6, 1))
      historical_entry = create(:employee_tipped_occupation, employee: employee, occupation_code: "102",
        effective_from: Date.new(2025, 6, 1), effective_to: Date.new(2025, 12, 31))
      PayrollFilingRecord.create!(company: company, filing_type: "w2_gu_w3_ss", tax_year: 2026,
        status: "submitted", submitted_at: Time.current, confirmation_number: "TEST-W2", source_fingerprint: "a" * 64)
      path = "/api/v1/admin/employees/#{employee.id}/tipped_occupations"

      delete "#{path}/#{open_entry.id}"
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(response.parsed_body.fetch("error")).to include("2026", "Use End or Change")
      expect(employee.employee_tipped_occupations.exists?(open_entry.id)).to be(true)
      expect(AuditLog.where(record_id: employee.id, action: "employee_tipped_occupation#remove")).to be_empty

      delete "#{path}/#{historical_entry.id}"
      expect(response).to have_http_status(:ok), response.body
      expect(employee.employee_tipped_occupations.exists?(historical_entry.id)).to be(false)
    end

    it "accepts bulk assignments for a later year with a configured wage base" do
      create(:annual_tax_config, tax_year: 2027)
      pay(company, Date.new(2027, 5, 7), worker: employee, reported_tips: 200, cash_tips_reported: 200,
        social_security_taxable_wages: 1_800, social_security_taxable_tips: 200)

      post "/api/v1/admin/year_end/tipped_occupations", params: { tax_year: 2027, occupation_code: "102", employee_ids: [ employee.id ] }
      expect(response).to have_http_status(:created), response.body
      expect(employee.employee_tipped_occupations.sole.effective_from).to eq(Date.new(2027, 1, 1))
    end

    it "returns JSON for a missing required field" do
      post "/api/v1/admin/employees/#{employee.id}/tipped_occupations", params: { occupation_code: "102" }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("error" => "Effective from is required.")
    end

    %w[accountant client employee].each do |role|
      it "denies a #{role} without staff client configuration access" do
        user = create(:user, company: company, role: role)
        allow_any_instance_of(Api::V1::Admin::EmployeeTippedOccupationsController).to receive(:current_user).and_return(user)

        post "/api/v1/admin/employees/#{employee.id}/tipped_occupations", params: { occupation_code: "102", effective_from: "2026-01-01" }
        expect(response).to have_http_status(:forbidden), response.body
        expect(employee.employee_tipped_occupations).to be_empty
      end
    end

    it "rejects writes to an employee outside the selected company" do
      other_company = create(:company, organization: company.organization)
      other_employee = create(:employee, company: other_company, department: create(:department, company: other_company))

      post "/api/v1/admin/employees/#{other_employee.id}/tipped_occupations", params: { occupation_code: "102", effective_from: "2026-01-01" }
      expect(response).to have_http_status(:not_found), response.body
      expect(other_employee.employee_tipped_occupations).to be_empty
    end

    it "refuses mark-ready for an employee e-file issue with the employee ID" do
      pay(company, Date.new(2026, 3, 6), worker: employee)
      employee.update_columns(state: "ZZ")
      record_decision(filing_types: %w[w2_gu], party: "cornerstone")
      mark_ready
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["year_end_blockers"]).to include(hash_including("code" => "EMPLOYEE_EFILE_INVALID", "employee_id" => employee.id))
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
        expect(PortalNotificationEvent.where(company: company, event_type: "w2_ready_to_post")).to be_empty
        decision = checklist_step("filing_decision")
        expect(decision["issues"].map { |issue| issue["code"] }).to eq(%w[FORM_1099_FILER_NOT_CHOSEN])
        expect(checklist_step("reconciliation")["status"]).to eq("done")
        expect(response.parsed_body.dig("data", "status")).to eq("needs_action")
      end

      it "queues the account team when 2026 employee tax forms are ready to post", :portal_notifications do
        company.client_operating_profiles.create!(effective_on: Date.new(2026, 1, 1), version: 1,
          offering: "payroll_service", hours_source: "manual", employee_portal_enabled: true,
          options: { employee_portal: { features: { tax_forms: true } } })
        activate_employee_app!(company)
        account_team = create(:user, role: "admin", company: company)
        list_portal_recipient!(company, user: account_team)
        with_portal_email do
          mark_ready
          expect(response).to have_http_status(:ok), response.body

          event = PortalNotificationEvent.find_by!(company: company, event_type: "w2_ready_to_post")
          expect(event.metadata).to eq("tax_year" => 2026, "revision" => 1)
          expect(event.deliveries.sole).to have_attributes(user_id: account_team.id, status: "pending", delivery_mode: "immediate")
        end
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

    it "refuses to mark ready when an input outside the W-2 fingerprint changes while the checklist is checked" do
      item = pay(company, Date.new(2026, 3, 6), worker: employee)
      record_decision(filing_types: %w[w2_gu form_1099], party: "cornerstone")
      allow_any_instance_of(YearEnd::Checklist).to receive(:w2_mark_ready_blockers).and_wrap_original do |original|
        blockers = original.call
        # Employer tax feeds the 941 review but not the W-2 fingerprint.
        item.update!(employer_social_security_tax: 0)
        blockers
      end

      mark_ready

      expect(response).to have_http_status(:conflict), response.body
      expect(W2FilingReadiness.find_by!(company: company, year: 2026)).to have_attributes(ready_fingerprint: nil)
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
