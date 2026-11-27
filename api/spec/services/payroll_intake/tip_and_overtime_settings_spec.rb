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

    it "ignores a persisted manual-hours operating profile with a blank intake_adapter (M4)" do
      options = OperatingProfileCatalog.default_options
      options["tips"]["default"] = "paid_in_check"
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 1, 1),
        ends_on: nil,
        version: 1,
        offering: "payroll_service",
        hours_source: "manual",
        intake_adapter: nil,
        client_portal_enabled: false,
        employee_portal_enabled: false,
        options: options,
        reason: "Manual baseline"
      )

      effective = PayrollIntake::EffectiveSettings.for(company: company, pay_period: pay_period, source_type: "spike_email")
      expect(effective).to have_attributes(
        tips_default: "already_paid_out",
        overtime_mode: "weekly_split",
        workweek_alignment: "aligned",
        source: "adapter_descriptor"
      )
    end
  end

  describe "M1: 29 CFR 778.104 workweek alignment enforcement for computed overtime modes" do
    let(:misaligned_period) do
      # Sunday workweek (starts_on_weekday: 0), pay period Wed Jun 17 – Tue Jun 30, 2026.
      # Legal week Jun 21–27 has 60h (40/40 if split by halves = 0 OT instead of 20 OT).
      create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 6, 17),
        end_date: Date.new(2026, 6, 30),
        pay_date: Date.new(2026, 7, 3),
        status: "draft"
      )
    end

    it "rejects warn_if_offset combined with any computed overtime mode on Company and ClientOperatingProfile" do
      %w[weekly_split daily_records total_as_regular_warn_over_80].each do |computed_mode|
        company.payroll_intake_settings = {
          "spike_email" => { "overtime_mode" => computed_mode, "workweek_alignment" => "warn_if_offset" }
        }
        expect(company).not_to be_valid
        expect(company.errors[:payroll_intake_settings].join).to include("29 CFR 778.104")

        options = OperatingProfileCatalog.default_options
        options["overtime"]["mode"] = computed_mode
        options["workweek"]["alignment"] = "warn_if_offset"
        profile = ClientOperatingProfile.new(
          company: company,
          effective_on: Date.new(2026, 1, 1),
          version: 1,
          offering: "payroll_service",
          hours_source: "intake_adapter",
          intake_adapter: "spike_email",
          client_portal_enabled: false,
          employee_portal_enabled: false,
          options: options
        )
        expect(profile).not_to be_valid
        expect(profile.errors[:options].join).to include("29 CFR 778.104")
      end
    end

    it "refuses a misaligned Wed Jun 17 - Tue Jun 30 period for every computed overtime mode even if warn_if_offset is passed" do
      %w[weekly_split daily_records total_as_regular_warn_over_80].each do |computed_mode|
        evidence = PayrollIntake::WorkweekEvidence.new(
          pay_period: misaligned_period,
          allow_misaligned: true,
          overtime_mode: computed_mode,
          workweek_alignment: "warn_if_offset"
        )
        expect { evidence.capture! }.to raise_error(ArgumentError, /begin on the confirmed legal workweek start day/)
      end

      source_reported = PayrollIntake::WorkweekEvidence.new(
        pay_period: misaligned_period,
        overtime_mode: "source_reports",
        workweek_alignment: "warn_if_offset"
      ).capture!
      expect(source_reported["aligned_with_pay_period"]).to be(false)
      expect(source_reported["legal_week_starts"]).to eq(%w[2026-06-21 2026-06-28])
    end

    it "blocks previewing a misaligned Wed Jun 17 - Tue Jun 30 period with 60h in legal week Jun 21-27 under weekly_split" do
      text = <<~EMAIL
        Pay period: 06/17/2026 - 06/30/2026
        Employee,Week 1 Hours,Week 2 Hours,Week 1 Tips,Week 2 Tips
        Alice Barista,40,40,20.00,20.00
      EMAIL
      expect do
        PayrollIntake::PreviewService.new(
          pay_period: misaligned_period, source_type: "spike_email", pasted_text: text, actor: staff
        ).call
      end.to raise_error(ArgumentError, /begin on the confirmed legal workweek start day/)
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

    it "never honors per-row tips_already_paid from AI-extracted rows (L1)" do
      ai_extractor = instance_double(
        PayrollIntake::AiExtractor,
        call: {
          detected_period: detected_period,
          rows: [
            {
              "employee_name" => employee.full_name,
              "week1_hours" => 40,
              "week2_hours" => 40,
              "total_tips" => 75.00,
              "tips_already_paid" => false,
              "confidence" => 0.95
            }
          ],
          warnings: []
        }
      )
      allow(PayrollIntake::AiExtractor).to receive(:new).and_return(ai_extractor)

      preview = PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "spike_email",
        pasted_text: "unstructured email text requiring AI extraction",
        actor: staff
      ).call

      row = preview.fetch(:session).rows.sole
      expect(row.reported_tips).to eq(BigDecimal("75.00"))
      expect(row.tips_paid_out).to eq(BigDecimal("75.00"))
      expect(row.source_payload).to include(
        "resolved_tip_treatment" => "already_paid_out",
        "tip_treatment_source" => "adapter_descriptor"
      )
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

    it "allows moving overtime up on apply but rejects reducing overtime in warn-over-80 mode (M2)" do
      text = <<~EMAIL
        Pay period: 06/14/2026 - 06/27/2026
        Employee,Total Hours,Week 1 Tips,Week 2 Tips
        Alice Barista,85.00,40.00,35.00
      EMAIL
      session = PayrollIntake::PreviewService.new(
        pay_period: pay_period, source_type: "spike_email", pasted_text: text, actor: staff
      ).call.fetch(:session)
      row = session.rows.sole

      upward = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [
          { id: row.id, disposition: "included", employee_id: employee.id, regular_hours: 80.0, overtime_hours: 5.0 }
        ],
        actor: staff,
        acknowledge_warnings: true
      ).call
      expect(upward[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee)).to have_attributes(
        hours_worked: BigDecimal("80.00"),
        overtime_hours: BigDecimal("5.00")
      )

      # Now supersede the applied session and start with explicit 80 reg / 5 OT to verify reducing OT is rejected.
      session.mark_superseded!(actor: staff)
      session_with_ot = PayrollIntakeSession.create!(
        company: company,
        pay_period: pay_period,
        source_type: "spike_email",
        source_label: "Spike Coffee Roasters email",
        import_hash: SecureRandom.hex(32),
        parser_version: "spike_email:v3",
        package_id: SecureRandom.uuid,
        package_revision: 2,
        package_schema_version: PayrollIntakeSession::PACKAGE_SCHEMA_VERSION,
        status: "previewed",
        evidence_snapshot: {
          "workweek" => PayrollIntake::WorkweekEvidence.new(pay_period: pay_period, overtime_mode: "total_as_regular_warn_over_80").capture!,
          "intake_settings" => { "overtime_mode" => "total_as_regular_warn_over_80" }
        },
        created_by: staff
      )
      ot_row = session_with_ot.rows.create!(
        position: 0,
        source_employee_name: employee.full_name,
        employee: employee,
        regular_hours: 80,
        overtime_hours: 5,
        reported_tips: 20,
        tips_paid_out: 20,
        status: "ready"
      )
      downward = PayrollIntake::ApplyService.new(
        session: session_with_ot,
        row_overrides: [
          { id: ot_row.id, disposition: "included", employee_id: employee.id, regular_hours: 85.0, overtime_hours: 0.0 }
        ],
        actor: staff
      ).call
      expect(downward[:applied]).to be_empty
      expect(downward[:errors].sole.fetch(:error)).to match(/Overtime hours cannot be reduced/)
    end

    it "warns when any single week exceeds 40h via weekly or daily data even if total <= 80h, and documents limits (L2)" do
      weekly_result = PayrollIntake::Adapters::SpikeEmail.new(pay_period: pay_period, company: company).normalize(
        detected_period: detected_period,
        extracted_rows: [
          { employee_name: employee.full_name, week1_hours: 45, week2_hours: 30, total_hours: 75, total_tips: 40 }
        ]
      )
      weekly_row = weekly_result.fetch(:rows).sole
      expect(weekly_row).to include(regular_hours: 70.0, overtime_hours: 5.0)
      expect(weekly_row[:warnings].pluck(:code)).to include("single_week_exceeds_40_hours")

      daily_result = PayrollIntake::Adapters::SpikeEmail.new(pay_period: pay_period, company: company).normalize(
        detected_period: detected_period,
        extracted_rows: [
          {
            employee_name: employee.full_name,
            total_hours: 75,
            total_tips: 40,
            daily_hours: [
              { date: "2026-06-15", hours: 15 },
              { date: "2026-06-16", hours: 15 },
              { date: "2026-06-17", hours: 15 },
              { date: "2026-06-22", hours: 15 },
              { date: "2026-06-23", hours: 15 }
            ]
          }
        ]
      )
      daily_row = daily_result.fetch(:rows).sole
      expect(daily_row[:warnings].pluck(:code)).to include("single_week_exceeds_40_hours")
      expect(OperatingProfileCatalog.find("overtime.mode").effect).to include("total_as_regular_warn_over_80 cannot detect weekly overtime")
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

    it "recomputes daily_hours on apply and rejects overrides that drop legal overtime (M2)" do
      create_profile!(tips_default: "already_paid_out", overtime_mode: "daily_records")
      daily_hours = [
        { "date" => "2026-06-15", "hours" => 15 },
        { "date" => "2026-06-16", "hours" => 15 },
        { "date" => "2026-06-17", "hours" => 15 }
      ]
      session = PayrollIntakeSession.create!(
        company: company,
        pay_period: pay_period,
        source_type: "spike_email",
        source_label: "Spike Coffee Roasters email",
        import_hash: SecureRandom.hex(32),
        parser_version: "spike_email:v3",
        package_id: SecureRandom.uuid,
        package_revision: 1,
        package_schema_version: PayrollIntakeSession::PACKAGE_SCHEMA_VERSION,
        status: "previewed",
        evidence_snapshot: {
          "workweek" => PayrollIntake::WorkweekEvidence.new(pay_period: pay_period, overtime_mode: "daily_records").capture!,
          "intake_settings" => { "overtime_mode" => "daily_records" }
        },
        created_by: staff
      )
      row = session.rows.create!(
        position: 0,
        source_employee_name: employee.full_name,
        employee: employee,
        regular_hours: 40,
        overtime_hours: 5,
        reported_tips: 30,
        tips_paid_out: 30,
        status: "ready",
        source_payload: { "daily_hours" => daily_hours }
      )

      rejected = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [
          { id: row.id, disposition: "included", employee_id: employee.id, regular_hours: 45.0, overtime_hours: 0.0 }
        ],
        actor: staff
      ).call
      expect(rejected[:applied]).to be_empty
      expect(rejected[:errors].sole.fetch(:error)).to match(/legal daily-workweek calculation/)

      applied = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [
          { id: row.id, disposition: "included", employee_id: employee.id, regular_hours: 40.0, overtime_hours: 5.0 }
        ],
        actor: staff
      ).call
      expect(applied[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee)).to have_attributes(
        hours_worked: BigDecimal("40.00"),
        overtime_hours: BigDecimal("5.00")
      )
    end
  end
end
