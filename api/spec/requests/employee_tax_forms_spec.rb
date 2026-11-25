# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

# W-2GU copies in the employee app (M4-5): staff post the year's final Copy B
# and C, each frozen per employee, and employees read their own through the
# link. Staff and employee requests use real Clerk token verification under
# the RLS guard in raise mode (spec/rails_helper.rb). Only R2 is a double.
RSpec.describe "Employee tax forms", type: :request do
  include EmployeeLinkHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers
  include PdfBoxText

  let(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization, name: "Tumon Bakery", ein: "98-7654321") }
  let!(:department) { create(:department, company: company) }
  let!(:employee) do
    create(:employee, company: company, department: department, first_name: "Jordan", last_name: "Santos",
      ssn_encrypted: "123-45-6789", email: "jordan.own@example.net", email_verified_at: 1.day.ago)
  end
  let!(:coworker) do
    create(:employee, company: company, department: department, first_name: "Alex", last_name: "Reyes",
      ssn_encrypted: "234-56-4321", email: nil)
  end
  let!(:staff) { create(:user, role: :admin, company: company, organization: organization, clerk_id: "user_staff") }
  let(:worker) { create(:user, role: :portal_employee, company: company, clerk_id: "user_jordan", email: "jordan.own@example.net") }
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active", activated_at: 1.day.ago) }
  let!(:threshold) { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }
  let(:stored) { {} }
  let(:storage) { instance_double(R2StorageService) }
  let(:staff_headers) { bearer("user_staff").merge("X-Company-Id" => company.id.to_s) }

  before do
    enable_tax_forms!(company)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) { |key, bytes, **| stored[key] = bytes.dup.b }
    allow(storage).to receive(:download) { |key| stored[key] }
    allow(storage).to receive(:delete) { |key| stored.delete(key) }
    [ employee, coworker ].each { |person| pay(person, Date.new(2026, 3, 6)) }
  end

  it "marks an overdue paper copy mailed once and records the staff actor" do
    today = PayrollBusinessClock.today
    copy = nil
    TenantScope.as_system(reason: "Spec creates a posted copy with paper follow-up") do
      copy = EmployeeDocument.create!(company: company, employee: employee, tax_year: 2026, revision: 1,
        storage_key: "employee_documents/test/copy.pdf", sha256: "a" * 64, posted_at: 32.days.ago)
      copy.notices.create!(company: company, employee: employee, kind: "w2gu_available", status: "sent",
        delivery_status: "bounced", paper_bounced_on: today - 31, paper_due_on: today - 1)
    end

    get "/api/v1/admin/employee_tax_forms", headers: staff_headers, params: { year: 2026 }
    expect(response.parsed_body.dig("documents", 0, "paper_follow_up", "status")).to eq("overdue")

    2.times do
      post "/api/v1/admin/employee_tax_forms/#{copy.id}/mark_paper_mailed", headers: staff_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("document", "paper_follow_up")).to include(
        "status" => "mailed", "mailed_on" => today.iso8601, "mailed_by" => staff.name)
    end
    audit = AuditLog.where(action: "employee_tax_forms#paper_mailed").sole
    expect(audit).to have_attributes(record_id: copy.id, user_id: staff.id)
  end

  def enable_tax_forms!(target, tax_forms: true, profile_requests: false)
    target.client_operating_profiles.where(effective_on: PayrollBusinessClock.today).delete_all
    target.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: target.client_operating_profiles.count + 1,
      offering: "payroll_service", hours_source: "manual", employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "tax_forms" => tax_forms, "profile_requests" => profile_requests } } }
    )
    activate_employee_app!(target)
  end

  def pay(person, pay_date, target = company)
    period = PayPeriod.find_by(company: target, pay_date: pay_date) ||
      create(:pay_period, :committed, company: target, start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    create(:payroll_item, company: target, employee: person, pay_period: period,
      gross_pay: 2_000, net_pay: 1_600, withholding_tax: 150,
      social_security_tax: 124, employer_social_security_tax: 124, medicare_tax: 29, employer_medicare_tax: 29,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000,
      fit_taxable_wages: 2_000)
  end

  def cornerstone_files!(headers: staff_headers)
    { "w2_gu" => "cornerstone", "form_1099" => "no_filing" }.each do |filing_type, party|
      put "/api/v1/admin/payroll_filing_responsibilities", headers: headers, as: :json, params: {
        responsibility: { tax_year: 2026, filing_types: [ filing_type ], responsible_party: party, imported_payroll_inclusion: "included" }
      }
      expect(response).to have_http_status(:ok), response.body
    end
  end

  def mark_ready!(headers: staff_headers)
    post "/api/v1/admin/reports/w2_gu_preflight", headers: headers, as: :json, params: { year: 2026 }
    post "/api/v1/admin/reports/w2_gu_mark_ready", headers: headers, as: :json, params: { year: 2026, notes: "Year-end review" }
    expect(response).to have_http_status(:ok), response.body
  end

  def final!
    cornerstone_files!
    mark_ready!
  end

  def post_copies!(headers: staff_headers)
    perform_enqueued_jobs(only: PostEmployeeW2GuCopiesJob) do
      post "/api/v1/admin/employee_tax_forms/post_copies", headers: headers, as: :json, params: { year: 2026 }
    end
  end

  def employee_headers(target_link = link, subject: "user_jordan")
    bearer(subject).merge("X-Employee-Link-Id" => target_link.id.to_s)
  end

  def forms(headers: employee_headers)
    get "/api/v1/employee/tax_forms", headers: headers
    response.parsed_body
  end

  def copy_of(person)
    EmployeeDocument.tax_forms.find_by!(company_id: person.company_id, employee_id: person.id)
  end

  def pdf_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.flat_map { |page| pdf_rows(page) }.join("\n")
  end

  def expect_empty_not_found
    expect([ response.status, response.body ]).to eq([ 404, "" ])
  end

  # A posted copy made directly, for isolation checks across companies.
  def frozen_copy!(person, status: "posted")
    bytes = "%PDF-1.4 w2gu #{person.id}"
    key = "employee_documents/test/w2gu-#{person.id}.pdf"
    stored[key] = bytes.b
    EmployeeDocument.create!(company_id: person.company_id, employee: person, tax_year: 2026, revision: 1, status: status,
      storage_key: key, sha256: Digest::SHA256.hexdigest(bytes), posted_at: Time.current)
  end

  describe "posting" do
    it "posts nothing while the W-2s aren't final, and says why" do
      post_copies!
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("blocker" => "not_filed")

      cornerstone_files!
      post_copies!
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("blocker" => "not_final")

      # A ready mark that no longer matches the inputs isn't final either.
      mark_ready!
      pay(employee, Date.new(2026, 4, 3))
      post_copies!
      expect(response.parsed_body).to include("blocker" => "not_final")

      # The job checks again on its own.
      result = PostEmployeeW2GuCopiesJob.perform_now(company.id, 2026, staff.id)
      expect(result.status).to eq(:not_final)
      expect(EmployeeDocument.count).to eq(0)
      expect(stored).to be_empty
    end

    it "freezes one final Copy B and C per employee with a fingerprint, and a rerun posts nothing new" do
      final!
      post_copies!
      expect(response).to have_http_status(:accepted)

      documents = EmployeeDocument.tax_forms.order(:employee_id)
      expect(documents.map(&:employee_id)).to contain_exactly(employee.id, coworker.id)
      documents.each do |document|
        expect(document).to have_attributes(company_id: company.id, tax_year: 2026, revision: 1, status: "posted", corrected: false)
        expect(document.storage_key).to include("employee_#{document.employee_id}/w2gu_2026/1-#{document.sha256}")
        expect(Digest::SHA256.hexdigest(stored.fetch(document.storage_key))).to eq(document.sha256)
      end

      text = pdf_text(stored.fetch(copy_of(employee).storage_key))
      expect(text).to include("XXX-XX-6789", "Santos", "Tumon Bakery")
      expect(text).not_to include("Reyes", "123-45-6789", "XXX-XX-4321", "DRAFT", "employee 1 of")
      expect(text).not_to match(/practice|test only/i)

      audit = AuditLog.where(action: "employee_tax_forms#posted").sole
      expect(audit).to have_attributes(user_id: staff.id, company_id: company.id, event_category: "employee_portal")
      expect(audit.metadata).to include("tax_year" => 2026, "posted_count" => 2)
      expect(audit.to_json).not_to include("6789")

      get "/api/v1/admin/employee_tax_forms", headers: staff_headers, params: { year: 2026 }
      expect(response.parsed_body).to include("can_post" => true, "available_through" => "2027-10-15")
      expect(response.parsed_body.fetch("documents").map { |row| row["inputs_changed_since_posting"] }).to eq([ false, false ])

      expect { post_copies! }.not_to change(EmployeeDocument, :count)
      expect(response).to have_http_status(:accepted)
      expect(EmployeeDocuments::PostW2GuCopies.new(company: company, year: 2026).call)
        .to have_attributes(status: :posted, documents: [])
      expect(AuditLog.where(action: "employee_tax_forms#posted").count).to eq(1)

      # Figures that change after posting are flagged for staff; the frozen copies stay as posted.
      pay(employee, Date.new(2026, 4, 3))
      get "/api/v1/admin/employee_tax_forms", headers: staff_headers, params: { year: 2026 }
      expect(response.parsed_body).to include("can_post" => false, "blocker" => "not_final")
      expect(response.parsed_body.fetch("documents").map { |row| row["inputs_changed_since_posting"] }).to eq([ true, true ])
    end

    it "posts nothing when the inputs change while the copies are drawn" do
      final!
      poster = EmployeeDocuments::PostW2GuCopies.new(company: company, year: 2026)
      allow(W2GuOfficialCopies).to receive(:new).and_wrap_original do |original, **options|
        original.call(**options).tap { company.update_columns(name: "Tumon Bakery Renamed") if options[:employee_id] }
      end

      expect(poster.call.status).to eq(:changed)
      expect(EmployeeDocument.count).to eq(0)
    end

    it "uploads before taking the locks, holds the annual rules through the commit, and discards uploads when the wage base changes" do
      rules = create(:annual_tax_config, tax_year: 2026, ss_wage_base: 184_500)
      final!
      steps = []
      record = lambda do |event|
        sql = event.payload[:sql]
        steps << :company_lock if sql.match?(/FROM "companies".*FOR UPDATE/)
        steps << :rules_lock if sql.match?(/FROM "annual_tax_configs".*FOR SHARE/)
        steps << :insert if sql.include?('INSERT INTO "employee_documents"')
      end
      allow(storage).to receive(:upload) { |key, bytes, **| steps << :upload && stored[key] = bytes.dup.b }

      ActiveSupport::Notifications.subscribed(record, "sql.active_record") do
        expect(EmployeeDocuments::PostW2GuCopies.new(company: company, year: 2026, user: staff).call.status).to eq(:posted)
      end
      expect(steps.chunk_while { |a, b| a == b }.map(&:first)).to eq(%i[company_lock upload company_lock rules_lock insert])
      expect(stored.keys).to match_array(EmployeeDocument.tax_forms.pluck(:storage_key))

      # The SS wage base is in the fingerprint; a change while the copies upload posts nothing.
      EmployeeDocumentNotice.delete_all
      EmployeeDocument.delete_all
      stored.clear
      allow(storage).to receive(:upload) do |key, bytes, **|
        stored[key] = bytes.dup.b
        rules.update_columns(ss_wage_base: 190_000)
      end
      expect(EmployeeDocuments::PostW2GuCopies.new(company: company, year: 2026, user: staff).call.status).to eq(:changed)
      expect(EmployeeDocument.count).to eq(0)
      expect(stored).to be_empty
    end

    it "commits a pending notice with each copy, and a rerun recovers a missing one" do
      final!
      poster = EmployeeDocuments::PostW2GuCopies.new(company: company, year: 2026, user: staff)
      expect { poster.call }.to have_enqueued_job(DispatchEmployeeTaxFormNoticesJob).with(company.id)
      notices = EmployeeDocumentNotice.where(company_id: company.id)
      expect(notices.pluck(:employee_document_id, :status)).to contain_exactly([ copy_of(employee).id, "pending" ], [ copy_of(coworker).id, "pending" ])

      # The dispatch job was lost and a notice row is gone: posting again restores and queues it.
      notices.where(employee_document: copy_of(coworker)).delete_all
      expect { expect(poster.call.documents).to be_empty }.to have_enqueued_job(DispatchEmployeeTaxFormNoticesJob).with(company.id)
      expect(notices.where(status: "pending").count).to eq(2)

      # The periodic sweep sends what is pending; with notification email off, each is saved as skipped.
      DispatchEmployeeTaxFormNoticesJob.perform_now
      expect(notices.reload.pluck(:employee_document_id, :status, :skip_reason)).to contain_exactly(
        [ copy_of(employee).id, "skipped", "email_delivery_disabled" ], [ copy_of(coworker).id, "skipped", "no_app_access" ]
      )
      expect { poster.call }.not_to have_enqueued_job(DispatchEmployeeTaxFormNoticesJob)
    end

    it "is refused while the tax forms switch is off" do
      final!
      enable_tax_forms!(company, tax_forms: false)
      post_copies!
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("blocker" => "feature_off")
      expect(EmployeeDocuments::PostW2GuCopies.new(company: company, year: 2026).call.status).to eq(:feature_off)
      expect(EmployeeDocument.count).to eq(0)
    end

    it "needs client administration access" do
      create(:user, role: :accountant, company: company, organization: organization, clerk_id: "user_accountant")
      final!
      post_copies!(headers: bearer("user_accountant").merge("X-Company-Id" => company.id.to_s))
      expect(response).to have_http_status(:forbidden)
      expect(EmployeeDocument.count).to eq(0)
    end
  end

  describe "the employee's copies" do
    before do
      final!
      post_copies!
    end

    it "lists, shows and serves only this employee's frozen copy, without caching, and audits each read" do
      body = forms
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      mine = copy_of(employee)
      expect(body.fetch("tax_forms")).to eq([ {
        "id" => mine.id.to_s, "tax_year" => 2026, "kind" => "w2gu", "status" => "posted", "corrected" => false,
        "posted_at" => mine.posted_at.iso8601, "pdf_available" => true, "available_through" => "2027-10-15"
      } ])

      get "/api/v1/employee/tax_forms/#{mine.id}", headers: employee_headers
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.parsed_body).to include("id" => mine.id.to_s, "status" => "posted")

      get "/api/v1/employee/tax_forms/#{mine.id}/pdf", headers: employee_headers
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["Content-Disposition"]).to include("w-2gu-2026.pdf")
      expect(response.body.b).to eq(stored.fetch(mine.storage_key))

      audits = AuditLog.where(action: %w[employee_tax_form#listed employee_tax_form#viewed employee_tax_form#pdf_downloaded]).order(:id)
      expect(audits.map(&:action)).to eq(%w[employee_tax_form#listed employee_tax_form#viewed employee_tax_form#pdf_downloaded])
      expect(audits.map(&:user_id).uniq).to eq([ worker.id ])
      expect(audits.last.metadata).to include("employee_account_link_id" => link.id, "sha256" => mine.sha256, "tax_year" => 2026)
    end

    it "refuses the PDF when the copy is withdrawn, the link revoked or the switch turned off while storage answers" do
      mine = copy_of(employee)
      {
        withdrawn: -> { mine.update_columns(status: "withdrawn") },
        revoked: -> { link.update_columns(status: "revoked", revoked_at: Time.current, revoked_reason: "spec") },
        switch_off: -> { enable_tax_forms!(company, tax_forms: false) }
      }.each do |name, change|
        allow(storage).to receive(:download) { |key| change.call && stored[key] }
        get "/api/v1/employee/tax_forms/#{mine.id}/pdf", headers: employee_headers
        expect([ name, response.status, response.body ]).to eq([ name, 404, "" ])

        mine.update_columns(status: "posted")
        link.update_columns(status: "active", revoked_at: nil, revoked_reason: nil)
        enable_tax_forms!(company)
      end
      expect(AuditLog.where(action: "employee_tax_form#pdf_downloaded").count).to eq(0)

      allow(storage).to receive(:download) { |key| stored[key] }
      get "/api/v1/employee/tax_forms/#{mine.id}/pdf", headers: employee_headers
      expect(response).to have_http_status(:ok)
    end

    it "keeps a coworker's copy out with the same empty 404" do
      theirs = copy_of(coworker)
      get "/api/v1/employee/tax_forms/#{theirs.id}", headers: employee_headers
      expect_empty_not_found
      get "/api/v1/employee/tax_forms/#{theirs.id}/pdf", headers: employee_headers
      expect_empty_not_found
      get "/api/v1/employee/tax_forms/not-an-id/pdf", headers: employee_headers
      expect_empty_not_found
    end

    it "keeps other companies' copies out, and each link sees only its own company" do
      other_company = create(:company, organization: organization, name: "Harbor Grill")
      enable_tax_forms!(other_company)
      other_employee = create(:employee, company: other_company, department: create(:department, company: other_company))
      other_link = EmployeeAccountLink.create!(user: worker, company: other_company, employee: other_employee, status: "active",
        activated_at: 1.day.ago)
      outsider = create(:employee, company: other_company, department: other_employee.department)
      theirs = frozen_copy!(other_employee)
      foreign = frozen_copy!(outsider)

      expect(forms.fetch("tax_forms").map { |form| form["id"] }).to eq([ copy_of(employee).id.to_s ])
      [ theirs, foreign ].each do |document|
        get "/api/v1/employee/tax_forms/#{document.id}/pdf", headers: employee_headers
        expect_empty_not_found
      end

      expect(forms(headers: employee_headers(other_link)).fetch("tax_forms").map { |form| form["id"] }).to eq([ theirs.id.to_s ])
      get "/api/v1/employee/tax_forms/#{copy_of(employee).id}/pdf", headers: employee_headers(other_link)
      expect_empty_not_found
      get "/api/v1/employee/tax_forms/#{foreign.id}", headers: employee_headers(other_link)
      expect_empty_not_found
    end

    it "is an empty 404 everywhere while the switch is off" do
      enable_tax_forms!(company, tax_forms: false)
      [ "/api/v1/employee/tax_forms", "/api/v1/employee/tax_forms/#{copy_of(employee).id}",
        "/api/v1/employee/tax_forms/#{copy_of(employee).id}/pdf" ].each do |path|
        get path, headers: employee_headers
        expect_empty_not_found
      end
    end

    it "refuses another login and a revoked link the same way" do
      create(:user, role: :portal_employee, company: company, clerk_id: "user_other")
      get "/api/v1/employee/tax_forms", headers: employee_headers(subject: "user_other")
      expect_empty_not_found

      link.update!(status: "revoked", revoked_at: Time.current, revoked_reason: "spec")
      get "/api/v1/employee/tax_forms", headers: employee_headers
      expect_empty_not_found
    end
  end

  describe "withdrawing a copy" do
    before do
      final!
      post_copies!
    end

    it "takes a reason, keeps the copy listed without its PDF, and posting never brings it back" do
      mine = copy_of(employee)
      post "/api/v1/admin/employee_tax_forms/#{mine.id}/withdraw", headers: staff_headers, as: :json, params: { reason: " " }
      expect(response).to have_http_status(:unprocessable_content)

      post "/api/v1/admin/employee_tax_forms/#{mine.id}/withdraw", headers: staff_headers, as: :json,
        params: { reason: "Box 1 is wrong; a W-2c is being prepared" }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("document", "status")).to eq("withdrawn")
      expect(mine.reload).to have_attributes(status: "withdrawn", withdrawn_by_id: staff.id,
        withdrawal_note: "Box 1 is wrong; a W-2c is being prepared")
      audit = AuditLog.where(action: "employee_tax_forms#withdrawn").sole
      expect(audit.metadata).to include("reason" => "Box 1 is wrong; a W-2c is being prepared", "tax_year" => 2026)

      expect(forms.fetch("tax_forms").sole).to include("id" => mine.id.to_s, "status" => "withdrawn", "pdf_available" => false)
      expect(response.body).not_to include("Box 1 is wrong")
      get "/api/v1/employee/tax_forms/#{mine.id}/pdf", headers: employee_headers
      expect_empty_not_found

      expect { post_copies! }.not_to change(EmployeeDocument, :count)
      expect(mine.reload.status).to eq("withdrawn")

      post "/api/v1/admin/employee_tax_forms/#{mine.id}/withdraw", headers: staff_headers, as: :json, params: { reason: "Again" }
      expect(response).to have_http_status(:unprocessable_content)

      get "/api/v1/admin/employee_tax_forms", headers: staff_headers, params: { year: 2026 }
      expect(response).to have_http_status(:ok)
      row = response.parsed_body.fetch("documents").find { |entry| entry["id"] == mine.id }
      expect(row).to include("status" => "withdrawn", "withdrawn_by" => staff.name)
    end

    it "can't withdraw another company's copy" do
      other_company = create(:company, organization: organization)
      foreign = frozen_copy!(create(:employee, company: other_company, department: create(:department, company: other_company)))
      post "/api/v1/admin/employee_tax_forms/#{foreign.id}/withdraw", headers: staff_headers, as: :json, params: { reason: "Wrong" }
      expect(response).to have_http_status(:not_found)
      TenantScope.as_system(reason: "Spec reads another company's copy") { expect(foreign.reload.status).to eq("posted") }
    end
  end

  describe "former employees" do
    it "keep their copies through October 15 of the next year, even when their access would end sooner" do
      final!
      link.update!(status: "former", former_at: Time.current, former_access_until: Time.zone.parse("2027-03-01T13:59:59Z"))
      ended = EmployeeAccountLink.create!(user: create(:user, role: :portal_employee, company: company), company: company,
        employee: coworker, status: "former", former_at: 2.days.ago, former_access_until: 1.minute.ago)
      post_copies!

      retention = EmployeeDocuments::TaxFormRetention.available_through(2026)
      expect(link.reload.former_access_until).to be_within(1.second).of(retention)
      expect(retention.in_time_zone("Pacific/Guam").to_date).to eq(Date.new(2027, 10, 15))
      expect(ended.reload.former_access_until).to be < Time.current
      expect(AuditLog.where(action: "employee_links#former_access_extended_for_tax_form").sole.record_id).to eq(link.id)

      expect(forms.fetch("tax_forms").map { |form| form["tax_year"] }).to eq([ 2026 ])
      get "/api/v1/employee/tax_forms/#{copy_of(employee).id}/pdf", headers: employee_headers
      expect(response).to have_http_status(:ok)

      travel_to(Time.zone.parse("2027-10-15T13:00:00Z")) do
        expect(forms.fetch("tax_forms").size).to eq(1)
      end
      travel_to(Time.zone.parse("2027-10-15T14:00:01Z")) do
        get "/api/v1/employee/tax_forms", headers: employee_headers
        expect_empty_not_found
      end
    end

    it "keep that floor when terminated after the copy posts" do
      final!
      post_copies!
      # The shortest window the client can choose.
      allow(EmployeeLinks::Close).to receive(:former_access_years).and_return(1)
      EmployeeLinks::Close.make_former!(link, termination_date: Date.new(2026, 1, 15), actor: staff)
      expect(link.reload.former_access_until).to be_within(1.second).of(EmployeeDocuments::TaxFormRetention.available_through(2026))
      expect(link.former_profile_access_until).to be_within(1.second).of(Time.find_zone!("Pacific/Guam").local(2027, 1, 15).end_of_day)
    end

    it "keep profile reads to their original cutoff while the copy stays open" do
      enable_tax_forms!(company, profile_requests: true)
      final!
      cutoff = Time.zone.parse("2027-03-01T13:59:59Z")
      # Made former before the original cutoff was recorded separately.
      link.update!(status: "former", former_at: Time.current, former_access_until: cutoff)
      post_copies!
      expect(link.reload.former_access_until).to be_within(1.second).of(EmployeeDocuments::TaxFormRetention.available_through(2026))
      expect(link.former_profile_access_until).to eq(cutoff)

      travel_to(Time.zone.parse("2027-02-01T00:00:00Z")) do
        get "/api/v1/employee/profile", headers: employee_headers
        expect(response).to have_http_status(:ok), response.body
        get "/api/v1/employee/context", headers: employee_headers
        expect(response.parsed_body["features"]).to include("profile_requests" => true, "tax_forms" => true)
      end
      travel_to(Time.zone.parse("2027-04-01T00:00:00Z")) do
        get "/api/v1/employee/profile", headers: employee_headers
        expect_empty_not_found
        get "/api/v1/employee/context", headers: employee_headers
        expect(response.parsed_body["features"]).to include("profile_requests" => false, "tax_forms" => true)
        expect(forms.fetch("tax_forms").size).to eq(1)
        get "/api/v1/employee/tax_forms/#{copy_of(employee).id}/pdf", headers: employee_headers
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "the W-2 delivery setting" do
    it "is set by staff and returned in the employee context" do
      get "/api/v1/employee/context", headers: employee_headers
      expect(response.parsed_body).to include("w2_delivery" => nil)

      patch "/api/v1/admin/employee_app_settings/w2_delivery", headers: staff_headers, as: :json, params: { w2_delivery: "mailed" }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("data", "w2_delivery")).to eq("mailed")
      expect(AuditLog.where(action: "employee_app_settings#update_w2_delivery").sole.metadata)
        .to include("before_values" => { "w2_delivery" => nil }, "after_values" => { "w2_delivery" => "mailed" })
      get "/api/v1/employee/context", headers: employee_headers
      expect(response.parsed_body).to include("w2_delivery" => "mailed")

      patch "/api/v1/admin/employee_app_settings/w2_delivery", headers: staff_headers, as: :json, params: { w2_delivery: "carrier pigeon" }
      expect(response).to have_http_status(:unprocessable_content)
      patch "/api/v1/admin/employee_app_settings/w2_delivery", headers: staff_headers, as: :json, params: { w2_delivery: "handed_out" }
      expect(company.reload.w2_delivery).to eq("handed_out")
      patch "/api/v1/admin/employee_app_settings/w2_delivery", headers: staff_headers, as: :json, params: { w2_delivery: nil }
      expect(company.reload.w2_delivery).to be_nil
    end

    it "isn't editable from the client portal" do
      client_user = create(:user, role: :client, company: company, organization: organization, clerk_id: "user_client")
      patch "/api/v1/client/employee_app_settings/w2_delivery", headers: bearer("user_client").merge("X-Company-Id" => company.id.to_s),
        as: :json, params: { w2_delivery: "mailed" }
      expect(response).to have_http_status(:not_found)
      expect(company.reload.w2_delivery).to be_nil
      expect(client_user).to be_persisted
    end
  end

  describe "the notice email" do
    around do |example|
      previous = ENV.to_h.slice("PORTAL_EMAIL_NOTIFICATIONS_ENABLED", "PORTAL_EMAIL_TRANSPORT")
      ENV["PORTAL_EMAIL_NOTIFICATIONS_ENABLED"] = "true"
      ENV["PORTAL_EMAIL_TRANSPORT"] = "capture"
      PortalNotifications::Transport.clear_captured!
      example.run
    ensure
      %w[PORTAL_EMAIL_NOTIFICATIONS_ENABLED PORTAL_EMAIL_TRANSPORT].each { |key| ENV[key] = previous[key] }
      PortalNotifications::Transport.clear_captured!
    end

    def post_with_notices!
      perform_enqueued_jobs(only: [ PostEmployeeW2GuCopiesJob, DispatchEmployeeTaxFormNoticesJob ]) do
        post "/api/v1/admin/employee_tax_forms/post_copies", headers: staff_headers, as: :json, params: { year: 2026 }
      end
    end

    it "goes once, only to the employee's verified email, with the required subject and no tax details" do
      final!
      post_with_notices!

      email = PortalNotifications::Transport.captured.sole
      expect(email).to include(to: "jordan.own@example.net", subject: "IMPORTANT TAX RETURN DOCUMENT AVAILABLE")
      expect(email[:text]).to include("Your 2026 Form W-2GU from Tumon Bakery is now available", "#{EmployeeLinkHelpers::APP_URL}/taxes",
        "paper copy")
      expect(email[:text]).not_to match(/\$|2,000|1600|6789|Santos/)

      mine = EmployeeDocumentNotice.find_by!(employee_document: copy_of(employee))
      expect(mine).to have_attributes(status: "sent", delivery_status: "unknown", recipient_email: "jordan.own@example.net",
        provider_message_id: nil, attempts: 1)
      # The coworker has no app link (and no email).
      expect(EmployeeDocumentNotice.find_by!(employee_document: copy_of(coworker))).to have_attributes(status: "skipped", skip_reason: "no_app_access")

      expect { DispatchEmployeeTaxFormNoticesJob.perform_now(company.id) }
        .not_to(change { PortalNotifications::Transport.captured.size })
    end

    it "skips an unverified address" do
      employee.update_columns(email_verified_at: nil)
      final!
      post_with_notices!
      expect(PortalNotifications::Transport.captured).to be_empty
      expect(EmployeeDocumentNotice.find_by!(employee_document: copy_of(employee)))
        .to have_attributes(status: "skipped", skip_reason: "email_not_verified")
    end

    it "is saved as skipped while notification email is off" do
      ENV["PORTAL_EMAIL_NOTIFICATIONS_ENABLED"] = "false"
      final!
      post_with_notices!
      expect(PortalNotifications::Transport.captured).to be_empty
      expect(EmployeeDocumentNotice.find_by!(employee_document: copy_of(employee)).skip_reason).to eq("email_delivery_disabled")
    end

    it "retries a failed send from the sweep after a pause" do
      final!
      allow(PortalNotifications::Transport).to receive(:deliver).and_raise(Timeout::Error)
      post_with_notices!
      mine = EmployeeDocumentNotice.find_by!(employee_document: copy_of(employee))
      expect(mine).to have_attributes(status: "failed", attempts: 1)

      allow(PortalNotifications::Transport).to receive(:deliver).and_call_original
      DispatchEmployeeTaxFormNoticesJob.perform_now
      expect(mine.reload).to have_attributes(status: "failed", attempts: 1)
      travel(DispatchEmployeeTaxFormNoticesJob::RETRY_AFTER + 1.minute) { DispatchEmployeeTaxFormNoticesJob.perform_now }
      expect(mine.reload).to have_attributes(status: "sent", attempts: 2)
      expect(PortalNotifications::Transport.captured.size).to eq(1)
    end

    it "applies a bounce that arrived before the send committed" do
      ENV["PORTAL_EMAIL_TRANSPORT"] = nil
      allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "re_msg_1" })
      EmployeeDocuments::NoticeDeliveryEvent.store!(event_id: "msg_early", event_type: "email.bounced", message_id: "re_msg_1",
        status: "bounced", bounce_type: "Permanent", occurred_at: Time.current.iso8601)
      final!
      post_with_notices!
      expect(EmployeeDocumentNotice.find_by!(employee_document: copy_of(employee)))
        .to have_attributes(status: "sent", provider_message_id: "re_msg_1", delivery_status: "bounced", bounce_type: "Permanent")
    end

    it "records the provider id when Resend accepts it" do
      ENV["PORTAL_EMAIL_TRANSPORT"] = nil
      allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "re_msg_1" })
      final!
      post_with_notices!
      expect(EmployeeDocumentNotice.find_by!(employee_document: copy_of(employee)))
        .to have_attributes(status: "sent", provider_message_id: "re_msg_1", delivery_status: "unknown")
    end
  end
end
