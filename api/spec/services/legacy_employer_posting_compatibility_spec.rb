# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reviewed pre-deploy employer postings" do
  include_context "corrective payroll ledger fixtures"

  def old_posting!(item, field_category: nil)
    posting = period.payroll_liability_postings.create!(company: company, posting_type: "commit", liability_date: period.pay_date,
      posted_at: Time.current, idempotency_key: "old:#{period.id}", component_rule_snapshot: {}, metadata: {})
    PayrollLiabilityPostingService::CORE_COMPONENTS.each do |key, (attribute, category, authority)|
      amount = item.public_send(attribute).to_d
      next if amount.zero?

      posting.entries.create!(company: company, payroll_item: item, component_key: key, category: category,
        authority: authority, amount: amount, metadata: { "source_field" => attribute.to_s })
    end
    if field_category == "insurance"
      field = item.payroll_item_field_entries.sole
      entry = posting.entries.build(company: company, payroll_item: item, component_key: "payroll_field:#{field.payroll_field_definition_id}:#{field.id}",
        category: "insurance_employer", authority: "Benefit provider", amount: field.amount,
        metadata: { "payroll_item_field_entry_id" => field.id })
      entry.save!(validate: false) # The old builder used insert_all! for this unlisted category.
    end
    posting
  end

  %w[insurance other].each do |category|
    it "corrects an old #{category} employer field without rewriting history" do
      field = create(:payroll_field_definition, company: company, name: "Historical employer source", kind: "employer_contribution",
        tax_treatment: "employer_contribution", category: category, amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      item = original!(post_liabilities: false)
      item.update_columns(calculation_context_snapshot: item.calculation_context_snapshot.except("built_in_employer_match_mirrors"))
      item.payroll_item_field_entries.each { |row| row.update_columns(metadata: row.metadata.except("deduction_mirror")) }
      item.payroll_item_deductions.sole.deduction_type.update!(name: field.name)
      item.reload
      source = old_posting!(item, field_category: category)
      frozen = [ freeze_history(item), source.attributes, source.entries.order(:id).map(&:attributes) ]
      reviewed = preview(hours_worked: 65)
      omissions = reviewed.dig(:meta, :legacy_unposted_employer_component)
      expect(omissions.sum { |row| row.fetch("amount").to_d }).to eq(category == "other" ? 45 : 0)
      correction = issue({ hours_worked: 65 }, digest: reviewed.dig(:meta, :review_digest))
      evidence = reviewed.dig(:meta, :legacy_employer_posting_compatibility)
      expect(evidence.sole).to include("payroll_item_id" => item.id, "source_posting_ids" => [ source.id ])
      expect(evidence.sole.fetch("evidence_digest")).to match(/\A[0-9a-f]{64}\z/)
      expect(correction.calculation_context_snapshot.dig("corrective_paycheck", "legacy_employer_posting_compatibility")).to eq(evidence)
      expect(correction.pay_period.payroll_liability_postings.sole.metadata["legacy_employer_posting_compatibility"]).to eq(evidence)
      expect(PayrollLiabilityEntry.where(payroll_item_id: correction.id, category: category == "other" ? "other_payroll_liability" : "benefit_employer").sum(:amount)).to eq(3.75)
      if category == "other"
        expect(correction.calculation_context_snapshot.dig("corrective_paycheck", "legacy_unposted_employer_component")).to eq(omissions)
        expect(AuditLog.where(action: "payroll#corrective_paycheck_issued", record_id: correction.id).sole.metadata["legacy_unposted_employer_component"]).to eq(omissions)
      end
      issue(hours_worked: 55)
      expect([ freeze_history(item.reload), source.reload.attributes, source.entries.order(:id).map(&:attributes) ]).to eq(frozen)
      replacement = PayrollLiabilityPostingService.restate_for_pay_date!(pay_period: period, actor: actor,
        old_pay_date: period.pay_date, new_pay_date: period.pay_date + 1.day)
      money = ->(posting) { posting.entries.order(:component_key).map { |entry| entry.attributes.slice("component_key", "category", "amount") } }
      expect(money.call(replacement)).to eq(money.call(source))
    end
  end

  [ false, true ].each do |aggregate|
    it "records the old direct insurance omission, aggregate=#{aggregate}" do
      add_deduction(category: "employer_contribution", sub_category: "insurance")
      item = original!(post_liabilities: false) do |built|
        built.calculation_context_snapshot = built.calculation_context_snapshot.except("built_in_employer_match_mirrors")
        built.insurance_payment = 45 if aggregate
      end
      source = old_posting!(item)
      reviewed = preview(hours_worked: 65)
      omissions = reviewed.dig(:meta, :legacy_unposted_employer_component)
      expect(omissions.sole).to include("amount" => "45.0", "payroll_item_id" => item.id)
      correction = issue({ hours_worked: 65 }, digest: reviewed.dig(:meta, :review_digest))
      expect(correction.insurance_payment).to eq(0)
      expect(correction.pay_period.payroll_liability_postings.sole.entries.where(category: "benefit_employer").sum(:amount)).to eq(3.75)
      expect(source.reload.entries.where(category: "insurance_employee").sum(:amount)).to eq(aggregate ? 45 : 0)
    end
  end

  it "holds missing new-rule obligations even if a posting version marker is removed" do
    add_deduction(category: "employer_contribution", sub_category: "insurance")
    item = original!
    PayrollLiabilityEntry.where(payroll_item_id: item.id, category: "benefit_employer").delete_all
    item.pay_period.payroll_liability_postings.update_all(metadata: {})
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /employer contribution.*reconcile/i)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "holds a missing obligation that the old benefit rules should have posted" do
    add_deduction(category: "employer_contribution", sub_category: "benefit")
    item = original!(post_liabilities: false) do |built|
      built.calculation_context_snapshot = built.calculation_context_snapshot.except("built_in_employer_match_mirrors")
    end
    old_posting!(item)
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /employer contribution.*reconcile/i)
  end

  it "binds the reviewed omission to retained posting evidence" do
    add_deduction(category: "employer_contribution", sub_category: "insurance")
    item = original!(post_liabilities: false) do |built|
      built.calculation_context_snapshot = built.calculation_context_snapshot.except("built_in_employer_match_mirrors")
    end
    posting = old_posting!(item)
    digest = preview(hours_worked: 65).dig(:meta, :review_digest)
    posting.entries.where(category: "medicare_employer").update_all(updated_at: 1.minute.from_now)
    expect { issue({ hours_worked: 65 }, digest: digest) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "rejects an unexplained old posting instead of converting it into an omission" do
    add_deduction(category: "employer_contribution", sub_category: "insurance")
    item = original!(post_liabilities: false) do |built|
      built.calculation_context_snapshot = built.calculation_context_snapshot.except("built_in_employer_match_mirrors")
    end
    posting = old_posting!(item)
    posting.entries.create!(company: company, payroll_item: item, component_key: "deduction_type:unknown-source", category: "other_payroll_liability",
      authority: "Unknown employer source", amount: 45, metadata: {})
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /retained legacy posting rules/)
  end
end
