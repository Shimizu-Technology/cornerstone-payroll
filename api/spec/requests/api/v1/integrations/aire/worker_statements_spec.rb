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

  # The cells PayStubGenerator draws in its EARNINGS table, without the header
  # and GROSS PAY rows.
  def printed_earnings(item)
    pdf = Prawn::Document.new
    rows = nil
    allow(pdf).to receive(:table) { |data, **| rows = data }
    PayStubGenerator.new(PayrollItem.find(item.id)).send(:render_earnings, pdf)
    rows[1...-1]
  end

  def cash(value) = "$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', value.to_d))}"

  # AIRE renders a salary rate per year, as the stub prints it.
  def as_printed(earnings)
    printed = ->(value) { value.nil? ? "—" : cash(value) }
    earnings.map do |row|
      rate = row["pay_basis"] == "salary" ? "#{cash(row['rate'])}/yr" : printed.call(row["rate"])
      [ row["label"], row["hours"] || "—", rate, printed.call(row["amount"]), printed.call(row["ytd"]) ]
    end
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
      roster = paycheck(worker, Date.new(2026, 7, 31), gross: 0, net: 0, hours_worked: 0) # roster row, no activity

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
      # A single statement is found under the same rules as the list.
      get path("/#{roster.id}"), headers: headers
      expect(response).to have_http_status(:not_found)
      get path("/#{reversed.id}"), headers: headers
      expect(response).to have_http_status(:ok)
      log = AuditLog.find_by!(action: "worker_statements#listed")
      expect(log).to have_attributes(company_id: company.id, record_type: "Employee", record_id: worker.id, event_category: "integration", user_id: nil)
      expect(log.metadata).to include("employee_id" => worker.id, "time_tracking_source_id" => source.id, "source_user_uuid" => uuid, "statement_count" => 6)
    end
  end

  describe "GET statements/:id" do
    it "returns the pay stub's own earnings with each row's YTD, taxes, deductions and source entries" do
      current_label = "Flight Hours · AIRE current period · $30.00/hr"
      carryover_label = "Flight Hours · AIRE carryover from Sep 15, 2026 · $30.00/hr"
      paycheck(worker, Date.new(2026, 9, 25), gross: 1260, net: 1100, withholding_tax: 100, social_security_tax: 40, medicare_tax: 20,
        ytd_gross: 1260, ytd_net: 1100, ytd_withholding_tax: 100, ytd_social_security_tax: 40, ytd_medicare_tax: 20).tap do |prior|
        earn!(prior, current_label, 40, 30, 1200)
        earn!(prior, "#{current_label} OT", 1.33, 45, 60, category: "overtime")
      end
      item = paycheck(worker, Date.new(2026, 10, 9), gross: 1372.5, net: 1200, hours_worked: 44.25, overtime_hours: 1,
        withholding_tax: 90, social_security_tax: 45, medicare_tax: 10, ytd_gross: 2632.5, ytd_net: 2300,
        ytd_withholding_tax: 190, ytd_social_security_tax: 85, ytd_medicare_tax: 30)
      earn!(item, current_label, 40, 30, 1200)
      earn!(item, "#{current_label} OT", 1, 45, 45, category: "overtime")
      earn!(item, carryover_label, 4.25, 30, 127.5)
      import = create(:time_tracking_import, pay_period: item.pay_period, time_tracking_source: source)
      TimeTrackingEntryAllocation.new(company: company, pay_period: item.pay_period, payroll_item: item, employee: worker,
        time_tracking_source: source, time_tracking_import: import, source_user_id: "aire-#{worker.id}", source_user_uuid: uuid,
        source_time_entry_id: "2282", line_key: "admin", source_kind: "current", original_work_date: Date.new(2026, 9, 29),
        total_hours: "8.51", regular_hours: "7.37", overtime_hours: "1.14", category_snapshot: { "name" => "Admin Duties" }).save!(validate: false)

      body = get_json(path("/#{item.id}"))
      stub = PayStubGenerator.new(item.reload).statement
      pdf_text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")

      expect(response).to have_http_status(:ok)
      expect(body).to include("id" => item.id, "gross_pay" => "1372.50", "net_pay" => "1200.00", "has_source_entries" => true)
      expect(body.fetch("earnings")).to eq([
        { "label" => current_label, "hours" => "40.00", "rate" => "30.00", "pay_basis" => nil, "amount" => "1200.00", "ytd" => "2400.00", "kind" => "regular" },
        { "label" => "#{current_label} OT", "hours" => "1.00", "rate" => "45.00", "pay_basis" => nil, "amount" => "45.00", "ytd" => "105.00", "kind" => "overtime" },
        { "label" => carryover_label, "hours" => "4.25", "rate" => "30.00", "pay_basis" => nil, "amount" => "127.50", "ytd" => "127.50", "kind" => "regular" }
      ])
      expect(as_printed(body.fetch("earnings"))).to eq(printed_earnings(item))
      expect(body.fetch("taxes")).to eq([
        { "label" => "Federal/Guam Income Tax", "amount" => "90.00", "ytd" => "190.00" },
        { "label" => "Social Security (6.2%)", "amount" => "45.00", "ytd" => "85.00" },
        { "label" => "Medicare (1.45%)", "amount" => "10.00", "ytd" => "30.00" }
      ])
      expect(body.fetch("deductions")).to eq(stub.fetch(:deductions).map { |row| { "label" => row[:label], "amount" => format("%.2f", row[:amount]), "ytd" => format("%.2f", row[:ytd]) } })
      expect(body.fetch("ytd")).to eq("gross" => "2632.50", "net" => "2300.00")
      expect(body.fetch("source_entries")).to eq([
        { "source_time_entry_id" => "2282", "work_date" => "2026-09-29", "hours" => "8.51", "regular_hours" => "7.37",
          "overtime_hours" => "1.14", "source_kind" => "current", "category" => "Admin Duties" }
      ])
      # Paper and app agree: each label, amount and YTD is on the printed statement.
      (body.fetch("earnings") + body.fetch("taxes")).each do |row|
        expect(pdf_text.gsub(/\s+/, " ")).to include(row["label"])
        expect(pdf_text).to include(cash(row["amount"]), cash(row["ytd"]))
      end
      expect(pdf_text).to include("$2,632.50", "$190.00")
      expect(response.body).not_to include("123-45-6789", "employer")
      expect(AuditLog.find_by!(action: "worker_statement#viewed")).to have_attributes(record_type: "PayrollItem", record_id: item.id)
    end

    it "lists earnings paid earlier this year but not on this check as zero-amount YTD rows, as the stub prints them" do
      paycheck(worker, Date.new(2026, 9, 25), gross: 1300, bonus: 100).tap do |prior|
        earn!(prior, "Regular Pay", 40, 30, 1200)
        earn!(prior, "Bonus", nil, nil, 100, category: "bonus")
      end
      item = paycheck(worker, Date.new(2026, 10, 9), gross: 1200)
      earn!(item, "Flight Hours", 40, 30, 1200)

      body = get_json(path("/#{item.id}"))

      expect(body.fetch("earnings")).to contain_exactly(
        { "label" => "Flight Hours", "hours" => "40.00", "rate" => "30.00", "pay_basis" => nil, "amount" => "1200.00", "ytd" => "1200.00", "kind" => "regular" },
        { "label" => "Regular Pay", "hours" => nil, "rate" => nil, "pay_basis" => nil, "amount" => "0.00", "ytd" => "1200.00", "kind" => "regular" },
        { "label" => "Bonus", "hours" => nil, "rate" => nil, "pay_basis" => nil, "amount" => "0.00", "ytd" => "100.00", "kind" => "bonus" }
      )
      expect(body.fetch("earnings").first["label"]).to eq("Flight Hours")
      expect(as_printed(body.fetch("earnings"))).to eq(printed_earnings(item))
      expect(body.fetch("earnings").sum { |row| row["amount"].to_d }).to eq(body["gross_pay"].to_d)
      expect(body.fetch("earnings").sum { |row| row["ytd"].to_d }).to eq(body.dig("ytd", "gross").to_d)
    end

    it "leaves each row's YTD empty where the stub prints a dash" do
      paycheck(worker, Date.new(2026, 9, 25), gross: 1200)
      # Stored rows that omit the saved bonus cannot be attributed row by row.
      item = paycheck(worker, Date.new(2026, 10, 9), gross: 1350, bonus: 50)
      earn!(item, "Flight Hours", 40, 30, 1200)
      earn!(item, "Ground School", 4, 25, 100)

      body = get_json(path("/#{item.id}"))

      expect(body.fetch("earnings").map { |row| row.values_at("label", "amount", "ytd") }).to eq([
        [ "Flight Hours", "1200.00", nil ], [ "Ground School", "100.00", nil ], [ "Bonus", "50.00", nil ]
      ])
      expect(as_printed(body.fetch("earnings"))).to eq(printed_earnings(item))
      expect(body.dig("ytd", "gross")).to eq("2550.00")
    end

    it "shows a contractor's combined contract rows with YTD, no taxes, and historical OT rows exactly as paid" do
      contractor = create(:employee, :contractor, company: company, contractor_pay_type: "hourly", pay_rate: 30, first_name: "Casey", last_name: "Contract")
      contractor_uuid = SecureRandom.uuid
      map!(contractor, contractor_uuid)
      combined = "Flight Hours · AIRE current period · $30.00/hr"
      old = paycheck(contractor, Date.new(2026, 9, 11), gross: 1290, net: 1290)
      earn!(old, "Contract Labor", 40, 30, 1200)
      earn!(old, "Contract OT", 2, 45, 90, category: "overtime")
      earlier = paycheck(contractor, Date.new(2026, 9, 25), gross: 1200, net: 1200)
      earn!(earlier, combined, 40, 30, 1200)
      current = paycheck(contractor, Date.new(2026, 10, 9), gross: 1854, net: 1854, hours_worked: 60.6, overtime_hours: 1.2, ytd_net: 4344)
      earn!(current, combined, 61.8, 30, 1854)

      list = get_json(path(worker_uuid: contractor_uuid))
      body = get_json(path("/#{current.id}", worker_uuid: contractor_uuid))
      history = get_json(path("/#{old.id}", worker_uuid: contractor_uuid))

      expect(list.fetch("worker")).to eq("employment_type" => "contractor", "contractor" => true, "display_name" => "Casey Contract")
      expect(body.fetch("earnings").first).to eq(
        "label" => combined, "hours" => "61.80", "rate" => "30.00", "pay_basis" => nil, "amount" => "1854.00", "ytd" => "3054.00", "kind" => "regular"
      )
      # Earlier Contract Labor/OT rows carry as zero-amount YTD rows exactly as the
      # stub prints them. PR #437 folds a contractor's earlier OT rows into the
      # contract row on both, so this stays equal when it merges.
      expect(as_printed(body.fetch("earnings"))).to eq(printed_earnings(current))
      expect(body.fetch("earnings").drop(1).map { |row| row["amount"] }).to all(eq("0.00"))
      expect(body.fetch("earnings").sum { |row| row["ytd"].to_d }).to eq(body.dig("ytd", "gross").to_d)
      expect(body.dig("ytd", "gross")).to eq("4344.00")
      expect(body.fetch("taxes")).to eq([])
      expect(body.fetch("total_hours")).to eq("61.80")
      expect(history.fetch("earnings").map { |row| row.values_at("label", "amount", "ytd", "kind") }).to eq([
        [ "Contract Labor", "1200.00", "1200.00", "regular" ], [ "Contract OT", "90.00", "90.00", "overtime" ]
      ])
      expect(as_printed(history.fetch("earnings"))).to eq(printed_earnings(old))
    end

    it "returns a salaried worker's annual rate with its pay basis, as the stub prints it" do
      salaried = create(:employee, company: company, employment_type: "salary", salary_type: "annual", pay_rate: 52_000,
        first_name: "Sam", last_name: "Salary")
      salaried_uuid = SecureRandom.uuid
      map!(salaried, salaried_uuid)
      first = paycheck(salaried, Date.new(2026, 9, 11), gross: 2000, pay_rate: 52_000, hours_worked: 0)
      # Stored rows that omit the saved bonus leave later checks unitemized.
      paycheck(salaried, Date.new(2026, 9, 25), gross: 2050, bonus: 50, pay_rate: 52_000, hours_worked: 0).tap do |omitted|
        earn!(omitted, "Salary", nil, nil, 2000, category: "salary")
      end
      current = paycheck(salaried, Date.new(2026, 10, 9), gross: 2000, pay_rate: 52_000, hours_worked: 0)

      itemized = get_json(path("/#{first.id}", worker_uuid: salaried_uuid))
      unitemized = get_json(path("/#{current.id}", worker_uuid: salaried_uuid))

      expect(itemized.fetch("earnings")).to eq([
        { "label" => "Salary", "hours" => nil, "rate" => "52000.00", "pay_basis" => "salary", "amount" => "2000.00", "ytd" => "2000.00", "kind" => "regular" }
      ])
      expect(as_printed(itemized.fetch("earnings"))).to eq(printed_earnings(first))
      expect(unitemized.fetch("earnings")).to eq([
        { "label" => "Salary", "hours" => nil, "rate" => "52000.00", "pay_basis" => "salary", "amount" => "2000.00", "ytd" => nil, "kind" => "regular" }
      ])
      expect(as_printed(unitemized.fetch("earnings"))).to eq(printed_earnings(current))
      expect(printed_earnings(current).sole[2]).to eq("$52,000.00/yr")
    end

    it "returns a fixed-fee contractor's fee rate with its pay basis, as the stub prints it" do
      contractor = create(:employee, :contractor, company: company, pay_rate: 1500, first_name: "Fran", last_name: "Fee")
      contractor_uuid = SecureRandom.uuid
      map!(contractor, contractor_uuid)
      first = paycheck(contractor, Date.new(2026, 9, 25), gross: 1500, net: 1500, pay_rate: 1500, hours_worked: 0,
        calculation_context_snapshot: { "employee" => { "contractor_pay_type" => "flat_fee" } })
      # Without a saved pay basis the stub cannot attribute YTD row by row.
      current = paycheck(contractor, Date.new(2026, 10, 9), gross: 1500, net: 1500, pay_rate: 1500, hours_worked: 0)

      itemized = get_json(path("/#{first.id}", worker_uuid: contractor_uuid))
      unitemized = get_json(path("/#{current.id}", worker_uuid: contractor_uuid))

      expect(itemized.fetch("earnings")).to eq([
        { "label" => "Contract Fee", "hours" => nil, "rate" => "1500.00", "pay_basis" => "contractor", "amount" => "1500.00", "ytd" => "1500.00", "kind" => "regular" }
      ])
      expect(as_printed(itemized.fetch("earnings"))).to eq(printed_earnings(first))
      expect(unitemized.fetch("earnings")).to eq([
        { "label" => "Contract Fee", "hours" => nil, "rate" => "1500.00", "pay_basis" => "contractor", "amount" => "1500.00", "ytd" => nil, "kind" => "regular" }
      ])
      expect(as_printed(unitemized.fetch("earnings"))).to eq(printed_earnings(current))
      expect(printed_earnings(current).sole[2]).to eq("$1,500.00")
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
