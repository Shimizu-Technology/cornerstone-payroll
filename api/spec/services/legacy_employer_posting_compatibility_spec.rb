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

  def uncaptured_legacy_item!(kind)
    if kind == :insurance
      add_deduction(category: "employer_contribution", sub_category: "insurance")
      item = original!(post_liabilities: false) { |built| built.insurance_payment = 45 }
    else
      field = create(:payroll_field_definition, company: company, name: "Uncaptured employer benefit", kind: "employer_contribution",
        tax_treatment: "employer_contribution", category: "benefit", amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      item = original!(post_liabilities: false)
      item.payroll_item_deductions.sole.deduction_type.update!(name: field.name)
      item.payroll_item_field_entries.each { |row| row.update_columns(metadata: row.metadata.except("deduction_mirror")) }
    end
    item.update_columns(calculation_context_snapshot: item.calculation_context_snapshot.except("built_in_employer_match_mirrors"))
    item.reload
  end

  [ :insurance, :employer ].product([ :preview, :issue ]).each do |kind, action|
    it "holds #{action} after an ambiguous #{kind} legacy restatement capture" do
      item = uncaptured_legacy_item!(kind)
      frozen = freeze_history(item)
      PayPeriodPayDateCorrectionService.call(pay_period: period, actor: actor,
        new_pay_date: ledger_correction_date, reason: "Restate retained legacy payroll")
      flag = kind == :insurance ? "ambiguous_insurance_history" : "ambiguous_employer_contribution_history"
      expect(period.payroll_liability_postings.find_by!(posting_type: "historical_backfill").metadata).to include(flag => true)
      before = [ PayPeriod.count, PayrollItem.count, PayrollLiabilityPosting.count, AuditLog.count, employee.ytd_totals_for(2024).reload.attributes ]
      expect { public_send(action, hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
      expect(PayrollLegacyEmployerComponents.eligible?(item)).to be(false)
      expect([ PayPeriod.count, PayrollItem.count, PayrollLiabilityPosting.count, AuditLog.count, employee.ytd_totals_for(2024).reload.attributes ]).to eq(before)
      expect(freeze_history(item.reload)[1..]).to eq(frozen[1..])
    end
  end

  [ :insurance, :employer ].each do |kind|
    it "keeps ambiguous #{kind} legacy voids available without certifying their capture" do
      item = uncaptured_legacy_item!(kind)
      PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Void retained legacy payroll")
      expect(period.reload).to be_voided
      expect(PayrollLegacyEmployerComponents.eligible?(item)).to be(false)
      expect(period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
      expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
    end
  end

  %w[legacy_capture lifecycle_legacy_capture].each do |marker|
    it "does not certify a retained posting with the #{marker} lifecycle marker" do
      item = uncaptured_legacy_item!(:insurance)
      old_posting!(item)
      period.payroll_liability_postings.update_all(metadata: { marker => true })
      expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
      expect(PayrollLegacyEmployerComponents.eligible?(item)).to be(false)
    end
  end

  it "checks a new ambiguity marker even when the item's posting association was already loaded" do
    item = uncaptured_legacy_item!(:insurance)
    old_posting!(item)
    item.pay_period.payroll_liability_postings.load
    expect(PayrollLegacyEmployerComponents.eligible?(item)).to be(true)
    period.payroll_liability_postings.create!(company: company, posting_type: "historical_backfill", liability_date: period.pay_date,
      posted_at: Time.current, idempotency_key: "new-capture:#{period.id}", component_rule_snapshot: {},
      metadata: { "ambiguous_insurance_history" => true })
    expect(PayrollLegacyEmployerComponents.eligible?(item)).to be(false)
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

  [ false, true ].each do |legacy|
    it "holds a foreign-company field mirror, legacy=#{legacy}" do
      definition = create(:payroll_field_definition, company: company, name: "Owned employer source", kind: "employer_contribution",
        tax_treatment: "employer_contribution", category: "insurance", amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: definition)
      item = original!(post_liabilities: false)
      row = item.payroll_item_deductions.sole
      foreign = DeductionType.create!(company: create(:company), name: row.deduction_type.name, category: row.category,
        sub_category: "insurance", reporting_group: row.reporting_group)
      row.update!(deduction_type: foreign)
      field = item.payroll_item_field_entries.sole
      if legacy
        foreign.update!(name: field.label)
        field.update_columns(metadata: field.metadata.except("deduction_mirror"))
        item.update_columns(calculation_context_snapshot: item.calculation_context_snapshot.except("built_in_employer_match_mirrors"))
        old_posting!(item.reload, field_category: "insurance")
      else
        PayrollComponentMirrors.record!(field, row)
        field.save!
      end
      frozen = freeze_history(item.reload)
      expect { PayrollEmployerContributions.total(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError, /mirror identity.*review/)
      expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /mirror identity.*review/)
      expect(period.supplemental_pay_periods).to be_empty
      expect(freeze_history(item.reload)).to eq(frozen)
    end
  end

  [ false, true ].each do |legacy|
    it "holds an impossible foreign-company built-in match mirror, legacy=#{legacy}" do
      item = original!(post_liabilities: false, track_ytd: false)
      type = DeductionType.create!(company: create(:company), name: "401(k) Employer Match", category: "employer_contribution",
        sub_category: "retirement", reporting_group: "401k_pre_tax")
      item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: type.category, amount: 45, reporting_group: type.reporting_group)
      context = item.calculation_context_snapshot.deep_dup
      if legacy
        context.delete("built_in_employer_match_mirrors")
      else
        context["built_in_employer_match_mirrors"] = { "version" => 1, "sources" => { "employer_retirement_match" => type.id } }
      end
      item.update_columns(employer_retirement_match: 45, calculation_context_snapshot: context)
      old_posting!(item.reload) if legacy
      expect { PayrollEmployerContributions.total(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError, /built-in.*review/)
    end
  end
end
