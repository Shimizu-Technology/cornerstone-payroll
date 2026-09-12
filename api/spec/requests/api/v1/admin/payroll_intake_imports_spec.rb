# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe "Api::V1::Admin::PayrollIntakeImports", type: :request do
  let!(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization, payroll_intake_source_types: [ "spike_email" ]) }
  let!(:admin_user) { create(:user, company: company, role: "admin") }
  let!(:company_workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      effective_on: Date.new(2026, 1, 1),
      confirmed_by: admin_user,
      confirmed_at: Time.current,
      notes: "Confirmed for Spike payroll intake"
    )
  end
  let!(:tax_table) do
    TaxTable.find_by(tax_year: 2026, filing_status: "single", pay_frequency: "biweekly") ||
      create(:tax_table, tax_year: 2026, filing_status: "single", pay_frequency: "biweekly")
  end
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 6, 14),
      end_date: Date.new(2026, 6, 27),
      pay_date: Date.new(2026, 7, 3),
      status: "draft"
    )
  end
  let!(:alice) { create(:employee, company: company, first_name: "Alice", last_name: "Barista", pay_rate: 15.00) }
  let!(:bob) { create(:employee, company: company, first_name: "Bob", last_name: "Roaster", pay_rate: 16.00) }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollIntakeImportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollIntakeImportsController).to receive(:current_user).and_return(admin_user)
  end

  describe "POST /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/preview" do
    it "previews a Spike email table into canonical payroll intake rows" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      rows = json.dig("import", "rows")

      expect(rows.length).to eq(2)
      alice_row = rows.find { |row| row["source_employee_name"] == "Alice Barista" }
      expect(alice_row["employee_id"]).to eq(alice.id)
      expect(alice_row["regular_hours"]).to eq(78.0)
      expect(alice_row["overtime_hours"]).to eq(2.0)
      expect(alice_row["reported_tips"]).to eq(126.0)
      expect(alice_row["tips_paid_out"]).to eq(126.0)
      expect(json.dig("import", "totals", "total_tips_paid_out")).to eq(151.0)
      expect(json.dig("import", "evidence_snapshot", "workweek")).to include(
        "company_workweek_id" => company_workweek.id,
        "pay_period_start" => "2026-06-14",
        "pay_period_end" => "2026-06-27",
        "legal_week_starts" => [ "2026-06-14", "2026-06-21" ]
      )
      expect(json.dig("import", "evidence_snapshot", "source_period")).to eq(
        "start_date" => "2026-06-14",
        "end_date" => "2026-06-27"
      )
      expect(json.dig("import", "package_id")).to be_present
      expect(json.dig("import", "package_revision")).to eq(1)
      expect(json.dig("import", "package_schema_version")).to eq(PayrollIntakeSession::PACKAGE_SCHEMA_VERSION)
      expect(json.dig("import", "documents", 0)).to include(
        "source_role" => "pasted_email",
        "position" => 0,
        "verification_status" => "verified",
        "byte_size" => spike_text.bytesize,
        "sha256" => Digest::SHA256.hexdigest(spike_text)
      )
    end

    it "rejects intake before extraction when the legal workweek is not confirmed" do
      company_workweek.update_columns(confirmation_status: "needs_confirmation", confirmed_by_id: nil, confirmed_at: nil)

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Confirm the employer's legal overtime workweek")
      expect(PayrollIntakeSession.count).to eq(0)
    end

    it "rejects a pay period that is not two complete legal workweeks" do
      pay_period.update!(
        start_date: Date.new(2026, 6, 15),
        end_date: Date.new(2026, 6, 28),
        pay_date: Date.new(2026, 7, 3)
      )

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("begin on the confirmed legal workweek start day")
      expect(PayrollIntakeSession.count).to eq(0)
    end

    it "rejects source dates that do not exactly match the selected pay period" do
      mismatched_text = spike_text.sub("06/14/2026 - 06/27/2026", "06/15/2026 - 06/28/2026")

      post preview_path, params: { source_type: "spike_email", pasted_text: mismatched_text }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("does not match this pay period")
      expect(PayrollIntakeSession.count).to eq(0)
    end

    it "previews the real Spike email body format with total hours and weekly tips" do
      haane = create(:employee, company: company, first_name: "Ha'ane", last_name: "Akima", pay_rate: 15.00)
      create(:employee, company: company, first_name: "Mia", last_name: "Lahnee Aquino", pay_rate: 15.00)
      create(:employee, company: company, first_name: "Jacqueline", last_name: "Martinez", pay_rate: 15.00)

      post preview_path, params: { source_type: "spike_email", pasted_text: real_spike_email_text }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      rows = json.dig("import", "rows")

      expect(rows.map { |row| row["source_employee_name"] }).to eq([ "Ha’ane Akima", "Mia Lahnee Aquino", "Jacqueline Martinez" ])
      expect(json.dig("import", "warnings")).to be_empty

      haane_row = rows.first
      expect(haane_row["employee_id"]).to eq(haane.id)
      expect(haane_row["week1_hours"]).to eq(0.0)
      expect(haane_row["week2_hours"]).to eq(0.0)
      expect(haane_row["regular_hours"]).to eq(45.25)
      expect(haane_row["overtime_hours"]).to eq(0.0)
      expect(haane_row["week1_tips"]).to eq(133.0)
      expect(haane_row["week2_tips"]).to eq(57.0)
      expect(haane_row["reported_tips"]).to eq(190.0)
      expect(haane_row["tips_paid_out"]).to eq(190.0)
      expect(haane_row["warnings"]).to be_empty
      expect(haane_row["errors"].map { |error| error["code"] }).to include("weekly_hours_required")

      jacqueline_row = rows.third
      expect(jacqueline_row["week1_tips"]).to eq(124.0)
      expect(jacqueline_row["week2_tips"]).to eq(0.0)
      expect(jacqueline_row["reported_tips"]).to eq(124.0)
    end

    it "rejects a source type that is not enabled for the company" do
      company.update!(payroll_intake_source_types: [])

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch("error")).to include("not enabled")
    end

    it "returns the existing session for duplicate source content with the same parser version" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      first_id = JSON.parse(response.body).dig("import", "id")

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("import", "id")).to eq(first_id)
      expect(json["duplicate"]).to eq(true)
      expect(json.dig("import", "warnings").map { |warning| warning["code"] }).to include("duplicate_source")
    end

    it "requires an explicit correction reason before a different source replaces the current package" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      current_package = response.parsed_body.fetch("import")

      post preview_path, params: {
        source_type: "spike_email",
        pasted_text: spike_text.sub("$75.75", "$76.75")
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Confirm that this corrected source replaces revision 1")
      expect(response.parsed_body.dig("details", "replacement_required")).to be(true)
      expect(response.parsed_body.dig("details", "current_package", "package_id")).to eq(current_package.fetch("package_id"))
      expect(PayrollIntakeSession.where(pay_period: pay_period).count).to eq(1)
    end

    it "invalidates an existing calculation when the first source arrives after calculation began" do
      pay_period.update!(status: "calculated", calculated_at: 1.hour.ago, calculated_by_id: admin_user.id)

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload).to have_attributes(
        status: "draft",
        calculated_at: nil,
        intake_stale_session_id: response.parsed_body.dig("import", "id")
      )
      expect(pay_period.intake_stale_reason).to include("received after payroll calculation began")
    end

    it "does not reuse a stale duplicate preview after the parser version changes" do
      stub_const("PayrollIntake::Adapters::SpikeEmail::PARSER_VERSION", "spike_email:test-v1")
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      first_package = JSON.parse(response.body).fetch("import")

      stub_const("PayrollIntake::Adapters::SpikeEmail::PARSER_VERSION", "spike_email:test-v2")
      post preview_path, params: {
        source_type: "spike_email",
        pasted_text: spike_text,
        supersedes_package_id: first_package.fetch("package_id"),
        supersession_reason: "Re-previewed with the corrected parser."
      }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("import", "id")).not_to eq(first_package.fetch("id"))
      expect(json["duplicate"]).to eq(false)
      expect(json.dig("import", "parser_version")).to eq("spike_email:test-v2")
      expect(json.dig("import", "package_revision")).to eq(2)
      expect(json.dig("import", "supersedes_package_id")).to eq(first_package.fetch("package_id"))
      expect(PayrollIntakeSession.find(first_package.fetch("id"))).to be_superseded
    end

    it "uploads source files outside the database transaction" do
      baseline_transactions = ActiveRecord::Base.connection.open_transactions
      upload_transactions = []
      storage = Class.new do
        define_method(:initialize) do |transactions|
          @transactions = transactions
          @objects = {}
        end

        def upload(key, data, content_type:)
          @transactions << ActiveRecord::Base.connection.open_transactions
          @objects[key] = data
          "https://storage.example/#{content_type}"
        end

        def download_with_limit(key, max_bytes:)
          value = @objects[key]
          value if value&.bytesize.to_i <= max_bytes
        end

        def delete(key)
          @objects.delete(key)
        end
      end.new(upload_transactions)

      tempfile = Tempfile.new([ "spike-intake", ".png" ])
      tempfile.binmode
      tempfile.write("image-bytes")
      tempfile.rewind
      upload = double("upload", tempfile: tempfile, original_filename: "spike.png", content_type: "image/png")

      result = PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "spike_email",
        pasted_text: spike_text,
        files: [ upload ],
        actor: admin_user,
        storage: storage
      ).call

      expect(upload_transactions).to eq([ baseline_transactions ])
      document = result[:session].documents.find_by!(document_type: "image")
      expect(document).to have_attributes(
        source_role: "email_attachment",
        verification_status: "verified",
        byte_size: 11,
        sha256: Digest::SHA256.hexdigest("image-bytes")
      )
    ensure
      tempfile&.close!
    end

    it "removes an upload and creates no package when retained bytes cannot be verified" do
      storage = instance_double(R2StorageService)
      allow(storage).to receive(:upload).and_return("local-r2://retained-source")
      allow(storage).to receive(:download_with_limit).and_return("corrupt")
      expect(storage).to receive(:delete).with(a_string_including("payroll-intake/#{company.id}/#{pay_period.id}/"))

      tempfile = Tempfile.new([ "spike-intake", ".png" ])
      tempfile.binmode
      tempfile.write("image-bytes")
      tempfile.rewind
      upload = double("upload", tempfile: tempfile, original_filename: "spike.png", content_type: "image/png")

      expect {
        PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "spike_email",
          pasted_text: spike_text,
          files: [ upload ],
          actor: admin_user,
          storage: storage
        ).call
      }.to raise_error(R2StorageService::UploadError, /could not be verified/)
      expect(PayrollIntakeSession.where(pay_period: pay_period)).to be_empty
    ensure
      tempfile&.close!
    end
  end


  describe "GET /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/:id/documents/:document_id/download" do
    it "returns fingerprint-verified source evidence and records the access" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      document = PayrollIntakeSession.last.documents.first

      get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/#{document.payroll_intake_session_id}/documents/#{document.id}/download"

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(spike_text)
      expect(response.headers.fetch("Content-Disposition")).to include("attachment")
      expect(AuditLog.where(action: "payroll_intake_imports#download_source_document", record_id: document.payroll_intake_session_id)).to exist
    end

    it "does not expose a source package through another company" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      document = PayrollIntakeSession.last.documents.first
      other_company = create(:company, organization: organization)
      allow_any_instance_of(Api::V1::Admin::PayrollIntakeImportsController).to receive(:current_company_id).and_return(other_company.id)

      get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/#{document.payroll_intake_session_id}/documents/#{document.id}/download"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/:id/apply" do
    it "applies reviewed Spike rows as taxable reported tips and paid-out tip offsets" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")

      post apply_path(import.fetch("id")), params: {
        acknowledge_warnings: true,
        rows: import.fetch("rows").map { |row| { id: row.fetch("id"), include: true, employee_id: row.fetch("employee_id") } }
      }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("results", "errors")).to be_empty
      expect(json.dig("results", "applied").length).to eq(2)
      expect(json.dig("pay_period", "status")).to eq("calculated")

      alice_item = pay_period.payroll_items.find_by!(employee_id: alice.id)
      expect(alice_item.import_source).to eq("spike_email")
      expect(alice_item.hours_worked.to_f).to eq(78.0)
      expect(alice_item.overtime_hours.to_f).to eq(2.0)
      expect(alice_item.reported_tips.to_f).to eq(126.0)
      expect(alice_item.tips_paid_out.to_f).to eq(126.0)
      expect(alice_item.gross_pay.to_f).to be > 126.0
    end

    it "preserves the applied revision but blocks approval until its corrected replacement is applied" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      first_package = response.parsed_body.fetch("import")
      post apply_path(first_package.fetch("id")), params: {
        acknowledge_warnings: true,
        rows: first_package.fetch("rows").map do |source_row|
          { id: source_row.fetch("id"), disposition: "included", employee_id: source_row.fetch("employee_id") }
        end
      }
      expect(response).to have_http_status(:ok)

      post preview_path, params: {
        source_type: "spike_email",
        pasted_text: spike_text.sub("$75.75", "$76.75"),
        supersedes_package_id: first_package.fetch("package_id"),
        supersession_reason: "Client corrected Alice's second-week tips."
      }

      expect(response).to have_http_status(:ok)
      corrected = response.parsed_body.fetch("import")
      expect(corrected).to include(
        "package_revision" => 2,
        "current" => true,
        "supersedes_package_id" => first_package.fetch("package_id"),
        "supersession_reason" => "Client corrected Alice's second-week tips."
      )
      expect(PayrollIntakeSession.find(first_package.fetch("id"))).to be_superseded
      expect(pay_period.reload).to have_attributes(
        status: "draft",
        calculated_at: nil,
        intake_stale_session_id: corrected.fetch("id")
      )
      expect {
        PayPeriodLifecycleService.new(pay_period: pay_period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Apply the current source package/)
    end

    it "blocks duplicate employee mappings within the same intake session" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")

      post apply_path(import.fetch("id")), params: {
        acknowledge_warnings: true,
        rows: import.fetch("rows").map { |row| { id: row.fetch("id"), include: true, employee_id: alice.id } }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      errors = json.dig("results", "errors")
      expect(errors.length).to eq(2)
      expect(errors.map { |error| error.fetch("error") }).to all(include("Multiple included intake rows map"))
      expect(pay_period.payroll_items.reload).to be_empty
    end

    it "blocks overwriting manual payroll items unless force_overwrite is supplied" do
      create(:payroll_item, pay_period: pay_period, company: company, employee: alice, import_source: nil, hours_worked: 1)
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")

      post apply_path(import.fetch("id")), params: {
        acknowledge_warnings: true,
        rows: import.fetch("rows").map { |row| { id: row.fetch("id"), include: true, employee_id: row.fetch("employee_id") } }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json.dig("results", "errors").first.fetch("error")).to include("already exists")
      expect(pay_period.payroll_items.find_by!(employee_id: alice.id).import_source).to be_nil
    end

    it "clears stale manual fields when force overwriting an existing payroll item" do
      alice.update!(additional_withholding: 7)
      create(
        :payroll_item,
        pay_period: pay_period,
        company: company,
        employee: alice,
        import_source: nil,
        hours_worked: 1,
        holiday_hours: 8,
        pto_hours: 4,
        bonus: 100,
        salary_override: 1234,
        non_taxable_pay: 50,
        loan_deduction: 99,
        loan_payment: 12,
        insurance_payment: 34,
        additional_withholding: 99,
        additional_withholding_override: 88,
        withholding_tax_adjustment: 77,
        withholding_tax_override: 66,
        custom_earnings: [ { "label" => "Stale earning", "amount" => 25 } ],
        custom_deductions: [ { "label" => "Stale deduction", "amount" => 10 } ],
        payroll_adjustments: [ { "label" => "Stale adjustment", "amount" => 15, "treatment" => "post_tax_deduction", "active" => true } ]
      )
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")

      post apply_path(import.fetch("id")), params: {
        acknowledge_warnings: true,
        force_overwrite: true,
        rows: import.fetch("rows").map do |row|
          included = row.fetch("source_employee_name") == "Alice Barista"
          {
            id: row.fetch("id"),
            disposition: included ? "included" : "excluded",
            disposition_reason: included ? nil : "Not part of this reviewed payroll run.",
            employee_id: row.fetch("employee_id")
          }
        end
      }

      expect(response).to have_http_status(:ok)
      item = pay_period.payroll_items.find_by!(employee_id: alice.id)
      expect(item.import_source).to eq("spike_email")
      expect(item.hours_worked.to_f).to eq(78.0)
      expect(item.overtime_hours.to_f).to eq(2.0)
      expect(item.holiday_hours.to_f).to eq(0.0)
      expect(item.pto_hours.to_f).to eq(0.0)
      expect(item.bonus.to_f).to eq(0.0)
      expect(item.salary_override).to be_nil
      expect(item.non_taxable_pay.to_f).to eq(0.0)
      expect(item.loan_deduction.to_f).to eq(0.0)
      expect(item.loan_payment.to_f).to eq(0.0)
      expect(item.insurance_payment.to_f).to eq(0.0)
      expect(item.additional_withholding.to_f).to eq(7.0)
      expect(item.additional_withholding_override).to be_nil
      expect(item.withholding_tax_adjustment).to be_nil
      expect(item.withholding_tax_override).to be_nil
      expect(item.custom_earnings).to eq([])
      expect(item.custom_deductions).to eq([])
      expect(item.payroll_adjustments).to eq([])
    end

    it "preserves manually overridden adjustments when force overwriting intake fields" do
      manual_adjustment = {
        "label" => "Reviewed period adjustment",
        "amount" => 42.0,
        "treatment" => "post_tax_deduction",
        "active" => true
      }
      item = create(
        :payroll_item,
        pay_period: pay_period,
        company: company,
        employee: alice,
        import_source: nil,
        hours_worked: 1,
        payroll_adjustments: [ manual_adjustment ]
      )
      item.mark_payroll_adjustments_overridden!
      item.save!
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")

      post apply_path(import.fetch("id")), params: {
        acknowledge_warnings: true,
        force_overwrite: true,
        rows: import.fetch("rows").map do |intake_row|
          included = intake_row.fetch("source_employee_name") == "Alice Barista"
          {
            id: intake_row.fetch("id"),
            disposition: included ? "included" : "excluded",
            disposition_reason: included ? nil : "Not part of this reviewed payroll run.",
            employee_id: intake_row.fetch("employee_id")
          }
        end
      }

      expect(response).to have_http_status(:ok)
      expect(item.reload.payroll_adjustments).to contain_exactly(include(manual_adjustment))
      expect(item).to be_payroll_adjustments_overridden
    end

    it "preserves required variable salary overrides when force overwriting" do
      alice.update!(employment_type: "salary", salary_type: "variable", pay_rate: 0)
      create(
        :payroll_item,
        :salary,
        pay_period: pay_period,
        company: company,
        employee: alice,
        import_source: nil,
        salary_override: 1_234,
        hours_worked: 0,
        overtime_hours: 0
      )
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")

      post apply_path(import.fetch("id")), params: {
        acknowledge_warnings: true,
        force_overwrite: true,
        rows: import.fetch("rows").map do |row|
          included = row.fetch("source_employee_name") == "Alice Barista"
          {
            id: row.fetch("id"),
            disposition: included ? "included" : "excluded",
            disposition_reason: included ? nil : "Not part of this reviewed payroll run.",
            employee_id: row.fetch("employee_id")
          }
        end
      }

      expect(response).to have_http_status(:ok)
      item = pay_period.payroll_items.find_by!(employee_id: alice.id)
      expect(item.salary_override.to_f).to eq(1_234.0)
      expect(item.gross_pay.to_f).to eq(1_360.0)
    end

    it "rechecks session applicability after acquiring the lock" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")
      stale_session = PayrollIntakeSession.find(import.fetch("id"))
      stale_session.update_columns(status: "previewed")
      PayrollIntakeSession.where(id: stale_session.id).update_all(status: "applied", applied_at: Time.current)

      service = PayrollIntake::ApplyService.new(
        session: stale_session,
        row_overrides: import.fetch("rows").map { |row| { id: row.fetch("id"), include: true, employee_id: row.fetch("employee_id") } },
        actor: admin_user,
        acknowledge_warnings: true
      )

      expect { service.call }.to raise_error(ArgumentError, /Only previewed payroll intake sessions can be applied/)
      expect(pay_period.payroll_items.reload).to be_empty
    end

    it "rechecks pay period editability after acquiring the lock" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      import = JSON.parse(response.body).fetch("import")
      stale_session = PayrollIntakeSession.find(import.fetch("id"))
      stale_session.pay_period.status
      service = PayrollIntake::ApplyService.new(
        session: stale_session,
        row_overrides: import.fetch("rows").map { |row| { id: row.fetch("id"), include: true, employee_id: row.fetch("employee_id") } },
        actor: admin_user,
        acknowledge_warnings: true
      )
      PayPeriod.where(id: pay_period.id).update_all(status: "committed", committed_at: Time.current)

      expect { service.call }.to raise_error(ArgumentError, /Cannot apply to a non-editable pay period/)
      expect(pay_period.payroll_items.reload).to be_empty
    end
  end

  def preview_path
    "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/preview"
  end

  def apply_path(import_id)
    "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/#{import_id}/apply"
  end

  def spike_text
    <<~TEXT
      Spike Coffee Roasters Payroll
      Pay period: 06/14/2026 - 06/27/2026
      Employee,Week 1 Hours,Week 2 Hours,Week 1 Tips,Week 2 Tips
      Alice Barista,38,42,$50.25,$75.75
      Bob Roaster,20,21,$10.00,$15.00
    TEXT
  end

  def real_spike_email_text
    <<~TEXT
      Spike Coffee Roasters payroll 6/14/26-6/27/26

      Hafa Adai,

      Here are the hours and tips accumulated for the pay period 6/14/26-6/27/26.

      Ha’ane Akima 45.25 hours
      6/14-6/20 $133
      6/21-6/27 $57

      Mia Lahnee Aquino 10.48 hours
      6/14-6/20 $30
      6/21-6/27 $12

      Jacqueline Martinez 15.72 hours
      6/14-6/20 $124
      6/21-6/27 no tips accumulated
    TEXT
  end
end
