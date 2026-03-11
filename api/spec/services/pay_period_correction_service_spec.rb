# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriodCorrectionService do
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:actor) do
    User.create!(company: company, email: "actor@correction.com",
                 name: "Correction Actor", role: "admin", active: true)
  end

  let(:employee) do
    create(:employee, company: company, department: department,
           employment_type: "hourly", pay_rate: 20.00)
  end

  let(:committed_period) do
    pp = create(:pay_period, :committed, company: company,
                start_date: Date.new(2024, 1, 1),
                end_date: Date.new(2024, 1, 14),
                pay_date: Date.new(2024, 1, 19))
    # Add a calculated payroll item
    create(:payroll_item,
           pay_period: pp,
           employee: employee,
           gross_pay: 1600.00,
           net_pay: 1300.00,
           withholding_tax: 160.00,
           social_security_tax: 99.20,
           medicare_tax: 23.20,
           employer_social_security_tax: 99.20,
           employer_medicare_tax: 23.20,
           retirement_payment: 0,
           roth_retirement_payment: 0,
           insurance_payment: 0,
           loan_payment: 0,
           reported_tips: 0,
           bonus: 0,
           overtime_hours: 0,
           voided: false)
    pp
  end

  def setup_ytd_totals
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024).tap do |ytd|
      ytd.update!(gross_pay: 1600.00, net_pay: 1300.00,
                  withholding_tax: 160.00, social_security_tax: 99.20,
                  medicare_tax: 23.20)
    end
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024).tap do |ytd|
      ytd.update!(gross_pay: 1600.00, net_pay: 1300.00,
                  withholding_tax: 160.00, social_security_tax: 99.20,
                  medicare_tax: 23.20,
                  employer_social_security: 99.20, employer_medicare: 23.20)
    end
  end

  # ----------------------------------------------------------------
  # void!
  # ----------------------------------------------------------------
  describe ".void!" do
    context "with a valid committed pay period" do
      before { setup_ytd_totals }

      it "marks the pay period as voided" do
        PayPeriodCorrectionService.void!(
          pay_period: committed_period,
          actor:      actor,
          reason:     "Data entry error"
        )

        committed_period.reload
        expect(committed_period.correction_status).to eq("voided")
        expect(committed_period.voided_at).to be_present
        expect(committed_period.voided_by_id).to eq(actor.id)
        expect(committed_period.void_reason).to eq("Data entry error")
      end

      it "returns a PayPeriodCorrectionEvent" do
        event = PayPeriodCorrectionService.void!(
          pay_period: committed_period,
          actor:      actor,
          reason:     "Data entry error"
        )

        expect(event).to be_a(PayPeriodCorrectionEvent)
        expect(event.action_type).to eq("void_initiated")
        expect(event.reason).to eq("Data entry error")
        expect(event.actor_id).to eq(actor.id)
        expect(event.actor_name).to eq(actor.name)
      end

      it "captures financial snapshot on the audit event" do
        event = PayPeriodCorrectionService.void!(
          pay_period: committed_period,
          actor:      actor,
          reason:     "Test"
        )

        expect(event.financial_snapshot["gross_pay"]).to eq(1600.0)
        expect(event.financial_snapshot["employee_count"]).to eq(1)
      end

      it "reverses employee YTD totals" do
        PayPeriodCorrectionService.void!(
          pay_period: committed_period,
          actor:      actor,
          reason:     "Reversal test"
        )

        ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024)
        expect(ytd.gross_pay).to eq(0.0)
        expect(ytd.net_pay).to eq(0.0)
      end

      it "reverses company YTD totals" do
        PayPeriodCorrectionService.void!(
          pay_period: committed_period,
          actor:      actor,
          reason:     "Company YTD test"
        )

        ytd = CompanyYtdTotal.find_by(company_id: company.id, year: 2024)
        expect(ytd.gross_pay).to eq(0.0)
        expect(ytd.employer_social_security).to eq(0.0)
      end

      it "does not reverse voided payroll items" do
        committed_period.payroll_items.first.update!(voided: true)
        # YTD never grows; we're testing it doesn't go negative
        EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
          .update!(gross_pay: 0.0, net_pay: 0.0)

        expect {
          PayPeriodCorrectionService.void!(
            pay_period: committed_period,
            actor:      actor,
            reason:     "Skip voided items test"
          )
        }.not_to raise_error
      end
    end

    context "guard: non-committed period" do
      it "raises InvalidStateError for a draft period" do
        draft = create(:pay_period, company: company, status: "draft")
        expect {
          PayPeriodCorrectionService.void!(pay_period: draft, actor: actor, reason: "test")
        }.to raise_error(PayPeriodCorrectionService::InvalidStateError)
      end

      it "raises InvalidStateError for an approved period" do
        approved = create(:pay_period, :approved, company: company)
        expect {
          PayPeriodCorrectionService.void!(pay_period: approved, actor: actor, reason: "test")
        }.to raise_error(PayPeriodCorrectionService::InvalidStateError)
      end
    end

    context "guard: double-void prevention" do
      before { setup_ytd_totals }

      it "raises AlreadyVoidedError on second void attempt" do
        PayPeriodCorrectionService.void!(
          pay_period: committed_period, actor: actor, reason: "First"
        )
        committed_period.reload

        expect {
          PayPeriodCorrectionService.void!(
            pay_period: committed_period, actor: actor, reason: "Second"
          )
        }.to raise_error(PayPeriodCorrectionService::AlreadyVoidedError)
      end
    end

    context "guard: already superseded" do
      before { setup_ytd_totals }

      it "raises AlreadySupersededError if a correction run already exists" do
        correction_run = create(:pay_period, :correction_run, company: company)
        committed_period.update!(superseded_by_id: correction_run.id)

        expect {
          PayPeriodCorrectionService.void!(
            pay_period: committed_period, actor: actor, reason: "test"
          )
        }.to raise_error(PayPeriodCorrectionService::AlreadySupersededError)
      end
    end

    context "guard: blank reason" do
      it "raises ArgumentError for blank reason" do
        expect {
          PayPeriodCorrectionService.void!(pay_period: committed_period, actor: actor, reason: "")
        }.to raise_error(ArgumentError, /reason is required/)
      end

      it "raises ArgumentError for nil reason" do
        expect {
          PayPeriodCorrectionService.void!(pay_period: committed_period, actor: actor, reason: nil)
        }.to raise_error(ArgumentError, /reason is required/)
      end
    end

    context "when voiding a committed correction run" do
      it "clears source superseded_by_id so another correction run can be created" do
        source = create(:pay_period, :voided, company: company,
                        start_date: Date.new(2024, 1, 1),
                        end_date: Date.new(2024, 1, 14),
                        pay_date: Date.new(2024, 1, 19),
                        status: "committed")
        correction_run = create(:pay_period, :correction_run, company: company,
                                start_date: Date.new(2024, 1, 1),
                                end_date: Date.new(2024, 1, 14),
                                pay_date: Date.new(2024, 1, 26),
                                status: "committed",
                                source_pay_period: source)
        source.update!(superseded_by_id: correction_run.id)

        PayPeriodCorrectionService.void!(
          pay_period: correction_run,
          actor: actor,
          reason: "Correction run had wrong pay date"
        )

        source.reload
        expect(source.superseded_by_id).to be_nil
      end
    end

    context "atomicity" do
      before { setup_ytd_totals }

      it "rolls back all changes if an error occurs mid-void" do
        allow_any_instance_of(EmployeeYtdTotal).to receive(:subtract_payroll_item!).and_raise("Simulated DB error")

        expect {
          PayPeriodCorrectionService.void!(
            pay_period: committed_period, actor: actor, reason: "Atomicity test"
          )
        }.to raise_error("Simulated DB error")

        committed_period.reload
        expect(committed_period.correction_status).to be_nil
        expect(PayPeriodCorrectionEvent.count).to eq(0)
      end
    end
  end

  # ----------------------------------------------------------------
  # create_correction_run!
  # ----------------------------------------------------------------
  describe ".create_correction_run!" do
    let(:voided_period) do
      create(:pay_period, :voided, company: company,
             start_date: Date.new(2024, 1, 1),
             end_date:   Date.new(2024, 1, 14),
             pay_date:   Date.new(2024, 1, 19))
    end

    before do
      create(:payroll_item,
             pay_period: voided_period,
             employee:   employee,
             gross_pay:  1600.00,
             net_pay:    1300.00)
    end

    context "with a valid voided period" do
      it "creates a correction run with status draft" do
        correction_run = PayPeriodCorrectionService.create_correction_run!(
          source_pay_period: voided_period,
          actor:             actor,
          reason:            "Re-running with corrected hours"
        )

        expect(correction_run).to be_persisted
        expect(correction_run.status).to eq("draft")
        expect(correction_run.correction_status).to eq("correction")
        expect(correction_run.source_pay_period_id).to eq(voided_period.id)
      end

      it "links the voided period to the correction run via superseded_by_id" do
        correction_run = PayPeriodCorrectionService.create_correction_run!(
          source_pay_period: voided_period,
          actor:             actor,
          reason:            "Fix hours"
        )

        voided_period.reload
        expect(voided_period.superseded_by_id).to eq(correction_run.id)
      end

      it "inherits dates from source by default" do
        correction_run = PayPeriodCorrectionService.create_correction_run!(
          source_pay_period: voided_period,
          actor:             actor,
          reason:            "Test"
        )

        expect(correction_run.start_date).to eq(voided_period.start_date)
        expect(correction_run.end_date).to eq(voided_period.end_date)
        expect(correction_run.pay_date).to eq(voided_period.pay_date)
      end

      it "accepts overridden dates" do
        new_pay_date = Date.new(2024, 1, 22)
        correction_run = PayPeriodCorrectionService.create_correction_run!(
          source_pay_period: voided_period,
          actor:             actor,
          reason:            "Adjusted pay date",
          new_pay_date:      new_pay_date
        )

        expect(correction_run.pay_date).to eq(new_pay_date)
      end

      it "copies payroll items from source into the correction run" do
        correction_run = PayPeriodCorrectionService.create_correction_run!(
          source_pay_period: voided_period,
          actor:             actor,
          reason:            "Copy test"
        )

        expect(correction_run.payroll_items.count).to eq(voided_period.payroll_items.count)
        expect(correction_run.payroll_items.first.employee_id).to eq(employee.id)
      end

      it "creates a correction_run_created audit event" do
        correction_run = PayPeriodCorrectionService.create_correction_run!(
          source_pay_period: voided_period,
          actor:             actor,
          reason:            "Audit event test"
        )

        event = PayPeriodCorrectionEvent.last
        expect(event.action_type).to eq("correction_run_created")
        expect(event.pay_period_id).to eq(voided_period.id)
        expect(event.resulting_pay_period_id).to eq(correction_run.id)
      end
    end

    context "guard: source not voided" do
      it "raises NotVoidedError for a committed non-voided period" do
        expect {
          PayPeriodCorrectionService.create_correction_run!(
            source_pay_period: committed_period,
            actor:             actor,
            reason:            "Test"
          )
        }.to raise_error(PayPeriodCorrectionService::NotVoidedError)
      end
    end

    context "guard: already superseded" do
      it "raises AlreadySupersededError when a correction run already exists" do
        existing = create(:pay_period, :correction_run, company: company)
        voided_period.update!(superseded_by_id: existing.id)

        expect {
          PayPeriodCorrectionService.create_correction_run!(
            source_pay_period: voided_period,
            actor:             actor,
            reason:            "Second attempt"
          )
        }.to raise_error(PayPeriodCorrectionService::AlreadySupersededError)
      end
    end

    context "guard: blank reason" do
      it "raises ArgumentError for blank reason" do
        expect {
          PayPeriodCorrectionService.create_correction_run!(
            source_pay_period: voided_period, actor: actor, reason: ""
          )
        }.to raise_error(ArgumentError, /reason is required/)
      end
    end
  end

  # ----------------------------------------------------------------
  # audit_trail
  # ----------------------------------------------------------------
  describe ".record_correction_committed!" do
    it "raises when correction run is missing source linkage" do
      orphan_correction = create(:pay_period, :correction_run, company: company,
                                 status: "committed", source_pay_period_id: nil)

      expect {
        PayPeriodCorrectionService.record_correction_committed!(
          pay_period: orphan_correction,
          actor: actor
        )
      }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /missing source pay period linkage/)
    end
  end

  describe ".audit_trail" do
    before { setup_ytd_totals }

    it "returns correction events for the pay period" do
      PayPeriodCorrectionService.void!(
        pay_period: committed_period,
        actor:      actor,
        reason:     "Audit trail test"
      )

      trail = PayPeriodCorrectionService.audit_trail(committed_period)
      expect(trail.count).to eq(1)
      expect(trail.first.action_type).to eq("void_initiated")
    end

    it "includes correction-run void event in source period trail" do
      source = create(:pay_period, :voided, company: company,
                      start_date: Date.new(2024, 1, 1),
                      end_date: Date.new(2024, 1, 14),
                      pay_date: Date.new(2024, 1, 19),
                      status: "committed")
      correction_run = create(:pay_period, :correction_run, company: company,
                              start_date: Date.new(2024, 1, 1),
                              end_date: Date.new(2024, 1, 14),
                              pay_date: Date.new(2024, 1, 26),
                              status: "committed",
                              source_pay_period: source)
      source.update!(superseded_by_id: correction_run.id)
      create(:payroll_item, pay_period: correction_run, employee: employee,
             gross_pay: 100.0, net_pay: 80.0, voided: false)

      PayPeriodCorrectionService.void!(
        pay_period: correction_run,
        actor: actor,
        reason: "Void incorrect correction run"
      )

      trail = PayPeriodCorrectionService.audit_trail(source)
      void_event = trail.find { |e| e.action_type == "void_initiated" }
      expect(void_event).to be_present
      expect(void_event.pay_period_id).to eq(source.id)
      expect(void_event.resulting_pay_period_id).to eq(correction_run.id)
    end

    it "includes events where the period is the resulting period" do
      # Create a standalone event where committed_period is the result
      other_period = create(:pay_period, :voided, company: company)
      PayPeriodCorrectionEvent.create!(
        action_type:            "correction_run_created",
        pay_period:             other_period,
        resulting_pay_period:   committed_period,
        company_id:             company.id,
        reason:                 "Cross-link test",
        actor_name:             actor.name,
        financial_snapshot:     {}
      )

      trail = PayPeriodCorrectionService.audit_trail(committed_period)
      expect(trail.map(&:action_type)).to include("correction_run_created")
    end

    it "orders events chronologically" do
      PayPeriodCorrectionService.void!(
        pay_period: committed_period,
        actor:      actor,
        reason:     "First event"
      )
      # Add a second event manually
      PayPeriodCorrectionEvent.create!(
        action_type: "correction_run_committed",
        pay_period:  committed_period,
        company_id:  company.id,
        reason:      "Second event",
        actor_name:  actor.name,
        financial_snapshot: {}
      )

      trail = PayPeriodCorrectionService.audit_trail(committed_period)
      times = trail.map(&:created_at)
      expect(times).to eq(times.sort)
    end
  end
end
