# frozen_string_literal: true

require "set"

# Creates immutable liability journal postings from values already stored on
# committed payroll items. It never invokes a calculator and never changes a
# payroll item's financial values.
class PayrollLiabilityPostingService
  class Error < StandardError; end
  class InvalidStateError < Error; end

  GUAM_DRT = "Guam Department of Revenue and Taxation"
  US_TREASURY = "United States Treasury"
  RETIREMENT_ADMINISTRATOR = "Retirement plan administrator"
  BENEFIT_PROVIDER = "Benefit provider"

  CORE_COMPONENTS = {
    "guam_income_tax_withheld" => [ :withholding_tax, "guam_income_tax_withheld", GUAM_DRT ],
    "guam_additional_income_tax_withheld" => [ :additional_withholding, "guam_income_tax_withheld", GUAM_DRT ],
    "social_security_employee" => [ :social_security_tax, "social_security_employee", US_TREASURY ],
    "social_security_employer" => [ :employer_social_security_tax, "social_security_employer", US_TREASURY ],
    "medicare_employee" => [ :medicare_tax, "medicare_employee", US_TREASURY ],
    "medicare_employer" => [ :employer_medicare_tax, "medicare_employer", US_TREASURY ],
    "additional_medicare_employee" => [ :additional_medicare_tax, "additional_medicare_employee", US_TREASURY ],
    "retirement_employee" => [ :retirement_payment, "retirement_employee", RETIREMENT_ADMINISTRATOR ],
    "roth_retirement_employee" => [ :roth_retirement_payment, "roth_retirement_employee", RETIREMENT_ADMINISTRATOR ],
    "retirement_employer" => [ :employer_retirement_match, "retirement_employer", RETIREMENT_ADMINISTRATOR ],
    "roth_retirement_employer" => [ :employer_roth_retirement_match, "roth_retirement_employer", RETIREMENT_ADMINISTRATOR ],
    "insurance_employee" => [ :insurance_payment, "insurance_employee", BENEFIT_PROVIDER ]
  }.freeze

  FIELD_CATEGORY_MAP = {
    "retirement" => [ "retirement_employee", RETIREMENT_ADMINISTRATOR ],
    "insurance" => [ "insurance_employee", BENEFIT_PROVIDER ],
    "benefit" => [ "benefit_employee", BENEFIT_PROVIDER ],
    "garnishment" => [ "garnishment", "Garnishment payee" ],
    "child_support" => [ "child_support", "Child support agency" ]
  }.freeze

  def self.post!(...)
    new(...).post!
  end

  def self.reverse!(...)
    new(...).reverse!
  end

  def self.restate_for_pay_date!(pay_period:, old_pay_date:, new_pay_date:, **options)
    new(pay_period: pay_period, **options).restate_for_pay_date!(
      old_pay_date: old_pay_date,
      new_pay_date: new_pay_date
    )
  end

  def initialize(pay_period:, actor: nil, posting_type: "commit", idempotency_key: nil,
                 liability_date: nil, reason: nil, metadata: {})
    @pay_period = pay_period
    @actor = actor
    @posting_type = posting_type
    @idempotency_key = idempotency_key
    @liability_date = liability_date
    @reason = reason
    @metadata = metadata
  end

  def post!
    PayPeriod.transaction do
      locked = PayPeriod.lock("FOR UPDATE").find(pay_period.id)
      validate_postable!(locked)

      key = idempotency_key.presence || "pay-period:#{locked.id}:commit"
      existing = PayrollLiabilityPosting.find_by(idempotency_key: key)
      return existing if existing

      create_posting!(
        locked,
        posting_type: posting_type,
        key: key,
        liability_date: liability_date || locked.pay_date,
        reason: reason,
        metadata: metadata
      )
    end
  end

  def reverse!
    PayPeriod.transaction do
      locked = PayPeriod.lock("FOR UPDATE").find(pay_period.id)
      ensure_committed!(locked)

      sources = open_source_postings(locked)
      base_key = idempotency_key.presence || "pay-period:#{locked.id}:void"
      existing_reversals = locked.payroll_liability_postings.reversals
        .where("idempotency_key LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(base_key)}:source:%")
        .chronological
        .to_a
      return existing_reversals if sources.empty? && existing_reversals.any?

      if sources.empty?
        sources = [ create_posting!(
          locked,
          posting_type: "historical_backfill",
          key: "pay-period:#{locked.id}:historical-before-reversal",
          liability_date: locked.pay_date,
          reason: "Captured legacy committed payroll before reversal",
          metadata: { "legacy_capture" => true }
        ) ]
      end

      sources.map do |source|
        create_reversal!(
          locked,
          source: source,
          key: "#{base_key}:source:#{source.id}",
          reason: reason.presence || "Payroll liability reversal",
          metadata: metadata
        )
      end
    end
  end

  def restate_for_pay_date!(old_pay_date:, new_pay_date:)
    PayPeriod.transaction do
      locked = PayPeriod.lock("FOR UPDATE").find(pay_period.id)
      ensure_committed!(locked)

      base_key = "pay-period:#{locked.id}:pay-date:#{old_pay_date}:to:#{new_pay_date}"
      sources = open_source_postings(locked)
      if sources.empty?
        sources = [ create_posting!(
          locked,
          posting_type: "historical_backfill",
          key: "#{base_key}:historical-capture",
          liability_date: old_pay_date,
          reason: "Captured legacy committed payroll before pay-date correction",
          metadata: { "legacy_capture" => true }
        ) ]
      end

      sources.each do |source|
        create_reversal!(
          locked,
          source: source,
          key: "#{base_key}:reversal:source:#{source.id}",
          reason: reason.presence || "Pay-date correction",
          metadata: { "old_pay_date" => old_pay_date, "new_pay_date" => new_pay_date }
        )
      end

      existing = PayrollLiabilityPosting.find_by(idempotency_key: "#{base_key}:replacement")
      existing || create_posting!(
        locked,
        posting_type: "replacement",
        key: "#{base_key}:replacement",
        liability_date: new_pay_date,
        reason: reason.presence || "Pay-date correction replacement",
        metadata: { "old_pay_date" => old_pay_date, "new_pay_date" => new_pay_date }
      )
    end
  end

  private

  attr_reader :pay_period, :actor, :posting_type, :idempotency_key,
              :liability_date, :reason, :metadata

  def validate_postable!(locked)
    ensure_committed!(locked)
    raise InvalidStateError, "Cannot post liabilities for a voided pay period" if locked.voided?
    raise InvalidStateError, "Cannot post liabilities for a pay period with no payroll items" unless locked.payroll_items.exists?
  end

  def ensure_committed!(locked)
    raise InvalidStateError, "Payroll liabilities require a committed pay period" unless locked.committed?
  end

  def create_posting!(locked, posting_type:, key:, liability_date:, reason:, metadata:)
    existing = PayrollLiabilityPosting.find_by(idempotency_key: key)
    return existing if existing

    snapshot_builder = PayComponentRuleSnapshotBuilder.new(company: locked.company, effective_on: liability_date)
    posting = PayrollLiabilityPosting.create!(
      company: locked.company,
      pay_period: locked,
      posting_type: posting_type,
      liability_date: liability_date,
      posted_at: Time.current,
      posted_by: actor,
      reason: reason,
      idempotency_key: key,
      component_rule_snapshot: snapshot_builder.call,
      metadata: metadata
    )

    entries = build_entries(locked, posting, snapshot_builder)
    PayrollLiabilityEntry.insert_all!(entries) if entries.any?
    posting.reload
  end

  def create_reversal!(locked, source:, key:, reason:, metadata:)
    existing = PayrollLiabilityPosting.find_by(source_posting_id: source.id) ||
               PayrollLiabilityPosting.find_by(idempotency_key: key)
    return existing if existing

    reversal = PayrollLiabilityPosting.create!(
      company: locked.company,
      pay_period: locked,
      posting_type: "reversal",
      source_posting: source,
      liability_date: source.liability_date,
      posted_at: Time.current,
      posted_by: actor,
      reason: reason,
      idempotency_key: key,
      component_rule_snapshot: source.component_rule_snapshot,
      metadata: metadata.merge("source_posting_id" => source.id)
    )

    rows = source.entries.map do |entry|
      {
        payroll_liability_posting_id: reversal.id,
        company_id: entry.company_id,
        payroll_item_id: entry.payroll_item_id,
        pay_component_tax_rule_id: entry.pay_component_tax_rule_id,
        component_key: entry.component_key,
        category: entry.category,
        authority: entry.authority,
        amount: -entry.amount,
        metadata: entry.metadata.merge("reverses_entry_id" => entry.id),
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    PayrollLiabilityEntry.insert_all!(rows) if rows.any?
    reversal.reload
  end

  def build_entries(locked, posting, snapshot_builder)
    now = Time.current
    locked.payroll_items.includes(
      payroll_item_field_entries: :payroll_field_definition,
      payroll_item_deductions: :deduction_type
    ).flat_map do |item|
      core = CORE_COMPONENTS.filter_map do |component_key, (field, category, authority)|
        amount = core_component_amount(item, component_key, field)
        next if amount.zero?

        entry_row(
          posting: posting,
          item: item,
          component_key: component_key,
          category: category,
          authority: authority,
          amount: amount,
          rule: snapshot_builder.rule_for(component_key.sub("guam_additional_income_tax_withheld", "guam_income_tax_withheld")),
          metadata: { "source_field" => field.to_s },
          now: now
        )
      end

      core + payroll_field_liability_rows(posting, item, now) + itemized_liability_rows(posting, item, now)
    end
  end

  # PayrollItem#medicare_tax stores the employee's regular Medicare tax plus
  # any Additional Medicare tax. The ledger classifies those liabilities
  # separately, so remove the additional amount from the regular Medicare
  # entry before posting it. This preserves the stored paycheck total while
  # preventing the additional tax from being payable twice.
  def core_component_amount(item, component_key, field)
    amount = item.public_send(field).to_d
    amount -= item.additional_medicare_tax.to_d if component_key == "medicare_employee"
    [ amount, 0.to_d ].max.round(2)
  end

  def payroll_field_liability_rows(posting, item, now)
    item.payroll_item_field_entries.filter_map do |field_entry|
      next unless field_entry.active? && field_entry.amount.to_d.nonzero?
      next unless field_entry.kind.in?(%w[deduction employer_contribution])

      category, default_authority = FIELD_CATEGORY_MAP[field_entry.category]
      next unless category

      if field_entry.employer_contribution?
        category = category.sub("_employee", "_employer")
      end
      definition = field_entry.payroll_field_definition
      authority = definition&.payee_name.presence || default_authority
      component_key = "payroll_field:#{definition&.id || "snapshot"}:#{field_entry.id}"

      entry_row(
        posting: posting,
        item: item,
        component_key: component_key,
        category: category,
        authority: authority,
        amount: field_entry.amount.to_d.round(2),
        rule: nil,
        metadata: {
          "payroll_item_field_entry_id" => field_entry.id,
          "payroll_field_definition_id" => definition&.id,
          "label" => field_entry.label,
          "tax_treatment" => field_entry.tax_treatment,
          "reporting_group" => field_entry.reporting_group
        },
        now: now
      )
    end
  end

  def itemized_liability_rows(posting, item, now)
    payroll_field_labels = item.payroll_item_field_entries.map(&:label).to_set

    item.payroll_item_deductions.filter_map do |deduction|
      type = deduction.deduction_type
      sub_category = type&.sub_category
      next unless sub_category.in?(%w[retirement garnishment child_support benefit])
      next if payroll_field_labels.include?(deduction.label)
      next if deduction.label.in?([ "401(k) Employer Match", "Roth 401(k) Employer Match" ])
      next if deduction.amount.to_d.zero?

      category = case sub_category
      when "retirement"
        deduction.employer_contribution? ? "retirement_employer" : "retirement_employee"
      when "garnishment" then "garnishment"
      when "child_support" then "child_support"
      when "benefit"
        deduction.employer_contribution? ? "benefit_employer" : "benefit_employee"
      end

      entry_row(
        posting: posting,
        item: item,
        component_key: "deduction_type:#{type&.id || "snapshot"}:#{deduction.id}",
        category: category,
        authority: type&.name.presence || deduction.label,
        amount: deduction.amount.to_d.round(2),
        rule: nil,
        metadata: {
          "payroll_item_deduction_id" => deduction.id,
          "deduction_type_id" => type&.id,
          "label" => deduction.label,
          "sub_category" => sub_category,
          "reporting_group" => deduction.reporting_group
        },
        now: now
      )
    end
  end

  def entry_row(posting:, item:, component_key:, category:, authority:, amount:, rule:, metadata:, now:)
    {
      payroll_liability_posting_id: posting.id,
      company_id: posting.company_id,
      payroll_item_id: item.id,
      pay_component_tax_rule_id: rule&.fetch("id", nil),
      component_key: component_key,
      category: category,
      authority: authority,
      amount: amount,
      metadata: metadata,
      created_at: now,
      updated_at: now
    }
  end

  def open_source_postings(locked)
    locked.payroll_liability_postings
      .source_postings
      .where.not(id: PayrollLiabilityPosting.where.not(source_posting_id: nil).select(:source_posting_id))
      .chronological
      .to_a
  end
end
