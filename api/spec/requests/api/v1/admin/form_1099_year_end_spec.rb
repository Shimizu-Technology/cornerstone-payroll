# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "1099 payees, sign-off and official copies", type: :request do
  let!(:company) do
    create(:company, name: "Tumon Bakery", ein: "98-7654321", address_line1: "123 Marine Corps Dr", city: "Tamuning",
      state: "GU", zip: "96913", phone: "671-555-0100", email: "office@tumonbakery.example")
  end
  let!(:department) { create(:department, company: company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:threshold_2026) { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }
  let!(:cruz) do
    create(:employee, :contractor, company: company, department: department, first_name: "Ana", last_name: "Cruz",
      ssn_encrypted: "345-67-7890", address_line1: "7 Route 8", city: "Maite", state: "GU", zip: "96910", w9_on_file: true)
  end
  let(:acting_user) { admin }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    [
      Api::V1::Admin::YearEndController, Api::V1::Admin::ReportsController,
      Api::V1::Admin::PayrollFilingResponsibilitiesController, Api::V1::Admin::PayrollFilingRecordsController,
      Api::V1::Admin::NonEmployeeChecksController
    ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user) { acting_user }
      allow_any_instance_of(controller).to receive(:current_company_id) { company.id }
    end
  end

  def pay_contractor(worker, amount, pay_date: Date.new(2026, 5, 8))
    period = PayPeriod.find_by(company: company, pay_date: pay_date) ||
      create(:pay_period, :committed, company: company, start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    create(:payroll_item, company: company, employee: worker, pay_period: period, employment_type: "contractor",
      gross_pay: amount, net_pay: amount, withholding_tax: 0, social_security_tax: 0, medicare_tax: 0,
      employer_social_security_tax: 0, employer_medicare_tax: 0)
  end

  def contractor_check(amount, number, payable_to: "Ana Cruz")
    create(:non_employee_check, company: company, check_type: "contractor", payable_to: payable_to, amount: amount,
      check_number: number, payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 6, 5), printed_at: Time.current)
  end

  def decide(w2: "client", form_1099: "cornerstone")
    { "w2_gu" => w2, "form_1099" => form_1099 }.each do |filing_type, party|
      put "/api/v1/admin/payroll_filing_responsibilities", params: {
        responsibility: { tax_year: 2026, filing_types: [ filing_type ], responsible_party: party, imported_payroll_inclusion: "included" }
      }
      expect(response).to have_http_status(:ok), response.body
    end
  end

  def checklist
    get "/api/v1/admin/year_end/checklist", params: { year: 2026 }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("data")
  end

  def step(key, data = checklist)
    data.fetch("steps").find { |entry| entry["key"] == key }
  end

  def one_off_payee
    step("people").dig("data", "one_off_payees").sole
  end

  def link(payee, employee)
    post "/api/v1/admin/year_end/one_off_payees/link", params: { payee: { tax_year: 2026, code: payee["code"], digest: payee["digest"], employee_id: employee.id } }
  end

  def unlink(check_ids, employee)
    post "/api/v1/admin/year_end/one_off_payees/unlink", params: { payee: { tax_year: 2026, employee_id: employee.id, check_ids: check_ids } }
  end

  def mark_ready(fingerprint = step("form_1099_ready").dig("data", "inputs_fingerprint"), notes: "Checked against the W-9s")
    post "/api/v1/admin/year_end/form_1099_mark_ready", params: { form_1099: { tax_year: 2026, inputs_fingerprint: fingerprint, notes: notes } }
  end

  def download(kind, year: 2026)
    get "/api/v1/admin/reports/#{kind == 'payer' ? 'form_1099_nec_payer_record' : 'form_1099_nec_recipient_copies'}", params: { year: year }
  end

  def pdf_text
    PDF::Reader.new(StringIO.new(response.body)).pages.flat_map { |page| [ page.text, *pdf_rows(page) ] }.join("\n")
  end

  def copy_logs
    AuditLog.where(action: %w[reports#form_1099_nec_recipient_copies reports#form_1099_nec_payer_record]).order(:id)
  end

  def report_rows
    Form1099NecAggregator.new(company, 2026).generate[:reportable_contractors]
  end

  describe "resolving a one-off payee" do
    before do
      pay_contractor(cruz, 1_500)
      contractor_check(1_500, "9001")
      contractor_check(1_000, "9002")
      decide
    end

    it "links the checks to an existing contractor, so one 1099 carries both payments" do
      payee = one_off_payee
      expect(payee).to include("name" => "Ana Cruz", "total_compensation" => 2_500.0, "status" => "needs_identity")
      people = step("people")
      expect(people["issues"]).to include(a_hash_including("code" => "PAYEE_IDENTITY_UNRESOLVED", "payee_key" => payee["payee_key"]))
      candidate = people.dig("data", "link_candidates").sole
      expect(candidate).to include("employee_id" => cruz.id, "tin_last4" => "7890", "name_matches" => true)
      # No contractor row yet, but the unresolved payee may become a 1099, so the sign-off stays open.
      expect(step("form_1099_ready")).to include("status" => "action_needed")
      expect(step("form_1099_ready").dig("data", "can_mark_ready")).to be(false)
      # Below the threshold on payroll alone, so no 1099 of its own yet.
      expect(report_rows.map { |row| row[:name] }).to eq([ "Ana Cruz" ])
      expect(report_rows.sole[:employee_id]).to be_nil

      link(payee, cruz)

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("data", "employee")).to include("id" => cruz.id, "created" => false)
      rows = report_rows
      expect(rows.length).to eq(1)
      expect(rows.sole).to include(employee_id: cruz.id, total_compensation: 4_000.0, payment_count: 3, payroll_payment_count: 1)
      expect(rows.sole[:non_employee_check_ids]).to eq(NonEmployeeCheck.order(:id).pluck(:id))

      people = step("people")
      expect(people["status"]).to eq("done")
      expect(people.dig("data", "one_off_payees")).to be_empty
      expect(people.dig("data", "linked_checks").sole).to include("employee_id" => cruz.id, "name" => "Ana Cruz", "total" => 2_500.0)

      log = AuditLog.find_by!(action: "year_end_one_off_payees#linked")
      expect(log).to have_attributes(user_id: admin.id, company_id: company.id, record_id: cruz.id)
      expect(log.metadata).to include("payee_name" => "Ana Cruz", "employee_id" => cruz.id, "tin_type" => "SSN", "tin_last4" => "7890", "total" => "2500.0")
      expect(log.to_json).not_to include("345-67", "345677890")
      expect(NonEmployeeCheckEdit.order(:id).map(&:changed_fields)).to eq([ [ "payee_employee_id" ] ] * 2)
    end

    it "refuses a link made on checks that changed since, to a non-contractor, or twice" do
      payee = one_off_payee
      contractor_check(300, "9003")
      link(payee, cruz)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to include("checks changed")

      payee = one_off_payee
      w2_worker = create(:employee, company: company, department: department)
      link(payee, w2_worker)
      expect(response).to have_http_status(:unprocessable_content)

      other = create(:company, organization: company.organization)
      outside = create(:employee, :contractor, company: other, department: create(:department, company: other))
      link(payee, outside)
      expect(response).to have_http_status(:unprocessable_content)

      link(payee, cruz)
      expect(response).to have_http_status(:ok), response.body
      link(payee, cruz)
      expect(response).to have_http_status(:conflict)
      expect(NonEmployeeCheck.distinct.pluck(:payee_employee_id)).to eq([ cruz.id ])
    end

    it "keeps the database from linking a check to another client's contractor" do
      other = create(:company, organization: company.organization)
      outside = create(:employee, :contractor, company: other, department: create(:department, company: other))

      expect { NonEmployeeCheck.first.update_columns(payee_employee_id: outside.id) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "undoes a link, returning the checks to the one-off list" do
      link(one_off_payee, cruz)
      ids = step("people").dig("data", "linked_checks", 0, "checks").map { |check| check["id"] }

      unlink(ids, cruz)

      expect(response).to have_http_status(:ok), response.body
      expect(one_off_payee).to include("name" => "Ana Cruz", "status" => "needs_identity")
      expect(AuditLog.find_by!(action: "year_end_one_off_payees#unlinked").metadata["checks"].map { |check| check["previous_employee_id"] }).to eq([ cruz.id, cruz.id ])
      unlink(ids, cruz)
      expect(response).to have_http_status(:conflict)
    end

    it "unlinks a linked check when its payee is renamed, so it is resolved again" do
      link(one_off_payee, cruz)
      first, second = NonEmployeeCheck.order(:id).to_a

      patch "/api/v1/admin/non_employee_checks/#{first.id}", params: { non_employee_check: { payable_to: "Island Supply" }, reason: "Wrong payee" }

      expect(response).to have_http_status(:ok), response.body
      expect(first.reload.payee_employee_id).to be_nil
      expect(second.reload.payee_employee_id).to eq(cruz.id)
      expect(step("people").dig("data", "one_off_payees")).to be_empty
      expect(step("people").dig("data", "smaller_one_off_payees").map { |payee| payee["name"] }).to eq([ "Island Supply" ])
      edit = first.edits.select { |entry| entry.changed_fields == [ "payee_employee_id" ] }.max_by(&:id)
      expect(edit).to have_attributes(before: { "payee_employee_id" => cruz.id }, after: { "payee_employee_id" => nil }, edited_by_id: admin.id,
        reason: "Payee changed from Ana Cruz to Island Supply, so the check is no longer linked to Ana Cruz for the 1099-NEC")
      expect(first.edits.map(&:changed_fields)).to include([ "payable_to" ])
      log = AuditLog.where(action: "year_end_one_off_payees#unlinked").sole
      expect(log).to have_attributes(user_id: admin.id, company_id: company.id, record_id: first.id)
      expect(log.metadata).to include("reason" => "payee_renamed")
      expect(log.metadata["checks"].sole).to include("previous_employee_id" => cruz.id, "previous_payable_to" => "Ana Cruz", "payable_to" => "Island Supply")

      # Any save path, not only the editor; an unchanged name keeps the link.
      second.update!(memo: "June work")
      expect(second.reload.payee_employee_id).to eq(cruz.id)
      second.update!(payable_to: "A. Cruz")
      expect(second.reload.payee_employee_id).to be_nil
      expect(AuditLog.where(action: "year_end_one_off_payees#unlinked").count).to eq(2)
    end

    it "refuses a stale undo after the checks were relinked to another contractor" do
      santos = create(:employee, :contractor, company: company, department: department, first_name: "Ben", last_name: "Santos",
        ssn_encrypted: "456-78-9012", address_line1: "9 Route 4", city: "Sinajana", state: "GU", zip: "96910", w9_on_file: true)
      link(one_off_payee, cruz)
      ids = step("people").dig("data", "linked_checks", 0, "checks").map { |check| check["id"] }
      unlink(ids, cruz)
      expect(response).to have_http_status(:ok), response.body
      link(one_off_payee, santos)
      expect(response).to have_http_status(:ok), response.body
      edits = NonEmployeeCheckEdit.count

      # A second tab still shows "linked to Ana Cruz" and sends the undo again.
      unlink(ids, cruz)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to include("no longer linked to that contractor")
      expect(NonEmployeeCheck.where(id: ids).pluck(:payee_employee_id)).to eq([ santos.id, santos.id ])
      expect(NonEmployeeCheckEdit.count).to eq(edits)
      expect(AuditLog.where(action: "year_end_one_off_payees#unlinked").count).to eq(1)

      post "/api/v1/admin/year_end/one_off_payees/unlink", params: { payee: { tax_year: 2026, check_ids: ids } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(NonEmployeeCheck.where(id: ids).pluck(:payee_employee_id)).to eq([ santos.id, santos.id ])
    end

    it "lets an accountant resolve payees but not someone without access to the client" do
      accountant = create(:user, company: company, organization: company.organization, role: "accountant")
      create(:company_assignment, user: accountant, company: company, client_management: false, granted_by: admin)
      outsider_company = create(:company)
      outsider = create(:user, company: outsider_company, organization: outsider_company.organization, role: "admin")
      payee = one_off_payee

      allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user).and_return(outsider)
      link(payee, cruz)
      expect(response).to have_http_status(:forbidden)

      allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user).and_return(accountant)
      link(payee, cruz)
      expect(response).to have_http_status(:ok), response.body
    end
  end

  describe "adding a contractor from the payee's W-9" do
    before do
      contractor_check(2_400, "9001", payable_to: "Island Roofing")
      decide
    end

    def add(payee, **contractor)
      post "/api/v1/admin/year_end/one_off_payees/contractor", params: { payee: { tax_year: 2026, code: payee["code"], digest: payee["digest"], contractor: contractor } }
    end

    let(:business) do
      { contractor_type: "business", first_name: "Pedro", last_name: "Reyes", business_name: "Island Roofing LLC", tin: "66-1234567",
        address_line1: "PO Box 8800", city: "Tamuning", state: "gu", zip: "96931", w9_on_file: "1" }
    end

    it "creates an inactive contractor record with the TIN and links the checks to it" do
      add(one_off_payee, **business)

      expect(response).to have_http_status(:created), response.body
      employee = Employee.find(response.parsed_body.dig("data", "employee", "id"))
      expect(employee).to have_attributes(employment_type: "contractor", contractor_type: "business", business_name: "Island Roofing LLC",
        status: "inactive", state: "GU", w9_on_file: true, hire_date: Date.new(2026, 6, 5), pay_rate: 0)
      expect(employee.form_1099_tin).to eq(type: "EIN", digits: "661234567")
      expect(NonEmployeeCheck.sole.payee_employee_id).to eq(employee.id)
      # Kept out of payroll runs: it exists to hold the TIN and address.
      expect(Employee.eligible_for_period(Date.new(2026, 7, 1), Date.new(2026, 7, 14))).not_to include(employee)
      expect(report_rows.sole).to include(employee_id: employee.id, total_compensation: 2_400.0)
      log = AuditLog.find_by!(action: "year_end_one_off_payees#contractor_created")
      expect(log.metadata).to include("contractor_created" => true, "tin_type" => "EIN", "tin_last4" => "4567")
      expect(log.to_json).not_to include("66-1234567", "661234567")
    end

    it "refuses a TIN another contractor of the client already has, so one payee never gets two 1099s" do
      create(:employee, :business_contractor, company: company, department: department, first_name: "Pedro", last_name: "Reyes",
        business_name: "Island Roofing", contractor_ein: "661234567", w9_on_file: true)

      expect { add(one_off_payee, **business) }.not_to change(Employee, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("Pedro Reyes already has this TIN. Link the checks to Pedro Reyes instead, so they get one 1099.")
      expect(NonEmployeeCheck.sole.payee_employee_id).to be_nil
    end

    it "refuses a record without a full TIN or a complete address" do
      employees = Employee.count
      add(one_off_payee, **business, tin: "66-12")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("Enter the 9-digit EIN from the W-9.")

      add(one_off_payee, **business, city: "")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("City can't be blank")
      expect(Employee.count).to eq(employees)
      expect(NonEmployeeCheck.sole.payee_employee_id).to be_nil
    end
  end

  describe "the no-1099-due path" do
    before do
      contractor_check(2_500, "9001", payable_to: "Guam Power Authority")
      decide
    end

    it "clears the payee, prints no 1099 for it, and asks again for an identification recorded before this meaning" do
      payee = one_off_payee
      legacy = YearEnd::JudgmentWarnings.digest_for(payee["code"], [ [ [ NonEmployeeCheck.sole.id, "2500.0" ] ], "2500.0", "Guam Power Authority" ])
      YearEndAcknowledgement.create!(company: company, tax_year: 2026, warning_code: payee["code"], warning_digest: legacy, note: "GPA, utility",
        acknowledged_by: admin, acknowledged_by_name: admin.name, acknowledged_by_email: admin.email, acknowledged_by_role: admin.role, acknowledged_at: Time.current)
      expect(one_off_payee).to include("status" => "needs_identity", "acknowledgement_stale" => true)

      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: payee["code"], warning_digest: payee["digest"], note: "Utility bill, not services. No 1099."
      } }
      expect(response).to have_http_status(:created), response.body

      data = checklist
      expect(step("people", data)["status"]).to eq("done")
      expect(step("form_1099_ready", data)).to include("status" => "done")
      expect(step("form_1099_ready", data).dig("data", "no_1099_due_count")).to eq(1)
      expect(step("form_1099_ready", data)["summary"]).to include("no 1099s to mark ready")
      expect(data["status"]).to eq("ready")
      # Nothing to file: Print and file says so and offers no e-file or 1096.
      print_and_file = step("print_and_file", data)
      expect(print_and_file["summary"]).to eq("No 1099 filings are needed for 2026: no payee gets a 1099.")
      expect(print_and_file.dig("data", "no_1099_filings")).to be(true)
      documents = print_and_file.dig("data", "documents").index_by { |document| document["key"] }
      expect(documents.values_at("form_1099_pub1220", "form_1096_totals"))
        .to all(include("available" => false, "unavailable_reason" => "No 1099 filings are needed for 2026: no payee gets a 1099."))
      expect(documents["form_1099_recipient_copies"]).to include("available" => false)
      download("recipient")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "keeps the draft guidance while a one-off payee is undecided" do
      print_and_file = step("print_and_file")
      expect(print_and_file["summary"]).to start_with("Drafts until the 1099s are marked ready")
      expect(print_and_file.dig("data", "no_1099_filings")).to be(false)
      documents = print_and_file.dig("data", "documents").index_by { |document| document["key"] }
      expect(documents["form_1099_pub1220"]).to include("available" => false, "unavailable_reason" => a_string_including("Resolve the one-off payees"))
    end
  end

  describe "marking the 1099s ready" do
    before do
      pay_contractor(cruz, 2_500)
      decide
    end

    it "records an audited sign-off on the inputs the reviewer saw" do
      fingerprint = step("form_1099_ready").dig("data", "inputs_fingerprint")
      expect(step("form_1099_ready")).to include("number" => 4, "status" => "action_needed")
      expect(step("form_1099_ready").dig("data", "payees").sole).to include("name" => "Ana Cruz", "tin_last4" => "7890", "total_compensation" => 2_500.0,
        "federal_withheld" => 0.0, "filing_reason" => "filing threshold reached")

      mark_ready(fingerprint)

      expect(response).to have_http_status(:ok), response.body
      readiness = Form1099FilingReadiness.find_by!(company: company, tax_year: 2026)
      expect(readiness).to have_attributes(ready_fingerprint: fingerprint, marked_ready_by_id: admin.id, payee_count: 1,
        total_compensation: 2_500, notes: "Checked against the W-9s")
      expect(readiness.attestation_history.sole).to include("source_fingerprint" => fingerprint, "payee_count" => 1)
      expect(AuditLog.find_by!(action: "year_end#form_1099_mark_ready").metadata).to include("inputs_fingerprint" => fingerprint, "payee_count" => 1)
      expect(step("form_1099_ready")["status"]).to eq("done")
      expect(Form1099FilingReadiness.final?(company: company, year: 2026, readiness: readiness, fingerprint: fingerprint)).to be(true)
    end

    it "refuses inputs other than the ones the reviewer saw" do
      fingerprint = step("form_1099_ready").dig("data", "inputs_fingerprint")
      pay_contractor(cruz, 100, pay_date: Date.new(2026, 7, 3))

      mark_ready(fingerprint)
      expect(response).to have_http_status(:conflict)
      mark_ready(nil)
      expect(response).to have_http_status(:conflict)
      expect(Form1099FilingReadiness.count).to eq(0)
    end

    it "refuses while a 1099 item is open, naming it, and never waits on the W-2s" do
      cruz.update_columns(city: nil)
      mark_ready
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["year_end_blockers"]).to contain_exactly(a_hash_including("code" => "PAYEE_DETAILS_MISSING", "employee_id" => cruz.id))

      cruz.update_columns(city: "Maite")
      # A W-2 problem (an employee with no SSN, the contact name) is no reason to hold the 1099s.
      decide(w2: "cornerstone")
      company.update_columns(filing_contact_name: nil)
      w2_worker = create(:employee, company: company, department: department)
      w2_worker.update_columns(ssn_encrypted: nil)
      period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 14), pay_date: Date.new(2026, 2, 20))
      create(:payroll_item, company: company, employee: w2_worker, pay_period: period, gross_pay: 1_000, fit_taxable_wages: 1_000)
      data = checklist
      expect(step("people", data)["issues"].map { |issue| issue["code"] }).to include("EMPLOYEE_DETAILS_MISSING")
      expect(step("form_1099_ready", data).dig("data", "can_mark_ready")).to be(true)

      mark_ready
      expect(response).to have_http_status(:ok), response.body
      # ...and the 1099 sign-off never holds up the W-2s.
      expect(step("mark_ready")).to include("number" => 8)
      expect(YearEnd::Checklist.new(company: company, year: 2026).w2_mark_ready_blockers.map { |issue| issue[:code] }).not_to include("FORM_1099_NOT_MARKED_READY")
    end

    it "refuses copies that wouldn't print, naming each one" do
      cruz.update_columns(address_line1: "Lot 1234 Unit 5678 Barrigada Heights " * 8)

      mark_ready

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["problems"]).to eq([
        "Ana Cruz: the street address is too long to fit the recipient's address box — shorten it on the contractor's record.",
        "Ana Cruz: the address is longer than 40 characters — shorten it on the profile."
      ])
    end

    it "refuses an address the copies fit but the e-file can't, so every signed-off client can e-file" do
      cruz.update!(address_line1: "123 North Marine Corps Drive", address_line2: "Building 7 Unit 215")
      expect(Form1099NecOfficialCopies.new(company: company, report: Form1099NecAggregator.new(company, 2026).generate, kind: "payer", draft: true).problems).to be_empty

      mark_ready

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("wouldn't print or e-file")
      expect(response.parsed_body["problems"]).to eq([ "Ana Cruz: the address is longer than 40 characters — shorten it on the profile." ])
      expect(Form1099FilingReadiness.count).to eq(0)

      cruz.update!(address_line1: "123 N Marine Corps Dr", address_line2: "Bldg 7 Unit 215")
      mark_ready
      expect(response).to have_http_status(:ok), response.body
    end

    it "refuses when the inputs change while they are checked" do
      calls = 0
      allow_any_instance_of(Form1099InputsFingerprint).to receive(:call).and_wrap_original do |original, *args|
        calls += 1
        # Payroll that skipped the company lock commits during the checks.
        pay_contractor(cruz, 50, pay_date: Date.new(2026, 8, 7)) if calls == 2
        original.call(*args)
      end
      fingerprint = step("form_1099_ready").dig("data", "inputs_fingerprint")
      calls = 0

      mark_ready(fingerprint)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to include("changed while they were being checked")
      expect(Form1099FilingReadiness.count).to eq(0)
    end

    it "goes stale when a payee's TIN, name or address, an amount, a link or the payer changes" do
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      readiness = -> { Form1099FilingReadiness.find_by!(company: company, tax_year: 2026) }
      current = -> { readiness.call.current?(Form1099InputsFingerprint.new(company: company.reload, year: 2026).call) }
      expect(current.call).to be(true)

      changes = [
        -> { cruz.update_columns(ssn_encrypted: "345-67-0001") },
        -> { cruz.update_columns(address_line2: "Unit 2") },
        -> { cruz.update_columns(middle_name: "B") },
        -> { company.update_columns(name: "Tumon Bakery Inc") },
        -> { company.update_columns(phone: "671-555-0199") },
        -> { pay_contractor(cruz, 10, pay_date: Date.new(2026, 9, 4)) },
        -> { contractor_check(600, "9100").update_columns(payee_employee_id: cruz.id) }
      ]
      changes.each do |change|
        change.call
        expect(current.call).to be(false)
        data = checklist
        expect(step("form_1099_ready", data)).to include("status" => "action_needed")
        expect(step("form_1099_ready", data).dig("data", "readiness", "stale")).to be(true)
        mark_ready
        expect(response).to have_http_status(:ok), response.body
        expect(current.call).to be(true)
      end
      expect(readiness.call.attestation_history.length).to eq(changes.length + 1)
    end

    it "needs client-management access and is blocked in a practice copy" do
      accountant = create(:user, company: company, organization: company.organization, role: "accountant")
      assignment = create(:company_assignment, user: accountant, company: company, client_management: false, granted_by: admin)
      fingerprint = step("form_1099_ready").dig("data", "inputs_fingerprint")
      allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user).and_return(accountant)
      mark_ready(fingerprint)
      expect(response).to have_http_status(:forbidden)

      assignment.update!(client_management: true)
      mark_ready(fingerprint)
      expect(response).to have_http_status(:ok), response.body

      source = create(:company, organization: company.organization)
      company.update_columns(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
        migration_source_company_id: source.id, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
      allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user).and_return(admin)
      mark_ready
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to include("unavailable in a test workspace")
      expect(step("form_1099_ready").dig("data", "unavailable_reason")).to eq("Not available in a practice copy.")
    end
  end

  describe "smaller one-off checks" do
    def smaller_payee(data = checklist)
      step("people", data).dig("data", "smaller_one_off_payees").sole
    end

    def ready_state
      Form1099NecFilingState.call(company: company.reload, year: 2026)
    end

    it "lets a check below the threshold join a contractor whose pay is also below it, so the 1099 is issued" do
      pay_contractor(cruz, 1_500)
      contractor_check(1_000, "9001")
      decide

      data = checklist
      people = step("people", data)
      # Neither reaches $2,000 alone: nothing blocks, but the check is listed to link.
      expect(people.dig("data", "one_off_payees")).to be_empty
      expect(people["issues"].map { |issue| issue["code"] }).not_to include("PAYEE_IDENTITY_UNRESOLVED")
      payee = smaller_payee(data)
      expect(payee).to include("name" => "Ana Cruz", "total_compensation" => 1_000.0, "status" => "below_threshold", "could_reach_threshold" => true)
      expect(people.dig("data", "link_candidates").sole).to include("employee_id" => cruz.id, "name_matches" => true, "year_total" => 1_500.0)
      expect(step("form_1099_ready", data)).to include("status" => "done")
      expect(step("form_1099_ready", data)["summary"]).to include("1 smaller one-off payee could reach it")
      expect(step("form_1099_ready", data).dig("data", "smaller_could_reach_count")).to eq(1)

      link(payee, cruz)

      expect(response).to have_http_status(:ok), response.body
      expect(report_rows.sole).to include(employee_id: cruz.id, total_compensation: 2_500.0)
      data = checklist
      expect(step("people", data).dig("data", "smaller_one_off_payees")).to be_empty
      expect(step("form_1099_ready", data)).to include("status" => "action_needed")
      expect(step("form_1099_ready", data).dig("data", "payees").sole).to include("employee_id" => cruz.id, "total_compensation" => 2_500.0)
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      expect(ready_state.final).to be(true)
    end

    it "makes a signed-off 1099 stale when a smaller unlinked check arrives, until it is linked or re-approved" do
      pay_contractor(cruz, 3_000)
      decide
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      expect(ready_state.final).to be(true)

      contractor_check(1_000, "9001")

      expect(ready_state.final).to be(false)
      data = checklist
      expect(step("form_1099_ready", data)).to include("status" => "action_needed")
      expect(step("form_1099_ready", data).dig("data", "readiness", "stale")).to be(true)
      # Listed to link; not flagged, since it would only add to a 1099 already due.
      expect(smaller_payee(data)).to include("name" => "Ana Cruz", "could_reach_threshold" => false)

      link(smaller_payee, cruz)
      expect(response).to have_http_status(:ok), response.body
      expect(report_rows.sole).to include(employee_id: cruz.id, total_compensation: 4_000.0)
      expect(ready_state.final).to be(false)
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      expect(Form1099FilingReadiness.sole.total_compensation).to eq(4_000)
      expect(ready_state.final).to be(true)

      # A smaller check to someone else also expires the sign-off; staff who
      # leave it unlinked mark ready again on the same amounts.
      contractor_check(200, "9002", payable_to: "Island Ice")
      expect(ready_state.final).to be(false)
      data = checklist
      expect(smaller_payee(data)).to include("name" => "Island Ice", "could_reach_threshold" => false)
      expect(step("people", data)["issues"]).to be_empty
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      expect(ready_state.final).to be(true)
      # Changing that check's amount expires it again.
      NonEmployeeCheck.find_by!(check_number: "9002").update_columns(amount: 250)
      expect(ready_state.final).to be(false)
    end

    it "flags only the smaller payees that could make a contractor under the threshold reach it" do
      pay_contractor(cruz, 500)
      contractor_check(400, "9001", payable_to: "Island Ice")
      decide

      expect(smaller_payee).to include("name" => "Island Ice", "could_reach_threshold" => false)
      expect(step("form_1099_ready").dig("data", "smaller_could_reach_count")).to eq(0)

      reyes = create(:employee, :contractor, company: company, department: department, first_name: "Ben", last_name: "Reyes", w9_on_file: true)
      pay_contractor(reyes, 1_700)
      expect(smaller_payee).to include("name" => "Island Ice", "could_reach_threshold" => true)
      expect(step("form_1099_ready").dig("data", "smaller_could_reach_count")).to eq(1)
    end

    it "doesn't flag a smaller payee that would only add to a contractor already getting a 1099 for withholding" do
      pay_contractor(cruz, 500).update_columns(withholding_tax: 50)
      contractor_check(1_600, "9001", payable_to: "Island Ice")
      decide

      # $500 with $50 withheld is already reportable; $2,100 linked would only add to that 1099.
      expect(report_rows.sole).to include(employee_id: cruz.id, requires_filing: true, filing_reason: "tax withheld")
      expect(smaller_payee).to include("name" => "Island Ice", "could_reach_threshold" => false)
      expect(step("form_1099_ready").dig("data", "smaller_could_reach_count")).to eq(0)

      # The same amounts with nothing withheld: linking would make a 1099 due.
      cruz.payroll_items.sole.update_columns(withholding_tax: 0)
      expect(smaller_payee).to include("name" => "Island Ice", "could_reach_threshold" => true)
      expect(step("form_1099_ready").dig("data", "smaller_could_reach_count")).to eq(1)
    end
  end

  describe "a payee's W-9" do
    before do
      pay_contractor(cruz, 2_500)
      decide
      cruz.update!(w9_on_file: false)
    end

    it "blocks the 1099 sign-off until the W-9 is on file, never the W-2s, and expires it when unticked" do
      data = checklist
      issue = step("people", data)["issues"].find { |entry| entry["code"] == "PAYEE_W9_MISSING" }
      expect(issue).to include("employee_id" => cruz.id, "message" => a_string_including("W-9 is not on file"))
      expect(step("people", data).dig("data", "w9_missing").sole).to include("employee_id" => cruz.id, "edit_path" => "/companies/#{company.id}/employees/#{cruz.id}/edit")
      expect(step("form_1099_ready", data).dig("data", "blockers")).to contain_exactly(a_hash_including("code" => "PAYEE_W9_MISSING"))
      expect(YearEnd::Checklist.new(company: company, year: 2026).w2_mark_ready_blockers.map { |entry| entry[:code] }).not_to include("PAYEE_W9_MISSING")

      mark_ready
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["year_end_blockers"]).to contain_exactly(a_hash_including("code" => "PAYEE_W9_MISSING", "employee_id" => cruz.id))

      cruz.update!(w9_on_file: true)
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      expect(Form1099NecFilingState.call(company: company.reload, year: 2026).final).to be(true)

      cruz.update!(w9_on_file: false)
      expect(Form1099NecFilingState.call(company: company.reload, year: 2026).final).to be(false)
      expect(step("form_1099_ready")).to include("status" => "action_needed")
    end
  end

  describe "the e-file and 1096 share the 1099 sign-off" do
    before do
      pay_contractor(cruz, 2_500)
      decide
      FilingSubmitter.create!(organization: company.organization, ein: "66-7654321", name: "Practice", address_line1: "1 Main", city: "Hagatna",
        state: "GU", zip: "96910", contact_name: "Dafne", contact_phone: "6715551234", contact_email: "filing@example.com", bso_user_id: "ABCDEFGH", tcc: "ABCDE")
    end

    def efile(mode, kind: "form_1099_pub1220")
      get "/api/v1/admin/reports/#{kind}", params: { year: 2026, mode: mode }
    end

    it "is 409 before mark ready, downloadable after it, and 409 again once an input changes" do
      efile("final")
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("Mark the 1099s ready first")
      efile("final", kind: "form_1096_totals")
      expect(response).to have_http_status(:conflict)
      documents = step("print_and_file").dig("data", "documents").index_by { |document| document["key"] }
      expect(documents.values_at("form_1099_pub1220", "form_1096_totals")).to all(include("draft" => true))

      mark_ready
      expect(response).to have_http_status(:ok), response.body
      efile("final")
      expect(response).to have_http_status(:ok), response.body
      payee = response.body.lines.find { |line| line.start_with?("B") }
      # The same account number the official copies print.
      expect(payee[20, 20].strip).to eq(Form1099Pub1220Generator.account_number(cruz))
      expect(payee[54, 12].to_i).to eq(250_000)
      efile("final", kind: "form_1096_totals")
      expect(response).to have_http_status(:ok), response.body
      documents = step("print_and_file").dig("data", "documents").index_by { |document| document["key"] }
      expect(documents.values_at("form_1099_recipient_copies", "form_1099_payer_record", "form_1099_pub1220", "form_1096_totals"))
        .to all(include("draft" => false))
      expect(documents["form_1099_pub1220"].dig("download", "params", "mode")).to eq("final")

      cruz.update!(business_name: "Cruz Consulting")
      efile("final")
      expect(response).to have_http_status(:conflict)
      efile("draft")
      expect(response).to have_http_status(:ok), response.body
    end

    it "builds the e-file and 1096 from the payees signed off, leaving out a payee decided no 1099 due" do
      contractor_check(3_100, "9001", payable_to: "Guam Power Authority")
      payee = one_off_payee
      post "/api/v1/admin/year_end/acknowledgements", params: { acknowledgement: {
        tax_year: 2026, warning_code: payee["code"], warning_digest: payee["digest"], note: "Utility bill, not services. No 1099."
      } }
      expect(response).to have_http_status(:created), response.body
      # Still in the aggregator's reportable list, with no TIN or address.
      expect(report_rows.map { |row| row[:name] }).to contain_exactly("Ana Cruz", "Guam Power Authority")
      expect(step("form_1099_ready").dig("data", "payees").map { |row| row["name"] }).to eq([ "Ana Cruz" ])

      mark_ready
      expect(response).to have_http_status(:ok), response.body
      efile("final")

      expect(response).to have_http_status(:ok), response.body
      records = response.body.lines
      expect(records.map { |record| record[0] }).to eq(%w[T A B C F])
      expect(records[2][20, 20].strip).to eq(Form1099Pub1220Generator.account_number(cruz))
      expect(records[3][1, 8].to_i).to eq(1)
      expect(records[3][15, 18].to_i).to eq(250_000)
      expect(records[4][49, 8].to_i).to eq(1)
      expect(response.body).not_to include("GUAM POWER")

      efile("final", kind: "form_1096_totals")
      expect(response).to have_http_status(:ok), response.body
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Total forms: 1", "Box 1 nonemployee compensation: $2,500.00")
    end

    it "names an undecided one-off payee instead of leaving it out of a draft e-file" do
      contractor_check(3_100, "9001", payable_to: "Guam Power Authority")
      efile("draft")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["problems"]).to include(a_string_starting_with("Guam Power Authority: missing TIN and address; link this one-off payee"))
    end

    it "expires the sign-off when withholding, the account number or the name lines change" do
      mark_ready
      expect(response).to have_http_status(:ok), response.body
      current = -> { Form1099Readiness.final?(company: company.reload, year: 2026) }
      expect(current.call).to be(true)

      changes = [
        -> { cruz.payroll_items.first.update_columns(withholding_tax: 25) },
        -> { cruz.update_columns(business_name: "Cruz Consulting") },
        -> { cruz.update_columns(contractor_type: "business", contractor_ein: "66-1111111", ssn_encrypted: nil) }
      ]
      changes.each do |change|
        change.call
        expect(current.call).to be(false)
        mark_ready
        expect(response).to have_http_status(:ok), response.body
        expect(current.call).to be(true)
      end
      # The account number is the contractor record's own id, which the
      # fingerprint binds: the same payee re-pointed to another record expires it.
      fingerprint = Form1099InputsFingerprint.new(company: company, year: 2026).call
      allow(Form1099Pub1220Generator).to receive(:account_number).and_return("C999999")
      expect(Form1099InputsFingerprint.new(company: company, year: 2026).call).not_to eq(fingerprint)
    end
  end

  describe "official copies" do
    before do
      pay_contractor(cruz, 2_500)
      decide
    end

    it "sends a watermarked draft until the 1099s are marked ready, without caching" do
      download("recipient")

      expect(response).to have_http_status(:ok), response.body
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Content-Disposition"]).to include("1099-NEC_2026_Tumon_Bakery_Recipient_Copies_B_DRAFT.pdf")
      expect(pdf_text).to include("DRAFT — the 2026 1099s are not marked ready", "***-**-7890", "98-7654321")
      expect(pdf_text).not_to include("345-67-7890")
      expect(copy_logs.last.metadata).to include("document_kind" => "form_1099_nec_recipient_copies_b", "status" => "draft", "contains_full_tin" => false)
    end

    it "sends final copies only while the sign-off matches the inputs" do
      mark_ready
      download("payer")
      expect(response).to have_http_status(:ok), response.body
      expect(response.headers["Content-Disposition"]).to include("1099-NEC_2026_Tumon_Bakery_Payer_Record.pdf")
      expect(pdf_text).to include("345-67-7890", "Copy 1", "Payer's record")
      expect(pdf_text).not_to include("DRAFT")

      cruz.update!(address_line1: "8 Route 8")
      download("payer")
      expect(pdf_text).to include("DRAFT — the 2026 1099s are not marked ready")
      expect(copy_logs.map { |log| log.metadata["status"] }).to eq(%w[final draft])
      documents = step("print_and_file").dig("data", "documents")
      expect(documents.map { |document| document["key"] }).to eq(%w[form_1099_recipient_copies form_1099_payer_record form_1099_pub1220 form_1096_totals])
      expect(documents).to all(include("draft" => true, "available" => true))
    end

    it "audits every full-TIN download with the sign-off, and no TIN" do
      mark_ready
      readiness = Form1099FilingReadiness.find_by!(company: company, tax_year: 2026)

      expect { download("payer") }.to change(copy_logs, :count).by(1)

      log = copy_logs.last
      expect(log).to have_attributes(user_id: admin.id, company_id: company.id, event_category: "document_access", record_type: "reports")
      expect(log.metadata).to include("tax_year" => 2026, "document_kind" => "form_1099_nec_payer_record", "contains_full_tin" => true,
        "status" => "final", "inputs_fingerprint" => readiness.ready_fingerprint, "ready_fingerprint" => readiness.ready_fingerprint, "payee_count" => 1)
      expect(log.metadata).to include("file_digest" => FilingFileDigest.call(response.body), "digest_alg" => "hmac-sha256-v1")
      expect(log.metadata).not_to have_key("sha256")
      expect(log.metadata.values.map(&:to_s)).not_to include(Digest::SHA256.hexdigest(response.body))
      expect(log.to_json).not_to include("7890")
    end

    it "sends nothing when the download can't be recorded" do
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")

      download("payer")

      expect(response).to have_http_status(:service_unavailable)
      expect(response.media_type).to eq("application/json")
      expect(response.body).not_to include("345-67-7890")
    end

    it "sends nothing when the 1099 data or the sign-off changes while the file is made" do
      mark_ready
      allow_any_instance_of(Form1099NecOfficialCopies).to receive(:generate).and_wrap_original do |original, *args|
        pdf = original.call(*args)
        cruz.update!(address_line1: "200 New Street")
        pdf
      end
      download("payer")
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("This client's 1099 data changed while the file was being made. Download again.")
      expect(response.body).not_to include("345-67-7890")

      allow_any_instance_of(Form1099NecOfficialCopies).to receive(:generate).and_wrap_original do |original, *args|
        pdf = original.call(*args)
        Form1099FilingReadiness.find_by!(company: company, tax_year: 2026).update_columns(ready_fingerprint: nil, marked_ready_at: nil)
        pdf
      end
      mark_ready
      download("recipient")
      expect(response).to have_http_status(:conflict)
      expect(copy_logs).to be_empty
    end

    it "rechecks and writes the audit entry under the company lock that mark ready and payee resolution take" do
      mark_ready
      company_locks = []
      lock_blocks = 0
      held = []
      audits = []
      # Track which company lock block is open, so the audit is shown to run
      # inside the second one (not merely inside some transaction).
      allow_any_instance_of(Company).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        lock_blocks += 1
        held.push(lock_blocks)
        begin
          original.call(*args, &block)
        ensure
          held.pop
        end
      end
      allow(AuditLog).to receive(:record!).and_wrap_original do |original, **kwargs|
        audits << { held: held.dup, locks_taken: company_locks.length }
        original.call(**kwargs)
      end
      lock_sql = ->(*, payload) { company_locks << payload[:sql] if payload[:sql].match?(/FROM "companies".*FOR UPDATE/m) }

      ActiveSupport::Notifications.subscribed(lock_sql, "sql.active_record") { download("payer") }

      expect(response).to have_http_status(:ok), response.body
      expect(lock_blocks).to eq(2)
      expect(company_locks.length).to eq(2)
      expect(held).to be_empty
      expect(audits).to eq([ { held: [ 2 ], locks_taken: 2 } ])
    end

    it "needs client-management access for the full-TIN payer record" do
      accountant = create(:user, company: company, organization: company.organization, role: "accountant")
      create(:company_assignment, user: accountant, company: company, client_management: false, granted_by: admin)
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(accountant)

      download("payer")
      expect(response).to have_http_status(:forbidden)
      download("recipient")
      expect(response).to have_http_status(:ok), response.body
      allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user).and_return(accountant)
      payer = step("print_and_file").dig("data", "documents").find { |document| document["key"] == "form_1099_payer_record" }
      expect(payer).to include("available" => false, "unavailable_reason" => "Needs client-management access (contains full TINs).", "contains_full_tin" => true)
    end

    it "sends no payer record when client-management access is revoked while it is drawn" do
      accountant = create(:user, company: company, organization: company.organization, role: "accountant")
      assignment = create(:company_assignment, user: accountant, company: company, client_management: true, granted_by: admin)
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(accountant)
      revoke = false
      allow_any_instance_of(Form1099NecOfficialCopies).to receive(:generate).and_wrap_original do |original, *args|
        original.call(*args).tap { assignment.update_columns(client_management: false) if revoke }
      end

      download("payer")
      expect(response).to have_http_status(:ok), response.body
      assignment.update_columns(client_management: true)
      logs = copy_logs.count

      revoke = true
      download("payer")
      expect(response).to have_http_status(:forbidden)
      expect(response.media_type).to eq("application/json")
      expect(copy_logs.count).to eq(logs)

      # Recipient copies have the 1099 report's access and are unaffected.
      assignment.update_columns(client_management: true)
      download("recipient")
      expect(response).to have_http_status(:ok), response.body
    end

    it "refuses the payer record in a practice copy and keeps recipient copies drafts" do
      mark_ready
      source = create(:company, organization: company.organization)
      company.update_columns(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
        migration_source_company_id: source.id, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)

      download("payer")
      expect(response).to have_http_status(:forbidden)
      download("recipient")
      expect(response).to have_http_status(:ok), response.body
      expect(pdf_text).to include("DRAFT — a practice copy. Do not give to contractors or file.")
      expect(copy_logs.map { |log| log.metadata["status"] }).to eq(%w[draft])
    end

    it "refuses names and addresses that won't print whole" do
      cruz.update_columns(address_line1: "Lot 1234 Unit 5678 Barrigada Heights " * 8)

      download("recipient")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["problems"]).to eq([ "Ana Cruz: the street address is too long to fit the recipient's address box — shorten it on the contractor's record." ])
      expect(copy_logs).to be_empty
    end

    it "offers no copies when Cornerstone doesn't file the 1099s, or for another year" do
      download("recipient", year: 2025)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("2026 only")

      decide(form_1099: "client")
      download("recipient")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("Cornerstone does not file 2026 1099s")
      expect(step("form_1099_ready")).to be_nil
      expect(step("print_and_file")["status"]).to eq("not_needed")
      expect(copy_logs).to be_empty
    end
  end
end
