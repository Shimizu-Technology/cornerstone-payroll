# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Track C B7: per-company tip and overtime intake settings" do
  let(:organization) { create(:organization) }
  let(:staff) { create(:user, organization: organization, company: company, role: "admin") }
  let(:company) { create(:company, organization: organization, payroll_intake_source_types: [ "spike_email" ]) }
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 6, 14),
      end_date: Date.new(2026, 6, 27),
      pay_date: Date.new(2026, 7, 3),
      status: "draft"
    )
  end
  let!(:employee) { create(:employee, company: company, first_name: "Alice", last_name: "Barista", pay_rate: 15.00) }
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      effective_on: Date.new(2026, 1, 1),
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: staff,
      confirmed_at: Time.current,
      notes: "Confirmed workweek"
    )
  end
  let!(:tax_config) do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    config
  end
  let(:detected_period) { { start_date: "2026-06-14", end_date: "2026-06-27" } }

  def create_profile!(tips_default: "already_paid_out", overtime_mode: "weekly_split", workweek_alignment: "aligned", intake_adapter: "spike_email", effective_on: Date.new(2026, 1, 1))
    options = OperatingProfileCatalog.default_options
    options["tips"]["default"] = tips_default
    options["overtime"]["mode"] = overtime_mode
    options["workweek"]["alignment"] = workweek_alignment
    ClientOperatingProfile.create!(
      company: company,
      effective_on: effective_on,
      ends_on: nil,
      version: 1,
      offering: "payroll_service",
      hours_source: "intake_adapter",
      intake_adapter: intake_adapter,
      client_portal_enabled: false,
      employee_portal_enabled: false,
      options: options,
      reason: "Test settings"
    )
  end

  describe "PayrollIntake::EffectiveSettings defaults and precedence" do
    it "reproduces today's defaults for MoSa and Spike when no operating profile is persisted" do
      dual = create(:company, organization: organization, payroll_intake_source_types: %w[mosa_revel spike_email])

      mosa = PayrollIntake::EffectiveSettings.for(company: dual, source_type: "mosa_revel")
      expect(mosa).to have_attributes(
        tips_default: "paid_in_check",
        overtime_mode: "source_reports",
        workweek_alignment: "warn_if_offset",
        source: "adapter_descriptor"
      )

      spike = PayrollIntake::EffectiveSettings.for(company: dual, source_type: "spike_email")
      expect(spike).to have_attributes(
        tips_default: "already_paid_out",
        overtime_mode: "weekly_split",
        workweek_alignment: "aligned",
        source: "adapter_descriptor"
      )
    end

    it "prefers an effective persisted ClientOperatingProfile over company_intake_settings and descriptor defaults" do
      company.update!(payroll_intake_settings: {
        "spike_email" => { "tips_default" => "paid_in_check", "overtime_mode" => "total_as_regular_warn_over_80" }
      })
      from_company = PayrollIntake::EffectiveSettings.for(company: company, pay_period: pay_period, source_type: "spike_email")
      expect(from_company).to have_attributes(
        tips_default: "paid_in_check",
        overtime_mode: "total_as_regular_warn_over_80",
        source: "company_intake_settings"
      )

      create_profile!(tips_default: "already_paid_out", overtime_mode: "source_reports", workweek_alignment: "warn_if_offset")
      from_profile = PayrollIntake::EffectiveSettings.for(company: company, pay_period: pay_period, source_type: "spike_email")
      expect(from_profile).to have_attributes(
        tips_default: "already_paid_out",
        overtime_mode: "source_reports",
        workweek_alignment: "warn_if_offset",
        source: "operating_profile"
      )
    end

    it "validates tips_default, overtime_mode, workweek_alignment, and rejects unknown keys on Company" do
      company.payroll_intake_settings = { "spike_email" => { "tips_default" => "invalid_mode" } }
      expect(company).not_to be_valid
      expect(company.errors[:payroll_intake_settings].join).to include("tips_default")

      company.payroll_intake_settings = { "spike_email" => { "overtime_mode" => "magic" } }
      expect(company).not_to be_valid
      expect(company.errors[:payroll_intake_settings].join).to include("overtime_mode")

      company.payroll_intake_settings = { "spike_email" => { "unknown_key" => true } }
      expect(company).not_to be_valid
      expect(company.errors[:payroll_intake_settings].join).to include("unknown spike_email setting")
    end
  end

  describe "tips.default and per-row override" do
    it "seeds tips_paid_out from the company setting and lets an explicit row value win with evidence" do
      create_profile!(tips_default: "paid_in_check", overtime_mode: "weekly_split")
      bob = create(:employee, company: company, first_name: "Bob", last_name: "Roaster", pay_rate: 16.00)

      result = PayrollIntake::Adapters::SpikeEmail.new(pay_period: pay_period, company: company).normalize(
        detected_period: detected_period,
        extracted_rows: [
          { employee_name: employee.full_name, week1_hours: 40, week2_hours: 40, total_tips: 100.25 },
          { employee_name: bob.full_name, week1_hours: 40, week2_hours: 40, total_tips: 50.50, tips_already_paid: true }
        ]
      )

      expect(result.dig(:evidence, "tip_treatment")).to eq("default" => "paid_in_check", "source" => "operating_profile")
      alice_row, bob_row = result.fetch(:rows)
      expect(alice_row).to include(reported_tips: 100.25, tips_paid_out: 0.0)
      expect(alice_row[:source_payload]).to include("resolved_tip_treatment" => "paid_in_check", "tip_treatment_source" => "operating_profile")
      expect(bob_row).to include(reported_tips: 50.50, tips_paid_out: 50.50)
      expect(bob_row[:source_payload]).to include("resolved_tip_treatment" => "already_paid_out", "tip_treatment_source" => "row_override")
    end

    it "allows an explicit row override to mark tips paid in check when company default is already_paid_out" do
      result = PayrollIntake::Adapters::SpikeEmail.new(pay_period: pay_period, company: company).normalize(
        detected_period: detected_period,
        extracted_rows: [
          { employee_name: employee.full_name, week1_hours: 40, week2_hours: 40, total_tips: 75.00, tips_already_paid: false }
        ]
      )

      row = result.fetch(:rows).sole
      expect(row).to include(reported_tips: 75.0, tips_paid_out: 0.0)
      expect(row[:source_payload]).to include("resolved_tip_treatment" => "paid_in_check", "tip_treatment_source" => "row_override")
    end
  end

  describe "overtime.mode = total_as_regular_warn_over_80" do
    before do
      create_profile!(tips_default: "already_paid_out", overtime_mode: "total_as_regular_warn_over_80")
    end

    it "treats total-only hours <= 80 as regular without a blocking error and applies cleanly" do
      text = <<~EMAIL
        Pay period: 06/14/2026 - 06/27/2026
        Employee,Total Hours,Week 1 Tips,Week 2 Tips
        Alice Barista,74.50,40.00,35.00
      EMAIL
      preview = PayrollIntake::PreviewService.new(
        pay_period: pay_period, source_type: "spike_email", pasted_text: text, actor: staff
      ).call
      session = preview.fetch(:session)
      row = session.rows.sole

      expect(session.evidence_snapshot.dig("intake_settings", "overtime_mode")).to eq("total_as_regular_warn_over_80")
      expect(row).to have_attributes(
        regular_hours: BigDecimal("74.50"),
        overtime_hours: BigDecimal("0.00"),
        reported_tips: BigDecimal("75.00"),
        tips_paid_out: BigDecimal("75.00"),
        status: "ready"
      )
      expect(row.errors_payload).to be_empty
      expect(row.warnings_payload).to be_empty

      apply = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [ { id: row.id, disposition: "included", employee_id: employee.id } ],
        actor: staff
      ).call
      expect(apply[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee)).to have_attributes(
        hours_worked: BigDecimal("74.50"),
        overtime_hours: BigDecimal("0.00")
      )
    end

    it "warns when total-only hours exceed 80 without a weekly breakdown and applies once acknowledged" do
      text = <<~EMAIL
        Pay period: 06/14/2026 - 06/27/2026
        Employee,Total Hours,Week 1 Tips,Week 2 Tips
        Alice Barista,84.25,40.00,35.00
      EMAIL
      preview = PayrollIntake::PreviewService.new(
        pay_period: pay_period, source_type: "spike_email", pasted_text: text, actor: staff
      ).call
      session = preview.fetch(:session)
      row = session.rows.sole

      expect(row.errors_payload).to be_empty
      expect(row.warnings_payload.pluck("code")).to include("hours_exceed_period_threshold")
      expect(row).to have_attributes(
        regular_hours: BigDecimal("84.25"),
        overtime_hours: BigDecimal("0.00"),
        status: "needs_review"
      )

      apply = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [ { id: row.id, disposition: "included", employee_id: employee.id } ],
        actor: staff,
        acknowledge_warnings: true
      ).call
      expect(apply[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee)).to have_attributes(
        hours_worked: BigDecimal("84.25"),
        overtime_hours: BigDecimal("0.00")
      )
    end
  end

  describe "overtime.mode = source_reports on semimonthly schedule" do
    it "allows semimonthly pay periods with source-reported overtime and applies cleanly" do
      company.update!(pay_frequency: "semimonthly")
      create_profile!(tips_default: "paid_in_check", overtime_mode: "source_reports", workweek_alignment: "warn_if_offset")
      semi_period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 7, 16),
        end_date: Date.new(2026, 7, 31),
        pay_date: Date.new(2026, 8, 5),
        status: "draft"
      )

      result = PayrollIntake::Adapters::SpikeEmail.new(pay_period: semi_period, company: company).normalize(
        detected_period: { start_date: "2026-07-16", end_date: "2026-07-31" },
        extracted_rows: [
          { employee_name: employee.full_name, regular_hours: 80, overtime_hours: 4.5, total_hours: 84.5, total_tips: 50 }
        ]
      )
      row = result.fetch(:rows).sole
      expect(row).to include(regular_hours: 80.0, overtime_hours: 4.5, reported_tips: 50.0, tips_paid_out: 0.0, validation_errors: [])
    end
  end

  describe "overtime.mode = daily_records" do
    it "buckets daily hours by the confirmed legal workweek and splits each week at 40 hours" do
      create_profile!(tips_default: "already_paid_out", overtime_mode: "daily_records")

      result = PayrollIntake::Adapters::SpikeEmail.new(pay_period: pay_period, company: company).normalize(
        detected_period: detected_period,
        extracted_rows: [
          {
            employee_name: employee.full_name,
            total_hours: 83,
            total_tips: 30,
            daily_hours: [
              { date: "2026-06-15", hours: 10 },
              { date: "2026-06-16", hours: 10 },
              { date: "2026-06-17", hours: 10 },
              { date: "2026-06-18", hours: 13 },
              { date: "2026-06-22", hours: 10 },
              { date: "2026-06-23", hours: 10 },
              { date: "2026-06-24", hours: 10 },
              { date: "2026-06-25", hours: 10 }
            ]
          }
        ]
      )
      row = result.fetch(:rows).sole
      expect(row).to include(regular_hours: 80.0, overtime_hours: 3.0, validation_errors: [])
    end
  end
end
