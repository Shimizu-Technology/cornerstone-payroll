# frozen_string_literal: true

class PayrollFilingResponsibilityGate
  TASK_FILING_TYPES = {
    "form_500" => "guam_withholding",
    "w1" => "guam_withholding",
    "swica" => "swica",
    "federal_941" => "form_941",
    "schedule_b" => "form_941"
  }.freeze
  OFFICIAL_FORM_FILING_TYPES = {
    "form_941" => "form_941",
    "schedule_b" => "form_941",
    "w1" => "guam_withholding",
    "swica" => "swica"
  }.freeze

  def self.quarterly(company:, tax_year:, quarter:)
    coverage = source_coverage(company: company, tax_year: tax_year, quarter: quarter)
    filings = PayrollFilingResponsibility::QUARTERLY_FILING_TYPES.index_with do |filing_type|
      new(
        company: company,
        tax_year: tax_year,
        quarter: quarter,
        filing_type: filing_type,
        source_coverage: coverage
      ).payload
    end

    grouped_payload(scope: "quarterly", tax_year: tax_year, quarter: quarter, coverage: coverage, filings: filings)
  end

  def self.annual(company:, tax_year:)
    coverage = source_coverage(company: company, tax_year: tax_year, quarter: nil)
    filings = PayrollFilingResponsibility::ANNUAL_FILING_TYPES.index_with do |filing_type|
      new(
        company: company,
        tax_year: tax_year,
        filing_type: filing_type,
        source_coverage: coverage
      ).payload
    end

    grouped_payload(scope: "annual", tax_year: tax_year, quarter: nil, coverage: coverage, filings: filings)
  end

  def self.for_task(task)
    packet = task.quarterly_compliance_packet
    filing_type = TASK_FILING_TYPES.fetch(task.task_type)
    new(company: packet.company, tax_year: packet.year, quarter: packet.quarter, filing_type: filing_type).payload
  end

  def self.source_coverage(company:, tax_year:, quarter:)
    range = filing_range(tax_year: tax_year, quarter: quarter)
    native_scope = PayPeriod.reportable_committed.where(company_id: company.id, pay_date: range)
    historical_scope = HistoricalPayPeriod.joins(:historical_import_batch)
                                            .where(
                                              company_id: company.id,
                                              period_type: "regular",
                                              pay_date: range,
                                              historical_import_batches: { status: "locked" }
                                            )

    native_count = native_scope.count
    historical_count = historical_scope.count
    latest_historical_lock_at = historical_scope.maximum("historical_import_batches.locked_at")

    {
      native_pay_period_count: native_count,
      historical_pay_period_count: historical_count,
      has_native_payroll: native_count.positive?,
      has_historical_payroll: historical_count.positive?,
      mixed_sources: native_count.positive? && historical_count.positive?,
      latest_historical_lock_at: latest_historical_lock_at&.iso8601,
      historical_scope: "locked_regular_pay_periods",
      period_basis: "pay_date"
    }
  end

  def self.filing_range(tax_year:, quarter:)
    year = Integer(tax_year)
    return Date.new(year, 1, 1)..Date.new(year, 12, 31) if quarter.nil?

    normalized_quarter = Integer(quarter)
    raise ArgumentError, "quarter must be 1, 2, 3, or 4" unless normalized_quarter.in?(1..4)

    first_month = ((normalized_quarter - 1) * 3) + 1
    Date.new(year, first_month, 1)..Date.new(year, first_month + 2, -1)
  end

  def initialize(company:, tax_year:, filing_type:, quarter: nil, source_coverage: nil)
    @company = company
    @tax_year = Integer(tax_year)
    @quarter = quarter.nil? ? nil : Integer(quarter)
    @filing_type = filing_type.to_s
    validate_period!
    @source_coverage = source_coverage || self.class.source_coverage(
      company: company,
      tax_year: @tax_year,
      quarter: @quarter
    )
  end

  def payload
    {
      filing_type: filing_type,
      scope: quarter.nil? ? "annual" : "quarterly",
      tax_year: tax_year,
      quarter: quarter,
      source_coverage: source_coverage,
      responsibility_required: source_coverage[:has_historical_payroll],
      decision_recorded: responsibility.present?,
      responsibility: responsibility&.decision_payload,
      status: status,
      blockers: blockers,
      capabilities: {
        can_review_draft: true,
        can_export_draft: true,
        can_mark_filing_ready: blockers.empty?,
        can_export_filing_ready: blockers.empty?
      }
    }
  end

  private

  attr_reader :company, :tax_year, :quarter, :filing_type, :source_coverage

  def self.grouped_payload(scope:, tax_year:, quarter:, coverage:, filings:)
    blockers = filings.flat_map do |filing_type, filing|
      filing.fetch(:blockers).map { |blocker| blocker.merge(filing_type: filing_type) }
    end

    {
      scope: scope,
      tax_year: Integer(tax_year),
      quarter: quarter,
      source_coverage: coverage,
      filings: filings,
      blockers: blockers,
      capabilities: {
        can_review_draft: true,
        can_export_draft: true,
        all_filing_ready_exports_allowed: blockers.empty?
      }
    }
  end

  private_class_method :grouped_payload

  def validate_period!
    unless filing_type.in?(PayrollFilingResponsibility::FILING_TYPES)
      raise ArgumentError, "filing_type must be form_941, guam_withholding, swica, or w2_gu"
    end

    if filing_type.in?(PayrollFilingResponsibility::ANNUAL_FILING_TYPES)
      raise ArgumentError, "quarter must be blank for annual filings" if quarter.present?
    elsif !quarter.in?(1..4)
      raise ArgumentError, "quarter must be 1, 2, 3, or 4 for quarterly filings"
    end
  end

  def responsibility
    return @responsibility if defined?(@responsibility)

    @responsibility = company.payroll_filing_responsibilities.includes(:reviewed_by).find_by(
      tax_year: tax_year,
      quarter: quarter,
      filing_type: filing_type
    )
  end

  def status
    return "responsibility_not_required" unless source_coverage[:has_historical_payroll] || responsibility
    return "responsibility_required" unless responsibility
    return "external_provider_responsible" if responsibility.responsible_party == "external_provider"
    return "historical_payroll_excluded" if responsibility.imported_payroll_inclusion == "excluded"
    return "review_stale" if responsibility_stale?

    "cornerstone_responsible"
  end

  def blockers
    return [] unless source_coverage[:has_historical_payroll] || responsibility

    if responsibility.nil?
      return [ blocker(
        code: "PAYROLL_FILING_RESPONSIBILITY_REQUIRED",
        message: "Locked imported payroll exists in this filing period. Record who is responsible and whether the imported wages belong in this filing before marking it ready."
      ) ]
    end

    if responsibility.responsible_party == "external_provider"
      return [ blocker(
        code: "EXTERNAL_PROVIDER_RESPONSIBLE",
        message: "An external provider is responsible for this filing. Cornerstone output remains draft/reference only."
      ) ]
    end

    if responsibility.imported_payroll_inclusion == "excluded" && source_coverage[:has_historical_payroll]
      return [ blocker(
        code: "HISTORICAL_PAYROLL_EXCLUSION_UNSAFE",
        message: "Cornerstone cannot mark this filing ready while locked imported wages inside the filing period are excluded. Keep the output as a draft and resolve the filing source coverage."
      ) ]
    end

    if responsibility_stale?
      return [ blocker(
        code: "PAYROLL_FILING_RESPONSIBILITY_STALE",
        message: "Imported payroll was locked after this responsibility review. Review the filing responsibility again before marking the filing ready."
      ) ]
    end

    []
  end

  def responsibility_stale?
    locked_at = source_coverage[:latest_historical_lock_at]
    locked_at.present? && responsibility.reviewed_at < Time.iso8601(locked_at)
  end

  def blocker(code:, message:)
    {
      code: code,
      severity: "blocking",
      message: message
    }
  end
end
