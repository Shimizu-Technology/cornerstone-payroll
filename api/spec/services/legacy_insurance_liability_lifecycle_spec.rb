# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legacy insurance liability lifecycle" do
  include_context "corrective payroll ledger fixtures"

  def legacy_item!(kind)
    add_deduction(category: "employer_contribution", sub_category: "insurance") if kind == :employer_aggregate
    item = original!(post_liabilities: false, track_ytd: false)
    if kind == :built_in_match
      type = company.deduction_types.create!(name: "401(k) Employer Match", category: "employer_contribution",
        sub_category: "retirement", reporting_group: "401k_pre_tax")
      item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: type.category,
        reporting_group: type.reporting_group, amount: 30)
      item.update_columns(employer_retirement_match: 30)
    elsif kind == :field_aggregate
      definition = create(:payroll_field_definition, company: company, name: "Legacy health", kind: "deduction",
        tax_treatment: "post_tax_deduction", category: "insurance", amount_type: "fixed", default_amount: 45)
      item.payroll_item_field_entries.create!(payroll_field_definition: definition, label: definition.name,
        kind: "deduction", tax_treatment: "post_tax_deduction", category: "insurance", amount: 45,
        employee_paid: true, source: "manual")
      item.update_columns(insurance_payment: 17, total_deductions: item.total_deductions + 62, net_pay: item.net_pay - 62)
    else
      item.update_columns(insurance_payment: 45)
    end
    employee.ytd_totals_for(ledger_tax_year).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company: company, year: ledger_tax_year).add_payroll_item!(item)
    item.reload
  end

  def legacy_entry_values(item)
    values = PayrollLiabilityPostingService::CORE_COMPONENTS.filter_map do |key, (field, category, authority)|
      amount = item.public_send(field).to_d
      amount -= item.additional_medicare_tax.to_d if key == "medicare_employee"
      next if amount.zero?

      { component_key: key, category: category, authority: authority, amount: amount }
    end
    item.payroll_item_field_entries.each do |field|
      values << { component_key: "payroll_field:#{field.payroll_field_definition_id}:#{field.id}", category: "insurance_employee",
        authority: PayrollLiabilityPostingService::BENEFIT_PROVIDER, amount: field.amount }
    end
    values
  end

  def seed_source!(item, values)
    posting = period.payroll_liability_postings.create!(company: company, posting_type: "commit", liability_date: period.pay_date,
      posted_at: Time.current, posted_by: actor, idempotency_key: "legacy-fixture:#{period.id}", component_rule_snapshot: {}, metadata: { "legacy_fixture" => true })
    values.each { |value| posting.entries.create!(value.merge(company: company, payroll_item: item, metadata: {})) }
    posting
  end

  [ :employer_aggregate, :field_aggregate, :built_in_match ].product([ false, true ], [ :void, :restate ]).each do |kind, existing, operation|
    it "preserves #{kind} history during #{operation}, existing posting=#{existing}" do
      item = legacy_item!(kind)
      values = legacy_entry_values(item)
      source = seed_source!(item, values) if existing
      frozen_source = source && [ source.attributes, source.entries.order(:id).map(&:attributes) ]
      frozen_components = freeze_history(item)[1..]
      money = item.attributes.slice("gross_pay", "net_pay", "total_deductions", *PayrollLiabilityPostingService::CORE_COMPONENTS.values.map(&:first).map(&:to_s))
      expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
      expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
      expect(period.supplemental_pay_periods).to be_empty

      if operation == :void
        allow_any_instance_of(PayrollLiabilityPostingService).to receive(:build_entries).and_raise("Recomputed existing source") if existing
        PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Void legacy payroll")
        expect(period.reload).to be_voided
      else
        PayPeriodPayDateCorrectionService.call(pay_period: period, actor: actor, new_pay_date: ledger_correction_date, reason: "Correct legacy date")
        expect(period.reload.pay_date).to eq(ledger_correction_date)
      end

      source ||= period.payroll_liability_postings.find_by!(posting_type: "historical_backfill")
      reversal = source.reload.reversal_posting
      expected = values.to_h { |value| [ value[:component_key], value[:amount] ] }
      expect(source.entries.to_h { |entry| [ entry.component_key, entry.amount ] }).to eq(expected)
      expect(reversal.entries.to_h { |entry| [ entry.component_key, entry.amount ] }).to eq(expected.transform_values { |amount| -amount })
      flag = kind == :built_in_match ? "ambiguous_employer_contribution_history" : "ambiguous_insurance_history"
      expect(reversal.metadata).to include(flag => true)
      expect(source.metadata).to include(flag => true) unless existing
      if operation == :void
        expect(period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
      else
        replacement = period.payroll_liability_postings.find_by!(posting_type: "replacement")
        expect(replacement.entries.to_h { |entry| [ entry.component_key, entry.amount ] }).to eq(expected)
        expect(replacement.metadata).to include(flag => true)
      end
      expect([ source.reload.attributes, source.entries.order(:id).map(&:attributes) ]).to eq(frozen_source) if existing
      expect(item.reload.attributes.slice(*money.keys)).to eq(money)
      expect(freeze_history(item)[1..]).to eq(frozen_components)
    end
  end
end
