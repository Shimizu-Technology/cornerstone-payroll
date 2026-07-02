# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe "Api::V1::Admin::PayrollIntakeImports", type: :request do
  let!(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization, payroll_intake_source_types: [ "spike_email" ]) }
  let!(:admin_user) { create(:user, company: company, role: "admin") }
  let!(:tax_table) { create(:tax_table, tax_year: 2026, filing_status: "single", pay_frequency: "biweekly") }
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 14),
      pay_date: Date.new(2026, 6, 19),
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
    end

    it "rejects a source type that is not enabled for the company" do
      company.update!(payroll_intake_source_types: [])

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch("error")).to include("not enabled")
    end

    it "returns the existing session for duplicate source content" do
      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }
      first_id = JSON.parse(response.body).dig("import", "id")

      post preview_path, params: { source_type: "spike_email", pasted_text: spike_text }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("import", "id")).to eq(first_id)
      expect(json["duplicate"]).to eq(true)
      expect(json.dig("import", "warnings").map { |warning| warning["code"] }).to include("duplicate_source")
    end

    it "uploads source files outside the database transaction" do
      baseline_transactions = ActiveRecord::Base.connection.open_transactions
      upload_transactions = []
      storage = Class.new do
        define_method(:initialize) { |transactions| @transactions = transactions }

        def upload(_key, _data, content_type:)
          @transactions << ActiveRecord::Base.connection.open_transactions
          "https://storage.example/#{content_type}"
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
      expect(result[:session].documents.where(document_type: "image").count).to eq(1)
    ensure
      tempfile&.close!
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
          {
            id: row.fetch("id"),
            include: row.fetch("source_employee_name") == "Alice Barista",
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
      expect(item.additional_withholding.to_f).to eq(7.0)
      expect(item.additional_withholding_override).to be_nil
      expect(item.withholding_tax_adjustment).to be_nil
      expect(item.withholding_tax_override).to be_nil
      expect(item.custom_earnings).to eq([])
      expect(item.custom_deductions).to eq([])
      expect(item.payroll_adjustments).to eq([])
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
          {
            id: row.fetch("id"),
            include: row.fetch("source_employee_name") == "Alice Barista",
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
      Pay period: 06/01/2026 - 06/14/2026
      Employee,Week 1 Hours,Week 2 Hours,Week 1 Tips,Week 2 Tips
      Alice Barista,38,42,$50.25,$75.75
      Bob Roaster,20,21,$10.00,$15.00
    TEXT
  end
end
