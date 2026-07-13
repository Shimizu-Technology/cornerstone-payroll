# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollLiabilityPostingService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:pay_period) do
    create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 6, 29),
      end_date: Date.new(2026, 7, 12),
      pay_date: Date.new(2026, 7, 15))
  end
  let!(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      gross_pay: 2_000,
      net_pay: 1_500,
      withholding_tax: 150,
      additional_withholding: 25,
      social_security_tax: 124,
      employer_social_security_tax: 124,
      # The stored employee Medicare amount includes the $5 Additional Medicare
      # tax, matching the calculator's persisted representation.
      medicare_tax: 34,
      employer_medicare_tax: 29,
      additional_medicare_tax: 5,
      retirement_payment: 40,
      roth_retirement_payment: 20,
      employer_retirement_match: 30,
      employer_roth_retirement_match: 10,
      insurance_payment: 15)
  end

  describe ".post!" do
    it "posts stored payroll values without invoking a calculator" do
      allow(PayrollCalculator).to receive(:for).and_call_original

      posting = described_class.post!(pay_period: pay_period, actor: actor)

      expect(PayrollCalculator).not_to have_received(:for)
      expect(posting).to have_attributes(
        company_id: company.id,
        pay_period_id: pay_period.id,
        posting_type: "commit",
        liability_date: Date.new(2026, 7, 15),
        posted_by_id: actor.id,
        idempotency_key: "pay-period:#{pay_period.id}:commit"
      )
      expect(posting.entries.sum(:amount)).to eq(601.00)
      expect(posting.entries.find_by!(component_key: "guam_income_tax_withheld").amount).to eq(150.00)
      expect(posting.entries.find_by!(component_key: "guam_additional_income_tax_withheld").amount).to eq(25.00)
      expect(posting.entries.find_by!(component_key: "social_security_employer").amount).to eq(124.00)
      expect(posting.entries.find_by!(component_key: "medicare_employee").amount).to eq(29.00)
      expect(posting.entries.find_by!(component_key: "additional_medicare_employee").amount).to eq(5.00)
      expect(posting.entries.where(authority: described_class::US_TREASURY).sum(:amount)).to eq(311.00)
      expect(posting.component_rule_snapshot).to include(
        "schema_version" => 1,
        "effective_on" => "2026-07-15"
      )
    end

    it "is idempotent" do
      first = described_class.post!(pay_period: pay_period, actor: actor)
      second = described_class.post!(pay_period: pay_period, actor: actor)

      expect(second.id).to eq(first.id)
      expect(PayrollLiabilityPosting.where(pay_period: pay_period).count).to eq(1)
      expect(PayrollLiabilityEntry.where(payroll_liability_posting: first).count).to eq(12)
    end

    it "allows a committed payroll with no non-zero liabilities" do
      payroll_item.update!(
        withholding_tax: 0,
        additional_withholding: 0,
        social_security_tax: 0,
        employer_social_security_tax: 0,
        medicare_tax: 0,
        employer_medicare_tax: 0,
        additional_medicare_tax: 0,
        retirement_payment: 0,
        roth_retirement_payment: 0,
        employer_retirement_match: 0,
        employer_roth_retirement_match: 0,
        insurance_payment: 0
      )

      posting = described_class.post!(pay_period: pay_period, actor: actor)

      expect(posting.entries).to be_empty
    end

    it "preserves signed tax credits from a corrective paycheck" do
      original_period = create(:pay_period, :committed, company: company,
        start_date: Date.new(2026, 6, 15),
        end_date: Date.new(2026, 6, 28),
        pay_date: Date.new(2026, 7, 1))
      original_item = create(:payroll_item,
        pay_period: original_period,
        employee: employee,
        company: company)
      payroll_item.update!(
        correction_for_payroll_item: original_item,
        withholding_tax: -150,
        additional_withholding: -25,
        social_security_tax: -124,
        employer_social_security_tax: -124,
        medicare_tax: -34,
        employer_medicare_tax: -29,
        additional_medicare_tax: -5,
        retirement_payment: 0,
        roth_retirement_payment: 0,
        employer_retirement_match: 0,
        employer_roth_retirement_match: 0,
        insurance_payment: 0
      )

      posting = described_class.post!(pay_period: pay_period, actor: actor)

      expect(posting.entries.find_by!(component_key: "guam_income_tax_withheld").amount).to eq(-150.00)
      expect(posting.entries.find_by!(component_key: "guam_additional_income_tax_withheld").amount).to eq(-25.00)
      expect(posting.entries.find_by!(component_key: "medicare_employee").amount).to eq(-29.00)
      expect(posting.entries.find_by!(component_key: "additional_medicare_employee").amount).to eq(-5.00)
      expect(posting.entries.where(authority: described_class::GUAM_DRT).sum(:amount)).to eq(-175.00)
      expect(posting.entries.where(authority: described_class::US_TREASURY).sum(:amount)).to eq(-311.00)
    end

    it "rejects non-committed and voided periods" do
      pay_period.update!(status: "approved")
      expect {
        described_class.post!(pay_period: pay_period, actor: actor)
      }.to raise_error(described_class::InvalidStateError, /committed/)

      pay_period.update!(status: "committed", correction_status: "voided")
      expect {
        described_class.post!(pay_period: pay_period, actor: actor)
      }.to raise_error(described_class::InvalidStateError, /voided/)
    end

    it "posts classified custom payroll-field liabilities with the configured payee" do
      definition = PayrollFieldDefinition.create!(
        company: company,
        name: "Child Support Order",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "child_support",
        amount_type: "fixed",
        default_amount: 75,
        payee_name: "Guam Child Support Enforcement Division"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: definition,
        label: definition.name,
        kind: definition.kind,
        tax_treatment: definition.tax_treatment,
        category: definition.category,
        amount: 75,
        source: "manual",
        employee_paid: true,
        employer_paid: false
      )

      posting = described_class.post!(pay_period: pay_period, actor: actor)
      entry = posting.entries.find_by!(component_key: "payroll_field:#{definition.id}:#{payroll_item.payroll_item_field_entries.last.id}")

      expect(entry).to have_attributes(
        category: "child_support",
        authority: "Guam Child Support Enforcement Division",
        amount: 75.00
      )
    end
  end

  describe ".reverse!" do
    it "creates one immutable reversing posting and is idempotent" do
      source = described_class.post!(pay_period: pay_period, actor: actor)

      first = described_class.reverse!(
        pay_period: pay_period,
        actor: actor,
        reason: "Payroll was voided",
        idempotency_key: "pay-period:#{pay_period.id}:void"
      ).first
      second = described_class.reverse!(
        pay_period: pay_period,
        actor: actor,
        reason: "Payroll was voided",
        idempotency_key: "pay-period:#{pay_period.id}:void"
      ).first

      expect(first.id).to eq(second.id)
      expect(first).to have_attributes(posting_type: "reversal", source_posting_id: source.id)
      expect(first.entries.sum(:amount)).to eq(-source.entries.sum(:amount))
      expect(PayrollLiabilityEntry.where(payroll_liability_posting_id: [ source.id, first.id ]).sum(:amount)).to eq(0)
    end

    it "captures a legacy committed payroll before reversing it" do
      reversals = described_class.reverse!(pay_period: pay_period, actor: actor, reason: "Legacy void")

      capture = pay_period.payroll_liability_postings.find_by!(posting_type: "historical_backfill")
      expect(reversals.first.source_posting_id).to eq(capture.id)
      expect(pay_period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
    end
  end

  describe ".restate_for_pay_date!" do
    it "reverses the old-date posting and replaces it on the corrected date" do
      source = described_class.post!(pay_period: pay_period, actor: actor)
      new_date = Date.new(2026, 7, 31)
      pay_period.update!(pay_date: new_date)

      replacement = described_class.restate_for_pay_date!(
        pay_period: pay_period,
        actor: actor,
        reason: "Correct clerical date",
        old_pay_date: Date.new(2026, 7, 15),
        new_pay_date: new_date
      )

      expect(source.reload.reversal_posting).to be_present
      expect(replacement).to have_attributes(posting_type: "replacement", liability_date: new_date)
      old_date_net = pay_period.payroll_liability_postings.where(liability_date: Date.new(2026, 7, 15)).joins(:entries).sum("payroll_liability_entries.amount")
      new_date_net = pay_period.payroll_liability_postings.where(liability_date: new_date).joins(:entries).sum("payroll_liability_entries.amount")
      expect(old_date_net).to eq(0)
      expect(new_date_net).to eq(601.00)
    end
  end
end
