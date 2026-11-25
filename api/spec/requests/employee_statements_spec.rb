# frozen_string_literal: true

require "rails_helper"

# The employee app's pay stubs (M4-4c), with real Clerk token verification and
# the RLS guard in raise mode (spec/rails_helper.rb). Only R2 is a double.
RSpec.describe "Employee statements", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Alpha Grill") }
  let(:employee) { create(:employee, company: company, first_name: "Jordan", last_name: "Reyes", email: nil) }
  let(:worker) { create(:user, role: :portal_employee, company: company, clerk_id: "user_jordan") }
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active") }
  let(:stored) { {} }
  let(:storage) { instance_double(R2StorageService) }

  before do
    enable_stubs!(company)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) { |key, bytes, **| stored[key] = bytes.dup.b }
    allow(storage).to receive(:download) { |key| stored[key] }
    allow(storage).to receive(:delete) { |key| stored.delete(key) }
  end

  def enable_stubs!(target, stubs: true)
    target.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service", hours_source: "manual",
      employee_portal_enabled: true, options: { "employee_portal" => { "features" => { "stubs" => stubs } } }
    )
    TenantSubdomainRegistry.invalidate!
  end

  def headers_for(target_link = link, subject: "user_jordan")
    bearer(subject).merge("X-Employee-Link-Id" => target_link.id.to_s)
  end

  def period_on(pay_date, target = company, **attributes)
    create(:pay_period, :committed, company: target, start_date: pay_date - 13, end_date: pay_date - 6, pay_date: pay_date,
      committed_at: pay_date.to_time - 2.days, **attributes)
  end

  def item_for(period, person = employee, net: 900, **attributes)
    create(:payroll_item, pay_period: period, employee: person, gross_pay: net + 100, net_pay: net, hours_worked: 80,
      payment_delivery_method: "direct_deposit", **attributes)
  end

  def post_stub!(item, revision: 1, status: "posted", replaces: nil, payment_line: "Direct deposit")
    bytes = "%PDF-1.4 stub #{item.id} revision #{revision}"
    key = "employee_documents/test/#{item.id}-#{revision}.pdf"
    stored[key] = bytes.b
    EmployeeDocument.create!(company_id: item.company_id, payroll_item: item, revision: revision, status: status,
      storage_key: key, sha256: Digest::SHA256.hexdigest(bytes), posted_at: Time.current, payment_line: payment_line,
      corrected: replaces.present?, replaces_document: replaces)
  end

  def stub_on(pay_date, **attributes)
    post_stub!(item_for(period_on(pay_date), **attributes))
  end

  def list(params = nil, headers: headers_for)
    get "/api/v1/employee/statements", params: params, headers: headers
    response.parsed_body
  end

  def listed_ids(params = nil)
    body = list(params)
    expect(response).to have_http_status(:ok)
    body.fetch("statements").map { |row| row.fetch("id") }
  end

  def quickbooks_check!(person = employee, pay_date:, **attributes)
    create(:historical_paycheck, employee: person, company: person.company, pay_date: pay_date,
      period_start: pay_date - 13, period_end: pay_date - 6, **attributes)
  end

  describe "GET /api/v1/employee/statements" do
    it "lists only this employee's posted stubs in this company, newest first, without caching" do
      older = stub_on(Date.new(2026, 9, 24))
      newer = stub_on(Date.new(2026, 10, 8))
      coworker = create(:employee, company: company)
      post_stub!(item_for(period_on(Date.new(2026, 10, 22)), coworker))
      other_company = create(:company, organization: organization)
      enable_stubs!(other_company)
      outsider = create(:employee, company: other_company)
      post_stub!(item_for(period_on(Date.new(2026, 10, 22), other_company), outsider))

      body = list
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(body.fetch("statements").map { |row| row.fetch("id") }).to eq([ newer.id.to_s, older.id.to_s ])
      expect(body.fetch("years")).to eq([ 2026 ])
      expect(body.fetch("next_page")).to be_nil

      row = body.fetch("statements").first
      expect(row).to include("source" => "payroll", "pdf_available" => true, "corrected" => false, "net_pay" => "900.00",
        "total_hours" => "80.00", "source_label" => nil)
      expect(row.dig("pay_period", "pay_date")).to eq("2026-10-08")
      expect(row.fetch("payment")).to include("method" => "direct_deposit", "status" => "pending")
      expect(row).not_to have_key("has_source_entries")
    end

    it "keeps out drafts, uncommitted runs, voided and reversed payroll, and unposted items" do
      shown = stub_on(Date.new(2026, 9, 10))
      draft = post_stub!(item_for(period_on(Date.new(2026, 9, 24))))
      draft.payroll_item.pay_period.update_columns(status: "draft")
      voided_run = post_stub!(item_for(period_on(Date.new(2026, 10, 8))))
      voided_run.payroll_item.pay_period.update_columns(correction_status: "voided")
      reversed = post_stub!(item_for(period_on(Date.new(2026, 10, 22))))
      reversed.payroll_item.update_columns(payroll_reversed_at: Time.current, payroll_reversal_reason: "Reversed in a spec",
        payroll_reversed_by_id: create(:user, role: :admin, company: company).id)
      voided_check = post_stub!(item_for(period_on(Date.new(2026, 11, 5))))
      voided_check.payroll_item.update_columns(voided: true)
      withdrawn = post_stub!(item_for(period_on(Date.new(2026, 11, 12))), status: "withdrawn")
      item_for(period_on(Date.new(2026, 11, 19)))

      expect(listed_ids).to eq([ shown.id.to_s ])
      [ draft, voided_run, reversed, voided_check, withdrawn ].each do |document|
        get "/api/v1/employee/statements/#{document.id}", headers: headers_for
        expect([ response.status, response.body ]).to eq([ 404, "" ])
        get "/api/v1/employee/statements/#{document.id}/pdf", headers: headers_for
        expect([ response.status, response.body ]).to eq([ 404, "" ])
      end
    end

    it "pages in SQL with a year filter and lists the years" do
      dates = (0...23).map { |n| Date.new(2026, 1, 8) + (n * 14) }
      documents = dates.map { |date| stub_on(date) }
      last_year = stub_on(Date.new(2025, 12, 24))

      first = list
      expect(first.fetch("statements").size).to eq(20)
      expect(first.fetch("next_page")).to eq(2)
      expect(first.fetch("years")).to eq([ 2026, 2025 ])
      second = list({ page: 2 })
      expect(second.fetch("statements").map { |row| row["id"] }).to eq(
        documents.first(3).reverse.map { |doc| doc.id.to_s } + [ last_year.id.to_s ]
      )
      expect(second.fetch("next_page")).to be_nil
      expect(listed_ids({ year: 2025 })).to eq([ last_year.id.to_s ])
      expect(listed_ids({ year: 2024 })).to eq([])

      [ { year: "26" }, { year: "2026x" }, { page: "0" }, { page: "-1" }, { page: "abc" } ].each do |params|
        list(params)
        expect(response).to have_http_status(:bad_request), params.inspect
      end
    end

    it "compares each regular check with the regular check before it, across pages and years" do
      dates = (0...21).map { |n| Date.new(2025, 12, 18) + (n * 14) }
      documents = dates.each_with_index.map { |date, n| stub_on(date, net: 900 + n, hours_worked: 80 - n) }
      bonus = post_stub!(item_for(period_on(Date.new(2026, 9, 17), run_purpose: "bonus"), net: 500))

      rows = list.fetch("statements")
      expect(rows.first.fetch("id")).to eq(documents.last.id.to_s)
      expect(rows.first.fetch("previous")).to include("id" => documents[-2].id.to_s, "net_pay" => "919.00",
        "pay_date" => dates[-2].iso8601)
      expect(rows.find { |row| row["id"] == bonus.id.to_s }.fetch("previous")).to be_nil
      # The page's last regular check finds its previous one on the next page.
      expect(rows.size).to eq(20)
      expect(rows.last.fetch("id")).to eq(documents[2].id.to_s)
      expect(rows.last.fetch("previous")).to include("id" => documents[1].id.to_s)

      january = list({ year: 2026, page: 2 }).fetch("statements").sole
      expect(january.fetch("id")).to eq(documents[1].id.to_s)
      expect(january.fetch("previous")).to include("id" => documents.first.id.to_s, "pay_date" => "2025-12-18")
      expect(list({ year: 2025 }).fetch("statements").sole.fetch("previous")).to be_nil
    end

    it "is a bare 404 when the stubs switch or the app is off" do
      stub_on(Date.new(2026, 10, 8))
      company.client_operating_profiles.sole.update_columns(options: { "employee_portal" => { "features" => { "stubs" => false } } })
      list
      expect([ response.status, response.body ]).to eq([ 404, "" ])
      expect(AuditLog.where(action: "employee_statement#listed")).to be_empty

      company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false,
        options: { "employee_portal" => { "features" => { "stubs" => true } } })
      list
      expect([ response.status, response.body ]).to eq([ 404, "" ])
    end

    it "audits each list, view and download under employee_portal" do
      document = stub_on(Date.new(2026, 10, 8))
      list({ year: 2026 })
      get "/api/v1/employee/statements/#{document.id}", headers: headers_for
      get "/api/v1/employee/statements/#{document.id}/pdf", headers: headers_for

      logs = AuditLog.where(company_id: company.id, event_category: "employee_portal").order(:id)
      expect(logs.map { |log| [ log.action, log.record_type, log.record_id ] }).to eq([
        [ "employee_statement#listed", "EmployeeAccountLink", link.id ],
        [ "employee_statement#viewed", "EmployeeDocument", document.id ],
        [ "employee_statement#pdf_downloaded", "EmployeeDocument", document.id ]
      ])
      expect(logs.map(&:user_id).uniq).to eq([ worker.id ])
      expect(logs.map(&:actor_type).uniq).to eq([ "employee" ])
      expect(logs.first.metadata).to include("year" => 2026, "page" => 1, "count" => 1, "employee_id" => employee.id)
      expect(logs.last.metadata).to include("sha256" => document.sha256, "revision" => 1)
      expect(AuditLog.where(action: [ "employee_portal/statements#index", "employee_portal/statements#show",
        "employee_portal/statements#pdf" ])).to be_empty
    end
  end

  describe "isolation" do
    it "never opens another employee's, company's or link's statement" do
      mine = stub_on(Date.new(2026, 10, 8))
      coworker = create(:employee, company: company)
      theirs = post_stub!(item_for(period_on(Date.new(2026, 10, 8)), coworker))
      second_company = create(:company, organization: organization)
      enable_stubs!(second_company)
      second_employee = create(:employee, company: second_company, first_name: "Jordan", last_name: "Reyes")
      second_link = EmployeeAccountLink.create!(user: worker, company: second_company, employee: second_employee, status: "active")
      elsewhere = post_stub!(item_for(period_on(Date.new(2026, 10, 8), second_company), second_employee))
      other_user = create(:user, role: :portal_employee, company: company, clerk_id: "user_other")
      other_link = EmployeeAccountLink.create!(user: other_user, company: company, employee: coworker, status: "active")
      coworker_check = quickbooks_check!(coworker, pay_date: Date.new(2026, 1, 20))

      [ theirs, elsewhere ].each do |document|
        [ "", "/pdf" ].each do |suffix|
          get "/api/v1/employee/statements/#{document.id}#{suffix}", headers: headers_for
          expect([ response.status, response.body ]).to eq([ 404, "" ])
        end
      end
      get "/api/v1/employee/statements/qb-#{coworker_check.id}", headers: headers_for
      expect([ response.status, response.body ]).to eq([ 404, "" ])

      # The same login sees each company's stub only through that company's link.
      expect(list(headers: headers_for(second_link)).fetch("statements").map { |row| row["id"] }).to eq([ elsewhere.id.to_s ])
      get "/api/v1/employee/statements/#{mine.id}", headers: headers_for(second_link)
      expect(response).to have_http_status(:not_found)
      # Another person's link isn't usable with this login.
      get "/api/v1/employee/statements", headers: headers_for(other_link)
      expect([ response.status, response.body ]).to eq([ 404, "" ])
      get "/api/v1/employee/statements/#{theirs.id}", headers: headers_for(other_link, subject: "user_other")
      expect(response).to have_http_status(:ok)

      [ "0", "-1", "abc", "1e3", "qb-0", "qb-x" ].each do |id|
        get "/api/v1/employee/statements/#{id}", headers: headers_for
        expect([ response.status, response.body ]).to eq([ 404, "" ]), id
      end
      # No route matches a dotted id; it's the router's 404, which carries no data.
      get "/api/v1/employee/statements/#{mine.id}.pdf", headers: headers_for
      expect(response).to have_http_status(:not_found)
    end

    it "shows a former link only statements dated through its access end" do
      today = PayrollBusinessClock.today
      inside = stub_on(today - 20)
      last_day = stub_on(today + 5)
      # A run committed ahead of its pay date, after the access end.
      after = stub_on(today + 6)
      link.update!(status: "former", former_at: Time.current,
        former_access_until: (today + 5).in_time_zone(PayrollBusinessClock::TIME_ZONE).end_of_day)

      expect(listed_ids).to eq([ last_day.id.to_s, inside.id.to_s ])
      get "/api/v1/employee/statements/#{after.id}", headers: headers_for
      expect([ response.status, response.body ]).to eq([ 404, "" ])
      get "/api/v1/employee/statements/#{after.id}/pdf", headers: headers_for
      expect([ response.status, response.body ]).to eq([ 404, "" ])
      get "/api/v1/employee/statements/#{inside.id}/pdf", headers: headers_for
      expect(response).to have_http_status(:ok)
    end
  end

  describe "corrected revisions" do
    let(:period) { period_on(Date.new(2026, 8, 20)) }
    let(:item) { item_for(period, payment_delivery_method: "paper_check", check_number: "4012") }

    def post!(at)
      travel_to(at) { EmployeeDocuments::PostPayStub.new(item.reload).call }
    end

    it "lists a voided check only with its replacement, marked Corrected, with the original as replaced" do
      post!(Time.utc(2026, 8, 20))
      original = EmployeeDocument.where(payroll_item: item).sole
      expect(listed_ids).to eq([ original.id.to_s ])

      item.update_columns(voided: true, updated_at: Time.utc(2026, 8, 21))
      post!(Time.utc(2026, 8, 21, 1))
      expect(original.reload).to be_withdrawn
      expect(listed_ids).to eq([])
      get "/api/v1/employee/statements/#{original.id}/pdf", headers: headers_for
      expect(response).to have_http_status(:not_found)

      item.update_columns(voided: false, check_number: "4013", updated_at: Time.utc(2026, 8, 22))
      post!(Time.utc(2026, 8, 22, 1))
      replacement = EmployeeDocument.where(payroll_item: item).order(:revision).last
      expect(replacement).to have_attributes(corrected: true, replaces_document_id: original.id, status: "posted")

      rows = list.fetch("statements")
      expect(rows.map { |row| [ row["id"], row["corrected"] ] }).to eq([ [ replacement.id.to_s, true ] ])

      get "/api/v1/employee/statements/#{replacement.id}", headers: headers_for
      expect(response.parsed_body.fetch("earlier_versions")).to eq([
        { "id" => original.id.to_s, "status" => "replaced", "posted_at" => original.posted_at.iso8601, "payment_line" => "Check #4012" }
      ])
      # The original's id opens the current version, and its PDF is the original as issued.
      get "/api/v1/employee/statements/#{original.id}", headers: headers_for
      expect(response.parsed_body.fetch("id")).to eq(replacement.id.to_s)
      get "/api/v1/employee/statements/#{original.id}/pdf", headers: headers_for
      expect(response).to have_http_status(:ok)
      expect(Digest::SHA256.hexdigest(response.body)).to eq(original.sha256)
      expect(response.headers["Content-Disposition"]).to include("pay-stub-2026-08-20.pdf")
      get "/api/v1/employee/statements/#{replacement.id}/pdf", headers: headers_for
      expect(Digest::SHA256.hexdigest(response.body)).to eq(replacement.sha256)
      expect(response.headers["Content-Disposition"]).to include("pay-stub-2026-08-20-corrected.pdf")
    end

    it "hides a replaced original again when its replacement is withdrawn" do
      original = post_stub!(item, status: "replaced")
      replacement = post_stub!(item, revision: 2, replaces: original)
      replacement.update!(status: "withdrawn", withdrawal_reason: "void")

      expect(listed_ids).to eq([])
      get "/api/v1/employee/statements/#{original.id}/pdf", headers: headers_for
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/employee/statements/:id" do
    it "returns hours, units times rate, plain Guam tax labels, YTD and live payment status" do
      period = period_on(Date.new(2026, 10, 8))
      item = item_for(period, payment_delivery_method: "paper_check", check_number: "40125", withholding_tax: 50,
        social_security_tax: 62, medicare_tax: 14.5)
      document = post_stub!(item, payment_line: "Check #40125")

      get "/api/v1/employee/statements/#{document.id}", headers: headers_for
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("id" => document.id.to_s, "source" => "payroll", "earlier_versions" => [], "note" => nil)
      expect(body.fetch("payment")).to include("method" => "paper_check", "status" => "pending", "check_number_last4" => "0125")
      expect(body.fetch("earnings")).to all(include("label", "hours", "rate", "amount", "ytd"))
      expect(body.fetch("taxes").map { |row| row.values_at("kind", "display_label") }).to start_with(
        [ "guam_income_tax", "Guam income tax" ], [ "social_security", "Social Security" ], [ "medicare", "Medicare" ]
      )
      expect(body.fetch("taxes").first.fetch("label")).to eq("Federal/Guam Income Tax")
      expect(body.fetch("ytd")).to include("gross", "net")
      expect(body).not_to have_key("source_entries")

      travel_to(Time.current + 1.minute) do
        item.update_columns(check_printed_at: Time.current, updated_at: Time.current)
        item.mark_delivered!(user: create(:user, role: :admin, company: company), delivered_on: period.pay_date,
          delivery_method: CheckEvent::DELIVERY_EVIDENCE_TYPES.first, attestation: true)
      end
      get "/api/v1/employee/statements/#{document.id}", headers: headers_for
      expect(response.parsed_body.fetch("payment")).to include("status" => "issued")
      expect(document.reload.payment_line).to eq("Check #40125")
    end

    it "serves the frozen PDF with no-store, and refuses a file that changed in storage" do
      document = stub_on(Date.new(2026, 10, 8))
      get "/api/v1/employee/statements/#{document.id}/pdf", headers: headers_for
      expect(response).to have_http_status(:ok)
      expect(response.headers).to include("Cache-Control" => "no-store", "Content-Type" => "application/pdf",
        "X-Content-Type-Options" => "nosniff")
      expect(response.body).to eq(stored.fetch(document.storage_key))

      stored[document.storage_key] = "%PDF-1.4 tampered".b
      get "/api/v1/employee/statements/#{document.id}/pdf", headers: headers_for
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "earlier 2026 QuickBooks checks" do
    let!(:first_payroll) { stub_on(Date.new(2026, 9, 10)) }

    it "lists only locked, matched, regular checks before the first Payroll run, with original PDFs where posted" do
      shown = quickbooks_check!(pay_date: Date.new(2026, 8, 27), payment_method: "Direct Deposit", hours_total: 75.5)
      with_pdf = quickbooks_check!(pay_date: Date.new(2026, 8, 13), payment_method: "Check", check_number: "1088")
      quickbooks_check!(pay_date: Date.new(2026, 7, 30), reconciliation_status: "opening_summary")
      quickbooks_check!(pay_date: Date.new(2026, 7, 16), reconciliation_status: "unmatched")
      quickbooks_check!(pay_date: Date.new(2026, 7, 2), batch_status: "applied")
      quickbooks_check!(pay_date: Date.new(2026, 6, 18), period_type: "opening_summary")
      quickbooks_check!(pay_date: Date.new(2026, 9, 24))
      quickbooks_check!(create(:employee, company: company), pay_date: Date.new(2026, 8, 27))
      bytes = "%PDF-1.4 original quickbooks stub"
      stored["qb/original.pdf"] = bytes.b
      original = EmployeeDocument.create!(company_id: company.id, historical_paycheck: with_pdf, revision: 1,
        storage_key: "qb/original.pdf", sha256: Digest::SHA256.hexdigest(bytes), posted_at: Time.current)

      rows = list.fetch("statements")
      expect(rows.map { |row| row["id"] }).to eq([ first_payroll.id.to_s, "qb-#{shown.id}", "qb-#{with_pdf.id}" ])
      expect(rows.second).to include("source" => "quickbooks", "source_label" => "From QuickBooks records",
        "pdf_available" => false, "original_pdf" => false, "total_hours" => "75.50", "previous" => nil)
      expect(rows.second.fetch("payment")).to include("method" => "direct_deposit", "status" => nil)
      expect(rows.third).to include("pdf_available" => true, "original_pdf" => true)
      expect(rows.third.fetch("payment")).to include("method" => "paper_check", "check_number_last4" => "1088")

      get "/api/v1/employee/statements/qb-#{shown.id}/pdf", headers: headers_for
      expect([ response.status, response.body ]).to eq([ 404, "" ])
      get "/api/v1/employee/statements/qb-#{with_pdf.id}/pdf", headers: headers_for
      expect(response.body).to eq(bytes)
      expect(AuditLog.where(action: "employee_statement#pdf_downloaded").sole).to have_attributes(
        record_type: "EmployeeDocument", record_id: original.id
      )

      get "/api/v1/employee/statements/qb-#{with_pdf.id}", headers: headers_for
      expect(response.parsed_body).to include("source" => "quickbooks", "note" => nil, "earlier_versions" => [])
      expect(response.parsed_body.fetch("taxes").first).to include("kind" => "guam_income_tax", "display_label" => "Guam income tax")
      expect(AuditLog.where(action: "employee_statement#viewed").sole).to have_attributes(
        record_type: "HistoricalPaycheck", record_id: with_pdf.id
      )
    end

    it "shows adjusted totals with a note instead of the unadjusted breakdown" do
      check = quickbooks_check!(pay_date: Date.new(2026, 8, 27), gross_pay: 1_000, adjusted_gross: 1_000, net_pay: 900,
        earnings_breakdown: [ { "label" => "Hourly", "amount" => "1000.00" } ])
      HistoricalPaycheckAdjustment.insert_all!([ {
        company_id: company.id, historical_paycheck_id: check.id, kind: "correction", effective_pay_date: check.pay_date,
        filing_year: 2026, filing_quarter: 3, reason: "Recorded correction", idempotency_key: "spec-adjustment",
        created_by_id: create(:user, role: :admin, company: company).id, gross_pay: 50, net_pay: 40,
        created_at: Time.current, updated_at: Time.current
      } ])

      get "/api/v1/employee/statements/qb-#{check.id}", headers: headers_for
      body = response.parsed_body
      expect(body).to include("gross_pay" => "1050.00", "net_pay" => "940.00", "note" => "Includes recorded payroll adjustments.")
      expect(body.fetch("earnings")).to eq([ { "label" => "Gross pay", "hours" => "40.00", "rate" => nil, "pay_basis" => nil,
        "amount" => "1050.00", "ytd" => nil, "kind" => nil } ])
    end
  end
end
