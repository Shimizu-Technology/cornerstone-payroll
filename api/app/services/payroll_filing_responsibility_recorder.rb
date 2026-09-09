# frozen_string_literal: true

class PayrollFilingResponsibilityRecorder
  MAX_ATTEMPTS = 2

  def initialize(company:, actor:, tax_year:, filing_types:, responsible_party:,
                 imported_payroll_inclusion:, quarter: nil, source_cutoff_date: nil, notes: nil)
    @company = company
    @actor = actor
    @tax_year = Integer(tax_year)
    @quarter = quarter.nil? ? nil : Integer(quarter)
    @filing_types = Array(filing_types).map(&:to_s).uniq
    @responsible_party = responsible_party.to_s
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

  attr_reader :company, :actor, :tax_year, :quarter, :filing_types, :responsible_party,
              :imported_payroll_inclusion, :source_cutoff_date, :notes

  def validate_filing_types!
    raise ArgumentError, "Select at least one filing type" if filing_types.empty?

    unknown = filing_types - PayrollFilingResponsibility::FILING_TYPES
    raise ArgumentError, "Unknown filing type: #{unknown.join(', ')}" if unknown.any?

    annual = filing_types & PayrollFilingResponsibility::ANNUAL_FILING_TYPES
    quarterly = filing_types & PayrollFilingResponsibility::QUARTERLY_FILING_TYPES
    raise ArgumentError, "Annual and quarterly filing types must be reviewed separately" if annual.any? && quarterly.any?
    raise ArgumentError, "quarter must be blank for annual filings" if annual.any? && quarter.present?
    raise ArgumentError, "quarter must be 1, 2, 3, or 4 for quarterly filings" if quarterly.any? && !quarter.in?(1..4)
  end

  def persist_decisions!
    PayrollFilingResponsibility.transaction do
      reviewed_at = Time.current
      before = {}

      records = filing_types.map do |filing_type|
        record = company.payroll_filing_responsibilities.find_or_initialize_by(
          tax_year: tax_year,
          quarter: quarter,
          filing_type: filing_type
        )
        before[filing_type] = decision_snapshot(record) if record.persisted?
        record.assign_attributes(
          responsible_party: responsible_party,
          imported_payroll_inclusion: imported_payroll_inclusion,
          source_cutoff_date: source_cutoff_date,
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
      reviewed_by_id: record.reviewed_by_id,
      reviewed_by_name: record.reviewed_by_name,
      reviewed_by_email: record.reviewed_by_email,
      reviewed_by_role: record.reviewed_by_role,
      reviewed_at: record.reviewed_at&.iso8601,
      notes: record.notes
    }
  end
end
