# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Integrations::Aire::WorkerStatements", type: :request do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", shared_secret: "worker-secret") }
  let(:headers) { { "X-Shared-Secret" => "worker-secret" } }
  let(:uuid) { SecureRandom.uuid }
  let(:actor) { create(:user, company: company) }
  let(:worker) do
    create(:employee, company: company, first_name: "Pat", middle_name: "Q", last_name: "Pilot", employment_type: "hourly", pay_rate: 30,
      ssn_encrypted: "123-45-6789")
  end

  before { map!(worker, uuid) }

  def map!(employee, source_uuid, mapped_source: source)
    TimeTrackingEmployeeMapping.create!(company: mapped_source.company, time_tracking_source: mapped_source, employee: employee,
      source_user_id: "aire-#{employee.id}", source_user_uuid: source_uuid)
  end

  def path(suffix = "", worker_uuid: uuid) = "/api/v1/integrations/time_payroll/workers/#{worker_uuid}/statements#{suffix}"

  def paycheck(employee, pay_date, status: "committed", gross: 1200, net: 1000, **attributes)
    period = create(:pay_period, company: employee.company, status: status, start_date: pay_date - 14, end_date: pay_date - 4,
      pay_date: pay_date, committed_at: (Time.current if status == "committed"))
    create(:payroll_item, company: employee.company, employee: employee, pay_period: period, employment_type: employee.employment_type,
      pay_rate: 30, hours_worked: 40, gross_pay: gross, net_pay: net, payment_delivery_method: "paper_check", **attributes)
  end

  def earn!(item, label, hours, rate, amount, category: "regular")
    item.payroll_item_earnings.create!(category: category, label: label, hours: hours, rate: rate, amount: amount)
  end

  def get_json(url, auth = headers)
    get url, headers: auth
    response.parsed_body
  end

  describe "authentication" do
    it "rejects missing, wrong, inactive and non-AIRE credentials without detail" do
      paycheck(worker, Date.new(2026, 10, 9))
      other = create(:time_tracking_source, company: create(:company), source_type: "custom", shared_secret: "custom-secret")

      [ {}, { "X-Shared-Secret" => "worker-secre" }, { "X-Shared-Secret" => "worker-secretx" }, { "X-Shared-Secret" => other.shared_secret } ].each do |auth|
        get path, headers: auth
        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to eq("error" => "Invalid AIRE integration credentials")
      end
      source.update_columns(active: false)
      get path, headers: headers
      expect(response).to have_http_status(:unauthorized)
      expect(AuditLog.where(action: "worker_statements#listed")).not_to exist
    end

    it "accepts the events endpoint's alternate secret header" do
      get path, headers: { "X-Payroll-Shared-Secret" => "worker-secret" }

      expect(response).to have_http_status(:ok)
    end

    it "refuses a credential shared by more than one active AIRE source" do
      create(:time_tracking_source, company: create(:company), source_type: "aire_services", shared_secret: "worker-secret")

      get path, headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns a retryable response while connected payroll is paused" do
      allow(ConnectedPayrollMode).to receive(:enabled?).and_return(false)

      get path, headers: headers
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "worker resolution" do
    it "returns 404 with no detail for unknown, malformed, unmapped and other-company workers" do
      other_company = create(:company)
      other_source = create(:time_tracking_source, company: other_company, source_type: "aire_services", shared_secret: "other-secret")
      outsider = create(:employee, company: other_company)
      outsider_uuid = SecureRandom.uuid
      map!(outsider, outsider_uuid, mapped_source: other_source)
      item = paycheck(outsider, Date.new(2026, 10, 9))

      [ path(worker_uuid: SecureRandom.uuid), path(worker_uuid: "not-a-uuid"), path(worker_uuid: outsider_uuid),
        path("/#{item.id}", worker_uuid: outsider_uuid), path("/#{item.id}/pdf", worker_uuid: outsider_uuid) ].each do |url|
        get url, headers: headers
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq("error" => "Not found")
      end
    end

    it "does not return another worker's statement through this worker's path" do
      colleague = create(:employee, company: company)
      map!(colleague, SecureRandom.uuid)
      item = paycheck(colleague, Date.new(2026, 10, 9))

      get path("/#{item.id}"), headers: headers
      expect(response).to have_http_status(:not_found)
      get path("/#{item.id}/pdf"), headers: headers
      expect(response).to have_http_status(:not_found)
      expect(get_json(path).fetch("statements")).to eq([])
    end
  end

  describe "GET statements" do
    it "lists every committed paycheck newest first, with voided history and payment status from recorded evidence" do
      oldest = paycheck(worker, Date.new(2025, 3, 7), check_number: "100431", check_printed_at: 1.year.ago)
      issued = paycheck(worker, Date.new(2026, 9, 25), check_number: "103155", check_printed_at: 1.month.ago)
      CheckEvent.new(payroll_item: issued, user: actor, event_type: "delivered", check_number: "103155",
        effective_on: Date.new(2026, 9, 26)).save!(validate: false)
      deposit = paycheck(worker, Date.new(2026, 10, 9), payment_delivery_method: "direct_deposit")
      DirectDepositPaymentConfirmation.new(payroll_item: deposit, user: actor, settled_on: Date.new(2026, 10, 9), bank_reference: "ACH-123456789")
        .save!(validate: false)
      voided = paycheck(worker, Date.new(2026, 8, 28), check_number: "102001", voided: true, voided_at: 2.months.ago)
      reversed = paycheck(worker, Date.new(2026, 8, 14), check_number: "101999")
      reversed.update_columns(payroll_reversed_at: 2.months.ago, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Entered twice")
      pending = paycheck(worker, Date.new(2026, 10, 23), check_number: "103300", check_prepared_at: nil)
      paycheck(worker, Date.new(2026, 11, 6), status: "calculated")
      paycheck(worker, Date.new(2026, 7, 31), gross: 0, net: 0, hours_worked: 0) # roster row, no activity

      body = get_json(path)

      expect(response).to have_http_status(:ok)
      expect(body.fetch("worker")).to eq("employment_type" => "hourly", "contractor" => false, "display_name" => "Pat Pilot")
      statements = body.fetch("statements")
      expect(statements.map { |row| row["id"] }).to eq([ pending, deposit, issued, voided, reversed, oldest ].map(&:id))
      expect(statements.map { |row| row.dig("payment", "status") }).to eq(%w[pending issued issued voided voided prepared])
      expect(statements.find { |row| row["id"] == issued.id }).to eq(
        "id" => issued.id,
        "pay_period" => { "start_date" => "2026-09-11", "end_date" => "2026-09-21", "pay_date" => "2026-09-25", "run_purpose" => "regular" },
        "check_date" => "2026-09-25",
        "gross_pay" => "1200.00",
        "net_pay" => "1000.00",
        "total_hours" => "40.00",
        "payment" => { "method" => "paper_check", "status" => "issued", "issued_on" => "2026-09-26", "check_number_last4" => "3155" },
        "has_source_entries" => false
      )
      expect(statements.find { |row| row["id"] == deposit.id }.fetch("payment"))
        .to eq("method" => "direct_deposit", "status" => "issued", "issued_on" => "2026-10-09", "check_number_last4" => nil)
      expect(response.body).not_to include("ACH-123456789", "123-45-6789", "6789\"")
      log = AuditLog.find_by!(action: "worker_statements#listed")
      expect(log).to have_attributes(company_id: company.id, record_type: "Employee", record_id: worker.id, event_category: "integration", user_id: nil)
      expect(log.metadata).to include("employee_id" => worker.id, "time_tracking_source_id" => source.id, "source_user_uuid" => uuid, "statement_count" => 6)
    end
  end

  describe "GET statements/:id" do
    it "returns the pay stub's own earnings, taxes, deductions, YTD and source entries" do
      paycheck(worker, Date.new(2026, 9, 25), gross: 1260, net: 1100, withholding_tax: 100, social_security_tax: 40, medicare_tax: 20,
        ytd_gross: 1260, ytd_net: 1100, ytd_withholding_tax: 100, ytd_social_security_tax: 40, ytd_medicare_tax: 20).tap do |prior|
        earn!(prior, "Flight Hours", 40, 30, 1200)
        earn!(prior, "Flight Hours OT", 1.33, 45, 60, category: "overtime")
      end
      item = paycheck(worker, Date.new(2026, 10, 9), gross: 1245, net: 1090, hours_worked: 40, overtime_hours: 1,
        withholding_tax: 90, social_security_tax: 45, medicare_tax: 10, ytd_gross: 2505, ytd_net: 2190,
        ytd_withholding_tax: 190, ytd_social_security_tax: 85, ytd_medicare_tax: 30)
      earn!(item, "Flight Hours", 40, 30, 1200)
      earn!(item, "Flight Hours OT", 1, 45, 45, category: "overtime")
      import = create(:time_tracking_import, pay_period: item.pay_period, time_tracking_source: source)
      TimeTrackingEntryAllocation.new(company: company, pay_period: item.pay_period, payroll_item: item, employee: worker,
        time_tracking_source: source, time_tracking_import: import, source_user_id: "aire-#{worker.id}", source_user_uuid: uuid,
        source_time_entry_id: "2282", line_key: "admin", source_kind: "current", original_work_date: Date.new(2026, 9, 29),
        total_hours: "8.51", regular_hours: "7.37", overtime_hours: "1.14", category_snapshot: { "name" => "Admin Duties" }).save!(validate: false)

      body = get_json(path("/#{item.id}"))
      stub = PayStubGenerator.new(item.reload).statement
      pdf_text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")

      expect(response).to have_http_status(:ok)
      expect(body).to include("id" => item.id, "gross_pay" => "1245.00", "net_pay" => "1090.00", "has_source_entries" => true)
      expect(body.fetch("earnings")).to eq([
        { "label" => "Flight Hours", "hours" => "40.00", "rate" => "30.00", "amount" => "1200.00", "kind" => "regular" },
        { "label" => "Flight Hours OT", "hours" => "1.00", "rate" => "45.00", "amount" => "45.00", "kind" => "overtime" }
      ])
      expect(body.fetch("taxes")).to eq([
        { "label" => "Federal/Guam Income Tax", "amount" => "90.00", "ytd" => "190.00" },
        { "label" => "Social Security (6.2%)", "amount" => "45.00", "ytd" => "85.00" },
        { "label" => "Medicare (1.45%)", "amount" => "10.00", "ytd" => "30.00" }
      ])
      expect(body.fetch("deductions")).to eq(stub.fetch(:deductions).map { |row| { "label" => row[:label], "amount" => format("%.2f", row[:amount]), "ytd" => format("%.2f", row[:ytd]) } })
      expect(body.fetch("ytd")).to eq("gross" => "2505.00", "net" => "2190.00")
      expect(body.fetch("source_entries")).to eq([
        { "source_time_entry_id" => "2282", "work_date" => "2026-09-29", "hours" => "8.51", "regular_hours" => "7.37",
          "overtime_hours" => "1.14", "source_kind" => "current", "category" => "Admin Duties" }
      ])
      # Paper and app agree: each label and amount is on the printed statement.
      (body.fetch("earnings") + body.fetch("taxes")).each do |row|
        expect(pdf_text).to include(row["label"])
        expect(pdf_text).to include("$#{row['amount'].to_d.to_fs(:delimited, precision: 2)}")
      end
      expect(pdf_text).to include("$2,505.00", "$190.00")
      expect(response.body).not_to include("123-45-6789", "employer")
      expect(AuditLog.find_by!(action: "worker_statement#viewed")).to have_attributes(record_type: "PayrollItem", record_id: item.id)
    end

    it "shows a contractor's combined contract rows, no taxes, and historical OT rows exactly as paid" do
      contractor = create(:employee, :contractor, company: company, contractor_pay_type: "hourly", pay_rate: 30, first_name: "Casey", last_name: "Contract")
      contractor_uuid = SecureRandom.uuid
      map!(contractor, contractor_uuid)
      old = paycheck(contractor, Date.new(2026, 9, 25), gross: 1290, net: 1290)
      earn!(old, "Contract Labor", 40, 30, 1200)
      earn!(old, "Contract OT", 2, 45, 90, category: "overtime")
      current = paycheck(contractor, Date.new(2026, 10, 9), gross: 1854, net: 1854, hours_worked: 60.6, overtime_hours: 1.2, ytd_net: 3144)
      earn!(current, "Flight Hours · AIRE current period · $30.00/hr", 61.8, 30, 1854)

      list = get_json(path(worker_uuid: contractor_uuid))
      body = get_json(path("/#{current.id}", worker_uuid: contractor_uuid))
      history = get_json(path("/#{old.id}", worker_uuid: contractor_uuid))

      expect(list.fetch("worker")).to eq("employment_type" => "contractor", "contractor" => true, "display_name" => "Casey Contract")
      expect(body.fetch("earnings")).to eq([
        { "label" => "Flight Hours · AIRE current period · $30.00/hr", "hours" => "61.80", "rate" => "30.00", "amount" => "1854.00", "kind" => "regular" }
      ])
      expect(body.fetch("taxes")).to eq([])
      expect(body.fetch("total_hours")).to eq("61.80")
      expect(history.fetch("earnings").map { |row| row.values_at("label", "amount", "kind") }).to eq([
        [ "Contract Labor", "1200.00", "regular" ], [ "Contract OT", "90.00", "overtime" ]
      ])
    end

    it "does not return statements from uncommitted payroll" do
      item = paycheck(worker, Date.new(2026, 11, 6), status: "approved")

      get path("/#{item.id}"), headers: headers
      expect(response).to have_http_status(:not_found)
      get path("/#{item.id}/pdf"), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET statements/:id/pdf" do
    it "returns the staff pay stub PDF for that paycheck, with the SSN masked, and records the download" do
      item = paycheck(worker, Date.new(2026, 10, 9), check_number: "103155")
      earn!(item, "Flight Hours", 40, 30, 1200)

      get path("/#{item.id}/pdf"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("EARNINGS STATEMENT", "Pat Q Pilot", "XXX-XX-6789", "Flight Hours")
      expect(text).not_to include("123-45-6789")
      expect(AuditLog.find_by!(action: "worker_statement#pdf_downloaded")).to have_attributes(record_id: item.id, company_id: company.id)
    end

    it "lists reversed payroll as voided history but has no current statement PDF for it" do
      item = paycheck(worker, Date.new(2026, 10, 9), check_number: "103155")
      item.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Entered twice")

      expect(get_json(path).fetch("statements").sole.dig("payment", "status")).to eq("voided")
      get path("/#{item.id}/pdf"), headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
