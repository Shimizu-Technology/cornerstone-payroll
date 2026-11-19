# frozen_string_literal: true

class PayrollFilingResponsibilityRecorder
  MAX_ATTEMPTS = 2

  # decisions: several { filing_types:, responsible_party:, prior_provider_through: }
  # saved in one transaction and one audit entry, so a client's year-end
  # W-2GU and 1099 answers change together or not at all. Without it, one
  # party (and prior-provider date) applies to every filing type.
  def initialize(company:, actor:, tax_year:, imported_payroll_inclusion:, filing_types: nil,
                 responsible_party: nil, quarter: nil, source_cutoff_date: nil,
                 prior_provider_through: nil, notes: nil, decisions: nil)
    @company = company
    @actor = actor
    @tax_year = Integer(tax_year)
    @quarter = quarter.nil? ? nil : Integer(quarter)
    @decisions = (decisions || [ { filing_types: filing_types, responsible_party: responsible_party, prior_provider_through: prior_provider_through } ])
      .map do |decision|
        {
          filing_types: Array(decision[:filing_types]).map(&:to_s).uniq,
          responsible_party: decision[:responsible_party].to_s,
          prior_provider_through: decision[:prior_provider_through]
        }
      end
    @filing_types = @decisions.flat_map { |decision| decision[:filing_types] }
    @imported_payroll_inclusion = imported_payroll_inclusion.to_s
    @source_cutoff_date = source_cutoff_date
    @notes = notes
  end

  def call
    PayrollFilingResponsibilityPolicy.authorize_record!(actor: actor, company: company)
    validate_filing_types!

    attempts = 0
    begin
      attempts += 1
      persist_decisions!
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < MAX_ATTEMPTS
      raise
    end
  end

  private

  attr_reader :company, :actor, :tax_year, :quarter, :decisions, :filing_types,
              :imported_payroll_inclusion, :source_cutoff_date, :notes

  def validate_filing_types!
    raise ArgumentError, "Select at least one filing type" if decisions.empty? || decisions.any? { |decision| decision[:filing_types].empty? }
    raise ArgumentError, "Each filing type can be decided once per request" if filing_types.uniq.length != filing_types.length

    unknown = filing_types - PayrollFilingResponsibility::FILING_TYPES
    raise ArgumentError, "Unknown filing type: #{unknown.join(', ')}" if unknown.any?

    annual = filing_types & PayrollFilingResponsibility::YEAR_END_FILING_TYPES
    quarterly = filing_types & PayrollFilingResponsibility::QUARTERLY_FILING_TYPES
    raise ArgumentError, "Annual and quarterly filing types must be reviewed separately" if annual.any? && quarterly.any?
    raise ArgumentError, "quarter must be blank for annual filings" if annual.any? && quarter.present?
    raise ArgumentError, "quarter must be 1, 2, 3, or 4 for quarterly filings" if quarterly.any? && !quarter.in?(1..4)
  end

  def persist_decisions!
    PayrollFilingResponsibility.transaction do
      # Share the onboarding/reversal lock so an ownership edit cannot race
      # its before/after evidence snapshot or be overwritten by reversal.
      company.lock!
      @actor = User.lock.find_by(id: actor&.id)
      CompanyAssignment.where(company_id: company.id, user_id: actor&.id).lock.load
      PayrollFilingResponsibilityPolicy.authorize_record!(actor: actor, company: company)
      reviewed_at = Time.current
      before = {}

      records = decisions.flat_map do |decision|
        decision[:filing_types].map { |filing_type| [ filing_type, decision ] }
      end.map do |filing_type, decision|
        record = company.payroll_filing_responsibilities.find_or_initialize_by(
          tax_year: tax_year,
          quarter: quarter,
          filing_type: filing_type
        )
        before[filing_type] = decision_snapshot(record) if record.persisted?
        record.assign_attributes(
          responsible_party: decision[:responsible_party],
          imported_payroll_inclusion: imported_payroll_inclusion,
          source_cutoff_date: source_cutoff_date,
          prior_provider_through: decision[:prior_provider_through],
          reviewed_by: actor,
          reviewed_by_name: actor.name,
          reviewed_by_email: actor.email,
          reviewed_by_role: actor.role,
          reviewed_at: reviewed_at,
          notes: notes
        )
        record.save!
        record
      end

      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "payroll_filing_responsibilities#recorded",
        record_type: "payroll_filing_responsibilities",
        record_id: records.one? ? records.first.id : nil,
        subject_name: "#{company.name} #{tax_year} payroll filing responsibility",
        metadata: {
          tax_year: tax_year,
          quarter: quarter,
          filing_types: filing_types,
          before: before,
          after: records.to_h { |record| [ record.filing_type, decision_snapshot(record) ] }
        }
      )

      records
    end
  end

  def decision_snapshot(record)
    {
      id: record.id,
      filing_type: record.filing_type,
      responsible_party: record.responsible_party,
      imported_payroll_inclusion: record.imported_payroll_inclusion,
      source_cutoff_date: record.source_cutoff_date&.iso8601,
      prior_provider_through: record.prior_provider_through&.iso8601,
      reviewed_by_id: record.reviewed_by_id,
      reviewed_by_name: record.reviewed_by_name,
      reviewed_by_email: record.reviewed_by_email,
      reviewed_by_role: record.reviewed_by_role,
      reviewed_at: record.reviewed_at&.iso8601,
      notes: record.notes
    }
  end
end
