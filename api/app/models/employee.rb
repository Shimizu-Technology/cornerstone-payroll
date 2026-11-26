# frozen_string_literal: true

class Employee < ApplicationRecord
  validates :name_suffix, inclusion: { in: %w[JR SR II III IV V VI] }, allow_blank: true
  before_validation { self.name_suffix = name_suffix.to_s.strip.upcase.delete(".").presence }
  include TracksRecordCreation

  belongs_to :created_by, class_name: "User", optional: true
  include PayrollAdjustable
  attr_accessor :ssn_confirmation, :require_ssn_confirmation, :allow_tax_classification_change

  EMPLOYMENT_TYPES = %w[hourly salary contractor].freeze
  CONTACT_SOURCES = %w[client staff employee import].freeze
  CONFIGURATION_REVIEW_STATUSES = %w[complete needs_review].freeze
  CONFIGURATION_SOURCES = %w[quickbooks_history].freeze
  SALARY_TYPES = %w[annual per_period variable].freeze
  PAYMENT_DELIVERY_METHODS = %w[paper_check direct_deposit].freeze
  CONTRACTOR_TYPES = %w[individual business].freeze
  CONTRACTOR_PAY_TYPES = %w[hourly flat_fee].freeze
  CONTRACTOR_ONLY_ATTRIBUTES = %i[business_name contractor_ein contractor_type contractor_pay_type w9_on_file].freeze
  MIN_SUPPORTED_W4_FORM_VERSION = 2020
  LEGACY_SOCIAL_SECURITY_RATE = BigDecimal("0.062")
  YTD_AGGREGATE_SOURCE_COLUMNS = {
    gross_pay: :gross_pay,
    net_pay: :net_pay,
    withholding_tax: :withholding_tax,
    social_security_tax: :social_security_tax,
    medicare_tax: :medicare_tax,
    additional_withholding: :additional_withholding,
    retirement: :retirement_payment,
    roth_retirement: :roth_retirement_payment,
    insurance: :insurance_payment,
    loans: :loan_payment,
    tips_paid_out: :tips_paid_out,
    social_security_taxable_total: :social_security_taxable_total,
    medicare_taxable_wages: :medicare_taxable_wages
  }.freeze
  YTD_AGGREGATE_COLUMNS = {
    gross_pay: "COALESCE(SUM(gross_pay), 0)",
    net_pay: "COALESCE(SUM(net_pay), 0)",
    withholding_tax: "COALESCE(SUM(withholding_tax), 0)",
    social_security_tax: "COALESCE(SUM(social_security_tax), 0)",
    medicare_tax: "COALESCE(SUM(medicare_tax), 0)",
    additional_withholding: "COALESCE(SUM(additional_withholding), 0)",
    retirement: "COALESCE(SUM(retirement_payment), 0)",
    roth_retirement: "COALESCE(SUM(roth_retirement_payment), 0)",
    insurance: "COALESCE(SUM(insurance_payment), 0)",
    loans: "COALESCE(SUM(loan_payment), 0)",
    tips_paid_out: "COALESCE(SUM(tips_paid_out), 0)",
    social_security_taxable_total: "COALESCE(SUM(COALESCE(social_security_taxable_wages + social_security_taxable_tips, gross_pay)), 0)",
    medicare_taxable_wages: "COALESCE(SUM(COALESCE(medicare_taxable_wages, gross_pay)), 0)"
  }.freeze

  def self.social_security_rate_for_year(year)
    AnnualTaxConfig.for_year(year)&.ss_rate&.to_d ||
      TaxTable.for_year(year).where.not(ss_rate: nil).pick(:ss_rate)&.to_d ||
      LEGACY_SOCIAL_SECURITY_RATE
  end

  def self.ytd_aggregate_columns_for_year(year)
    rate = connection.quote(social_security_rate_for_year(year))
    YTD_AGGREGATE_COLUMNS.merge(
      social_security_taxable_total: <<~SQL.squish
        COALESCE(SUM(
          CASE
            WHEN social_security_taxable_wages IS NOT NULL
             AND social_security_taxable_tips IS NOT NULL
              THEN social_security_taxable_wages + social_security_taxable_tips
            ELSE social_security_tax / NULLIF(#{rate}, 0)
          END
        ), 0)
      SQL
    )
  end

  belongs_to :company
  belongs_to :department, optional: true
  belongs_to :test_workspace_source_employee,
             class_name: "Employee",
             optional: true,
             inverse_of: :training_replay_copies
  has_many :training_replay_copies,
           class_name: "Employee",
           foreign_key: :test_workspace_source_employee_id,
           inverse_of: :test_workspace_source_employee,
           dependent: :restrict_with_error
  belongs_to :previous_employee,
             class_name: "Employee",
             optional: true,
             inverse_of: :next_employee
  has_one :next_employee,
          class_name: "Employee",
          foreign_key: :previous_employee_id,
          inverse_of: :previous_employee,
          dependent: :restrict_with_error
  has_many :payroll_items, dependent: :destroy
  has_many :pay_period_excluded_employees, dependent: :destroy
  has_many :employee_account_links, dependent: :restrict_with_error
  has_many :delivery_consents, dependent: :restrict_with_error
  has_many :employee_deductions, dependent: :destroy
  has_many :deduction_types, through: :employee_deductions
  has_many :employee_payroll_fields, dependent: :destroy
  has_many :payroll_field_definitions, through: :employee_payroll_fields
  has_many :employee_ytd_totals, dependent: :destroy
  has_many :employee_loans, dependent: :destroy
  has_many :employee_w4_elections, dependent: :restrict_with_error
  has_many :employee_retirement_elections, dependent: :restrict_with_error
  has_many :employee_retirement_year_inputs, dependent: :restrict_with_error
  has_many :historical_workers, dependent: :restrict_with_error
  # Compensation history is removed before the wage rates it references.
  has_many :employee_compensation_changes, dependent: :restrict_with_error
  has_many :employee_wage_rate_versions, dependent: :restrict_with_error
  has_many :employee_wage_rates, dependent: :destroy
  has_many :employee_tipped_occupations, dependent: :destroy
  has_many :employee_work_profiles, dependent: :restrict_with_error
  has_many :employee_status_events, dependent: :restrict_with_error
  has_many :daily_time_records, dependent: :restrict_with_error
  has_many :payroll_time_allocations, dependent: :restrict_with_error
  has_many :employee_change_requests, dependent: :restrict_with_error
  has_many :employee_document_requirements, dependent: :restrict_with_error
  has_many :employee_document_requirement_events, dependent: :restrict_with_error
  has_many :employee_notes, dependent: :restrict_with_error
  has_many :historical_paychecks, dependent: :restrict_with_error
  has_many :historical_employee_ytd_balances, dependent: :restrict_with_error
  has_many :employee_configuration_review_resolutions, dependent: :restrict_with_error
  # One-off contractor checks linked to this contractor for its 1099-NEC.
  has_many :linked_non_employee_checks, class_name: "NonEmployeeCheck", foreign_key: :payee_employee_id,
           inverse_of: :payee_employee, dependent: :restrict_with_error

  attr_accessor :intake_original_employee, :require_initial_w4_effective_on
  # Creation paths that copy an existing history (test workspaces, rehearsal
  # promotion) skip the initial version and copy the source's instead.
  attr_accessor :skip_initial_compensation_history, :initial_compensation_source, :initial_compensation_actor
  validate :valid_supplied_intake_dates
  before_update :invalidate_intake_payroll_confirmation
  before_update :guard_compensation_mutation
  before_save :clear_verification_on_contact_change
  # Closes an open employee app invite, audits and notifies the old address
  # (EmployeeLinks::EmailChange). Inside the UPDATE, so the row is locked.
  after_update :apply_employee_app_email_change, if: :saved_change_to_email?
  after_create :record_initial_compensation_history, unless: :skip_initial_compensation_history
  before_validation :normalize_w4_source_reference
  before_validation :normalize_intake_blank_details
  before_validation :normalize_pay_rate_precision
  before_validation :normalize_filing_status_value
  before_validation :normalize_w4_currency_precision
  before_validation :normalize_default_payroll_adjustments

  # Encrypt sensitive fields
  encrypts :ssn_encrypted, deterministic: true
  encrypts :bank_routing_number_encrypted
  encrypts :bank_account_number_encrypted
  # A business contractor's EIN is a tax identifier, protected like the SSN.
  # Plaintext reads stay supported while the post-deploy backfill
  # (ContractorEinEncryption, employees:encrypt_contractor_eins) rolls out;
  # EncryptedDataReadiness fails until no plaintext EIN remains, after which
  # this tolerance can be removed.
  encrypts :contractor_ein, deterministic: true, support_unencrypted_data: true
  normalizes :contractor_ein, with: ->(value) { value.to_s.strip.presence }

  validates :w4_source_reference, length: { maximum: 255 }, allow_nil: true
  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :pay_rate,
            presence: true,
            numericality: { greater_than_or_equal_to: 0, less_than: 1_000_000_000_000 }
  validates :employment_type, inclusion: { in: EMPLOYMENT_TYPES }
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :status, inclusion: { in: %w[active inactive terminated] }
  validates :contact_source, inclusion: { in: CONTACT_SOURCES }, allow_nil: true
  validates :payment_delivery_method, inclusion: { in: PAYMENT_DELIVERY_METHODS }, allow_nil: true
  validates :configuration_review_status, inclusion: { in: CONFIGURATION_REVIEW_STATUSES }
  validates :configuration_source, inclusion: { in: CONFIGURATION_SOURCES }, allow_nil: true
  validate :plausible_hire_date, if: :will_save_change_to_hire_date?
  validate :demo_bank_details_are_fictional, if: -> { company&.demo? && bank_routing_number_encrypted.present? }
  validate :demo_has_no_contractors, if: -> { company&.demo? && employment_type == "contractor" }
  validate :configuration_review_items_are_valid
  validates :salary_type, inclusion: { in: SALARY_TYPES }, if: :salary?
  validates :contractor_type, inclusion: { in: CONTRACTOR_TYPES }, if: :contractor?
  validates :contractor_pay_type, inclusion: { in: CONTRACTOR_PAY_TYPES }, if: :contractor?
  validate :required_filing_fields, if: :filing_data_validation_required?
  validate :filing_ssn_format, if: -> { filing_data_validation_required? && filing_ssn_required? }
  validate :business_ein_format, if: -> { filing_data_validation_required? && business_contractor? }
  validate :matching_ssn_confirmation, if: :ssn_confirmation_required?
  validate :tax_classification_cannot_change_in_place, on: :update
  validate :previous_employee_transition_is_valid
  validate :portal_pending_employee_is_inactive
  validate :test_workspace_source_employee_is_valid

  # W-2 employee validations (not applicable to contractors)
  with_options unless: :contractor? do
    validates :filing_status, inclusion: { in: %w[single married married_separate head_of_household] }
    validates :allowances, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :retirement_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :roth_retirement_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :employer_retirement_match_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :employer_roth_match_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :w4_dependent_credit, numericality: { greater_than_or_equal_to: 0 }
    validates :w4_step4a_other_income, numericality: { greater_than_or_equal_to: 0 }
    validates :w4_step4b_deductions, numericality: { greater_than_or_equal_to: 0 }
    validates :w4_form_version, numericality: { only_integer: true, greater_than_or_equal_to: 1987, less_than_or_equal_to: ->(_) { Date.current.year + 1 } }
  end

  scope :intake_incomplete, -> {
    where.not(intake_exception: {}).where(<<~SQL.squish)
      (ssn_encrypted IS NULL AND NOT (employment_type = 'contractor' AND COALESCE(contractor_type, '') = 'business'))
      OR (employment_type = 'contractor' AND COALESCE(contractor_type, '') = 'business' AND COALESCE(contractor_ein, '') = '')
      OR hire_date IS NULL OR COALESCE(address_line1, '') = '' OR COALESCE(city, '') = ''
      OR COALESCE(state, '') = '' OR COALESCE(zip, '') = ''
      OR (employment_type <> 'contractor' AND (w4_effective_on IS NULL OR NOT EXISTS (
        SELECT 1 FROM employee_w4_elections WHERE employee_id = employees.id AND source <> 'default_withholding'
      )))
    SQL
  }

  scope :active, -> { where(status: "active") }

  def contact_revision
    updated_at&.iso8601(6)
  end
  scope :needs_contact_details, ->(flagged_emails: []) {
    v = EmployeeContactValidator
    email = v.normalized_email_node(arel_table[:email])
    email_part = ->(index) { Arel::Nodes::NamedFunction.new("SPLIT_PART", [ email, Arel::Nodes.build_quoted("@"), Arel::Nodes.build_quoted(index) ]) }
    # Whitespace-only fields (tabs and newlines too) count as missing.
    clauses = %i[email phone address_line1 city state zip].map { |field| v.blank_node(arel_table[field]) }
    clauses << email_part.call(1).in(v::PLACEHOLDER_LOCAL_PARTS.to_a)
    clauses << email_part.call(2).in(v::PLACEHOLDER_DOMAINS.to_a)
    normalized_flagged = Array(flagged_emails).filter_map { |flagged| v.normalize_email(flagged) }.uniq
    clauses << email.in(normalized_flagged) if normalized_flagged.any?
    where(clauses.reduce { |combined, clause| combined.or(clause) })
  }
  scope :hourly, -> { where(employment_type: "hourly") }
  scope :salary, -> { where(employment_type: "salary") }
  scope :contractor, -> { where(employment_type: "contractor") }
  scope :w2_employees, -> { where(employment_type: %w[hourly salary]) }
  scope :eligible_for_payroll_run, ->(period, explicitly_selected: false) {
    if explicitly_selected && %w[final correction adjustment].include?(period.run_purpose)
      where("status IN (?) OR (status = ? AND EXISTS (SELECT 1 FROM employee_status_events WHERE employee_id = employees.id AND event_type = ?))", %w[active terminated], "inactive", "deactivated")
        .where("intake_exception = '{}'::jsonb OR (intake_payroll_confirmed_at IS NOT NULL AND intake_payroll_eligible_from <= ?)", period.end_date)
        .where("hire_date IS NULL OR hire_date <= ?", period.end_date)
    else
      eligible_for_period(period.start_date, period.end_date)
    end
  }
  scope :eligible_for_period, ->(period_start, period_end) {
    where("intake_exception = '{}'::jsonb OR (intake_payroll_confirmed_at IS NOT NULL AND intake_payroll_eligible_from <= ?)", period_end)
      .where("hire_date IS NULL OR hire_date <= ?", period_end)
      .where("termination_date IS NULL OR termination_date >= ?", period_start)
      .where("status IN ('active', 'terminated') OR EXISTS (SELECT 1 FROM employee_status_events WHERE employee_id = employees.id AND event_type = 'deactivated')")
      .where(
        <<~SQL.squish,
          NOT EXISTS (
            SELECT 1
            FROM employee_status_events termination_events
            WHERE termination_events.employee_id = employees.id
              AND ((termination_events.event_type = 'terminated' AND termination_events.effective_date < :period_start)
                OR (termination_events.event_type = 'deactivated' AND termination_events.effective_date <= :period_start))
              AND NOT EXISTS (
                SELECT 1
                FROM employee_status_events reactivation_events
                WHERE reactivation_events.employee_id = employees.id
                  AND reactivation_events.event_type = 'reactivated'
                  AND (reactivation_events.effective_date > termination_events.effective_date
                    OR (reactivation_events.effective_date = termination_events.effective_date AND reactivation_events.id > termination_events.id))
                  AND reactivation_events.effective_date <= :period_end
              )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM employee_status_events initial_inactive_event
            WHERE initial_inactive_event.employee_id = employees.id
              AND initial_inactive_event.previous_status = 'inactive'
              AND NOT EXISTS (
                SELECT 1
                FROM employee_status_events earlier_event
                WHERE earlier_event.employee_id = employees.id
                  AND (earlier_event.effective_date < initial_inactive_event.effective_date
                    OR (earlier_event.effective_date = initial_inactive_event.effective_date AND earlier_event.id < initial_inactive_event.id))
              )
              AND NOT EXISTS (
                SELECT 1
                FROM employee_status_events active_event
                WHERE active_event.employee_id = employees.id
                  AND active_event.resulting_status = 'active'
                  AND active_event.effective_date <= :period_end
              )
          )
        SQL
        period_start: period_start,
        period_end: period_end
      )
  }

  def active_wage_rates
    if association(:employee_wage_rates).loaded?
      employee_wage_rates.select(&:active?).sort_by { |rate| [ rate.is_primary ? 0 : 1, rate.label.to_s ] }
    else
      employee_wage_rates.active.order(is_primary: :desc, label: :asc)
    end
  end

  def retirement_election_on(date)
    if association(:employee_retirement_elections).loaded?
      employee_retirement_elections
        .select { |election| election.effective_on <= date.to_date }
        .max_by { |election| [ election.effective_on, election.created_at, election.id ] }
    else
      employee_retirement_elections.effective_on(date).first
    end
  end

  def retirement_year_input_for(year)
    if association(:employee_retirement_year_inputs).loaded?
      employee_retirement_year_inputs.select { |input| input.tax_year == year.to_i }
        .max_by { |input| [ input.created_at, input.id ] }
    else
      employee_retirement_year_inputs.where(tax_year: year).recent_first.first
    end
  end

  # Profile wage-rate rows describe hourly work. Keep them as history when the
  # worker changes pay basis, but never use an old hourly amount as annual salary
  # or a flat contractor fee when preparing a new/current payroll calculation.
  def default_payroll_rate
    hourly_pay_basis? ? (primary_wage_rate&.rate || pay_rate) : pay_rate
  end

  # Effective-dated compensation (M3-4). pay_rate and the wage-rate rows cache
  # today's values; these resolve the version in effect on a given date.
  # Payroll readers pass the pay period end date; profile views pass today.
  # The first version also covers earlier dates, so payroll older than the
  # recorded history keeps the employee's original rate.
  def compensation_on(date)
    date = date.to_date
    changes = compensation_change_timeline
    changes.find { |change| change.covers?(date) } || changes.find { |change| !change.historical_correction? && date < change.effective_on }
  end

  def payroll_compensation_on(date)
    compensation_on(date) || self
  end

  def payroll_rate_on(date)
    payroll_compensation_on(date).pay_rate
  end

  def default_payroll_rate_on(date)
    compensation = payroll_compensation_on(date)
    compensation.hourly_pay_basis? ? (primary_wage_rate_on(date)&.rate || compensation.pay_rate) : compensation.pay_rate
  end

  # Wage rates as they stood on the date, as read-only EmployeeWageRate
  # objects carrying that version's label, rate and flags. A rate with no
  # recorded history (an unsaved employee) falls back to its current row.
  def wage_rates_on(date, include_inactive: false)
    date = date.to_date
    rates = employee_wage_rates.to_a.filter_map do |row|
      if wage_rate_versions_by_row.fetch(row.id, []).empty?
        next if row.label.start_with?(EmployeeCompensationChangeService::RESERVED_LABEL_PREFIX)

        next (include_inactive || row.active?) ? row : nil
      end

      version = wage_rate_version_for(row, date)
      next unless version && (include_inactive || version.active)

      version.as_wage_rate(row)
    end
    rates.sort_by { |rate| [ rate.is_primary ? 0 : 1, rate.label.to_s ] }
  end

  def primary_wage_rate_on(date)
    rates = wage_rates_on(date)
    rates.find(&:is_primary) || rates.first
  end

  def wage_rate_version_for(row, date)
    date = date.to_date
    versions = wage_rate_versions_by_row.fetch(row.id, [])
    covering = versions.find { |version| version.covers?(date) }
    return covering if covering

    first = versions.find { |version| !version.historical_correction? }
    baseline = compensation_change_timeline.find { |version| !version.historical_correction? }&.effective_on
    first if first && date < first.effective_on && (first.source == "backfill" || (baseline && first.effective_on <= baseline))
  end

  scope :with_compensation_history, -> { preload(:employee_compensation_changes, :employee_wage_rates, :employee_wage_rate_versions) }

  # Pay-rate or wage-rate versions that start after the first day of the
  # range and on or before its last day: a change in the middle of a period.
  # The initial setup (a timeline's first version from the employee's start)
  # is not a change.
  def compensation_changes_within(start_date, end_date)
    range = (start_date.to_date + 1)..end_date.to_date
    timeline = compensation_change_timeline
    baseline = timeline.find { |version| !version.historical_correction? }
    wage_changes = wage_rate_versions_by_row.values.flat_map do |versions|
      initial_wage = versions.find { |version| !version.historical_correction? }
      initial_wage && baseline && initial_wage.effective_on <= baseline.effective_on ? versions - [ initial_wage ] : versions
    end
    (timeline.reject { |version| version == baseline } + wage_changes).select { |version| range.cover?(version.effective_on) }.sort_by(&:effective_on)
  end

  def hourly_pay_basis?
    hourly? || (contractor? && contractor_pay_type == "hourly")
  end

  def primary_wage_rate
    rates = active_wage_rates
    rates.find(&:is_primary) || rates.first
  end

  def full_name
    [ first_name, middle_name, last_name ].compact_blank.join(" ")
  end

  # The legal name with its suffix ("Jr.", "III") for records and payroll
  # documents. W-2GU prints the coded suffix in its own box.
  def legal_name
    suffix = name_suffix.to_s.strip.upcase.delete(".")
    [ full_name, { "JR" => "Jr.", "SR" => "Sr." }.fetch(suffix, suffix) ].compact_blank.join(" ")
  end

  def display_name
    contractor? && business_name.present? ? "#{full_name} (#{business_name})" : full_name
  end

  def full_address
    city_state_zip = [
      city.presence,
      state.presence,
      zip.presence
    ].compact

    city_state_zip_line = if city_state_zip.empty?
      nil
    elsif city.present? && state.present?
      [ "#{city}, #{state}", zip.presence ].compact.join(" ")
    else
      city_state_zip.join(" ")
    end

    [ address_line1, address_line2, city_state_zip_line ].compact_blank.join("\n")
  end

  def active?
    status == "active"
  end

  # w4_on: the date the W-4 is checked on, a payroll's pay_date when the
  # caller is building that payroll (EmployeeIntakePolicy.payroll_ready?).
  def eligible_on?(date, w4_on: date)
    date = date.to_date
    return false unless EmployeeIntakePolicy.payroll_ready?(self, date, w4_on: w4_on.to_date)
    return false if hire_date.present? && date < hire_date

    event = employee_status_events.where("effective_date <= ?", date).order(effective_date: :desc, id: :desc).first
    return event.resulting_status == "active" if event

    first_event = employee_status_events.order(:effective_date, :id).first
    return false if first_event&.previous_status == "inactive"

    (first_event&.previous_status == "active" || status != "inactive") && (termination_date.blank? || date <= termination_date)
  end

  def work_profile_on(date)
    employee_work_profiles.effective_on(date).first
  end

  def w4_election_on(date)
    date = date.to_date
    if association(:employee_w4_elections).loaded?
      employee_w4_elections
        .select { |election| election.effective_on <= date && (election.w4_signed_on.nil? || election.w4_signed_on <= date) }
        .max_by { |election| [ election.effective_on, election.created_at, election.id ] }
    else
      employee_w4_elections.effective_on(date).where("w4_signed_on IS NULL OR w4_signed_on <= ?", date).first
    end
  end

  def hourly?
    employment_type == "hourly"
  end

  def salary?
    employment_type == "salary"
  end

  def variable_salary?
    salary? && salary_type == "variable"
  end

  def contractor?
    employment_type == "contractor"
  end

  def w2_employee?
    hourly? || salary?
  end

  def tax_classification
    contractor? ? "1099" : "w2"
  end

  def contractor_hourly?
    contractor? && contractor_pay_type == "hourly"
  end

  def contractor_flat_fee?
    contractor? && contractor_pay_type == "flat_fee"
  end

  def business_contractor?
    contractor? && contractor_type == "business"
  end

  def individual_filer?
    !business_contractor?
  end

  def normalized_filing_status
    FilingStatusConfig.normalize(filing_status)
  end

  def supported_w4_form_version?
    w4_form_version.to_i >= MIN_SUPPORTED_W4_FORM_VERSION
  end

  # The TIN a 1099-NEC prints, as { type: "SSN" | "EIN", digits: "123456789" },
  # or nil when there is no valid one: a business contractor's EIN, otherwise
  # the SSN, otherwise an EIN (a sole proprietor may give either).
  def form_1099_tin
    ein = contractor_ein.to_s.gsub(/\D/, "")
    return { type: "EIN", digits: ein } if business_contractor? && ein.length == 9
    return { type: "SSN", digits: ssn_digits } if valid_filing_ssn?
    return { type: "EIN", digits: ein } if ein.length == 9

    nil
  end

  # TIN for 1099-NEC: EIN for business entities, SSN for individuals
  def tax_identification_number
    contractor? && contractor_type == "business" && contractor_ein.present? ? contractor_ein : ssn_encrypted
  end

  # Get YTD totals for a given year
  def ytd_totals_for(year)
    employee_ytd_totals.find_or_create_by(year: year)
  end

  def cache_ytd_values!(year:, as_of_pay_date:, before_pay_period_id:, totals:)
    normalized_totals = YTD_AGGREGATE_SOURCE_COLUMNS.keys.each_with_object({}) do |key, acc|
      acc[key] = totals[key].to_f
    end

    @cached_ytd_before_totals = normalized_totals
    @cached_ytd_gross = normalized_totals[:gross_pay]
    @cached_ytd_social_security = normalized_totals[:social_security_tax]
    @cached_ytd_year = year
    @cached_ytd_as_of_pay_date = as_of_pay_date
    @cached_ytd_before_pay_period_id = before_pay_period_id
  end

  def cached_ytd_snapshot
    {
      gross: defined?(@cached_ytd_gross) ? @cached_ytd_gross : nil,
      social_security: defined?(@cached_ytd_social_security) ? @cached_ytd_social_security : nil,
      before_totals: defined?(@cached_ytd_before_totals) ? @cached_ytd_before_totals&.dup : nil,
      year: defined?(@cached_ytd_year) ? @cached_ytd_year : nil,
      as_of_pay_date: defined?(@cached_ytd_as_of_pay_date) ? @cached_ytd_as_of_pay_date : nil,
      before_pay_period_id: defined?(@cached_ytd_before_pay_period_id) ? @cached_ytd_before_pay_period_id : nil
    }
  end

  def restore_cached_ytd_snapshot!(snapshot)
    restore_cached_ytd_ivar(:@cached_ytd_gross, snapshot[:gross])
    restore_cached_ytd_ivar(:@cached_ytd_social_security, snapshot[:social_security])
    restore_cached_ytd_ivar(:@cached_ytd_before_totals, snapshot[:before_totals])
    restore_cached_ytd_ivar(:@cached_ytd_year, snapshot[:year])
    restore_cached_ytd_ivar(:@cached_ytd_as_of_pay_date, snapshot[:as_of_pay_date])
    restore_cached_ytd_ivar(:@cached_ytd_before_pay_period_id, snapshot[:before_pay_period_id])
  end

  def ytd_totals_before(year:, pay_date:, pay_period_id:, for_reporting: false)
    # Display reads must neither consume nor populate the strict calculation
    # cache, including values restored around a calculation preview.
    if !for_reporting && cached_ytd_matches?(year, pay_date, pay_period_id) &&
       defined?(@cached_ytd_before_totals) && @cached_ytd_before_totals.present?
      return @cached_ytd_before_totals.dup
    end

    ytd_aggregate_totals(
      year: year,
      pay_date: pay_date,
      pay_period_id: pay_period_id,
      include_current_period: false,
      for_reporting: for_reporting
    )
  end

  def ytd_totals_through(year:, pay_date:, pay_period_id:)
    # This intentionally bypasses the pre-period cache because "through"
    # totals are used for display/rendering and must include the current
    # pay period's own row in the aggregate window.
    ytd_aggregate_totals(
      year: year,
      pay_date: pay_date,
      pay_period_id: pay_period_id,
      include_current_period: true,
      for_reporting: true
    )
  end

  def ytd_totals_for_scope(scope, tax_year:, for_reporting: false, historical_balance: :latest)
    columns = self.class.ytd_aggregate_columns_for_year(tax_year)
    select_list = columns.map { |key, sql| "#{sql} AS #{key}" }.join(", ")
    row = self.class.connection.select_one(scope.reselect(Arel.sql(select_list)).to_sql) || {}

    live_totals = columns.keys.each_with_object({}) do |key, totals|
      totals[key] = row[key.to_s].to_f
    end
    live_totals.merge!(PayrollRetirementTotals.for_scope(scope, for_reporting: for_reporting))
    return merge_historical_ytd(live_totals, tax_year) if historical_balance == :latest

    merge_historical_ytd(live_totals, tax_year, historical_balance: historical_balance, preloaded: true)
  end

  # Calculate YTD gross from payroll items.
  # Returns the precomputed cache when set by batch operations (e.g. run_payroll).
  def calculate_ytd_gross(year, as_of_pay_date: nil, before_pay_period_id: nil)
    if cached_ytd_matches?(year, as_of_pay_date, before_pay_period_id) &&
       defined?(@cached_ytd_gross) && !@cached_ytd_gross.nil?
      return @cached_ytd_gross
    end

    if as_of_pay_date.present? && before_pay_period_id.present?
      return ytd_totals_before(year: year, pay_date: as_of_pay_date, pay_period_id: before_pay_period_id)[:gross_pay]
    end

    live_total = payroll_items
      .joins(:pay_period)
      .financially_reportable
      .where(pay_periods: {
        id: PayPeriod.reportable_for_company(company)
          .where(pay_date: pay_date_range_for_year(year))
          .select(:id)
      })
      .sum(:gross_pay)
    live_total + historical_ytd_value(year, :gross_pay)
  end

  # Calculate YTD Social Security tax withheld.
  # Returns the precomputed cache when set by batch operations.
  def calculate_ytd_social_security(year, as_of_pay_date: nil, before_pay_period_id: nil)
    if cached_ytd_matches?(year, as_of_pay_date, before_pay_period_id) &&
       defined?(@cached_ytd_social_security) && !@cached_ytd_social_security.nil?
      return @cached_ytd_social_security
    end

    if as_of_pay_date.present? && before_pay_period_id.present?
      return ytd_totals_before(year: year, pay_date: as_of_pay_date, pay_period_id: before_pay_period_id)[:social_security_tax]
    end

    live_total = payroll_items
      .joins(:pay_period)
      .financially_reportable
      .where(pay_periods: {
        id: PayPeriod.reportable_for_company(company)
          .where(pay_date: pay_date_range_for_year(year))
          .select(:id)
      })
      .sum(:social_security_tax)
    live_total + historical_ytd_value(year, :social_security_tax)
  end

  # Returns last 4 digits of SSN for display purposes
  def ssn_digits
    return nil if ssn_encrypted.blank?

    ssn_encrypted.to_s.gsub(/\D/, "").presence
  end

  def ssn_last_four
    ssn_digits&.last(4)
  end

  def valid_filing_ssn?
    ssn_digits&.length == 9
  end

  def merge_historical_ytd(live_totals, year, historical_balance: nil, preloaded: false)
    balance = preloaded ? historical_balance : applied_historical_ytd_balance(year)
    return live_totals unless balance
    raise ArgumentError, "historical balance tax year does not match" if balance.tax_year != year

    historical = balance.ytd_aggregate_totals.merge(
      HistoricalRetirementProjection.new(employee: self, tax_year: year, balance: balance).totals.slice(:retirement, :roth_retirement)
    )
    live_totals.each_with_object({}) do |(key, value), totals|
      totals[key] = value.to_f + historical.fetch(key, 0).to_f
    end
  end

  private

  def apply_employee_app_email_change
    EmployeeLinks::EmailChange.call(employee: self, from: email_before_last_save, to: email)
  end

  # A demo company's direct deposits are simulated: its routing numbers must
  # fail the ABA checksum, so no real bank account can ever be stored.
  def demo_bank_details_are_fictional
    return unless AbaRoutingNumber.valid_checksum?(bank_routing_number_encrypted)

    errors.add(:bank_routing_number_encrypted, "isn't available for this client")
  end

  # Contractor checks pay a real outside party, so a demo has no contractors.
  def demo_has_no_contractors
    errors.add(:employment_type, "isn't available for this client")
  end

  def test_workspace_source_employee_is_valid
    return if test_workspace_source_employee.blank?
    return if company&.test_workspace? &&
      test_workspace_source_employee.company_id == company.migration_source_company_id

    errors.add(:test_workspace_source_employee, "must belong to the test workspace's source client")
  end

  SOURCE_FIELD_CONFIGURATION_REVIEW_CODES = %w[
    verify_hire_date quickbooks_nevada_address_suppressed employee_address_missing
  ].freeze

  def normalize_w4_source_reference
    self.w4_source_reference = w4_source_reference.to_s.strip.presence
  end

  def normalize_intake_blank_details
    return if intake_exception.blank?

    %w[ssn_encrypted contractor_ein address_line1 city state zip].each do |attribute|
      self[attribute] = nil if self[attribute].blank?
    end
  end

  def plausible_hire_date
    if hire_date.blank?
      errors.add(:hire_date, "must be a valid date") if hire_date_before_type_cast.present?
      return
    end

    errors.add(:hire_date, "must have a year between 1900 and next year") unless hire_date.year.between?(1900, Date.current.year + 1)
  end

  def configuration_review_items_are_valid
    unless configuration_review_items.is_a?(Array)
      errors.add(:configuration_review_items, "must be a list")
      return
    end

    invalid = configuration_review_items.reject do |item|
      item.is_a?(Hash) && item["code"].present? && item["message"].present? && item["fields"].is_a?(Array)
    end
    errors.add(:configuration_review_items, "contains an invalid review item") if invalid.any?
  end

  def tax_classification_cannot_change_in_place
    return unless will_save_change_to_employment_type?
    return if ActiveModel::Type::Boolean.new.cast(allow_tax_classification_change)

    prior_type = employment_type_in_database
    return if prior_type.blank?
    return if (prior_type == "contractor") == contractor?

    errors.add(
      :employment_type,
      "cannot change between W-2 and 1099 in place; create a new worker record"
    )
  end

  def previous_employee_transition_is_valid
    return if previous_employee.blank?

    errors.add(:previous_employee, "must belong to the same company") if previous_employee.company_id != company_id
    errors.add(:previous_employee, "cannot reference itself") if persisted? && previous_employee_id == id
    if previous_employee.tax_classification == tax_classification
      errors.add(:previous_employee, "must use the opposite W-2/1099 classification")
    end
  end

  def new_filing_profile?
    new_record? && !intake_original_employee&.persisted?
  end

  def filing_field_presence_required?(field)
    baseline = intake_original_employee || self
    new_filing_profile? || baseline.attribute_in_database(field).present?
  end

  def required_filing_fields
    {
      hire_date: hire_date,
      address_line1: address_line1,
      city: city,
      state: state,
      zip: zip
    }.each do |field, value|
      errors.add(field, "can't be blank") if filing_field_presence_required?(field) && value.blank? &&
        !(new_filing_profile? && configuration_review_allows_blank?(field)) && !intake_allows_blank?(field)
    end

    if business_contractor?
      errors.add(:business_name, "can't be blank") if business_name.blank?
      errors.add(:contractor_ein, "can't be blank") if contractor_ein.blank? && !intake_allows_blank?(:contractor_ein)
    elsif filing_field_presence_required?(:ssn_encrypted) && ssn_encrypted.blank? && !intake_allows_blank?(:ssn)
      errors.add(:ssn, "can't be blank")
    end
  end

  def filing_data_validation_required?
    return false if portal_pending_approval?
    return true if new_record?

    (changes_to_save.keys - %w[status termination_date updated_at]).any?
  end

  def valid_supplied_intake_dates
    if require_initial_w4_effective_on && w2_employee? && w4_effective_on.blank?
      errors.add(:w4_effective_on, "is required unless incomplete employee entry is enabled")
    end
    if intake_exception.present? && !new_record? && w4_effective_on.blank? && w4_effective_on_in_database.present?
      errors.add(:w4_effective_on, "cannot clear a completed withholding effective date")
    end
    %w[date_of_birth hire_date w4_effective_on w4_signed_on].each do |field|
      if public_send(field).blank? && public_send("#{field}_before_type_cast").present?
        errors.add(field, "must be a valid date")
      end
    end
  end

  def intake_allows_blank?(field)
    return false unless Array(intake_exception["deferred_fields"]).include?(field.to_s)
    attribute = field.to_s == "ssn" ? "ssn_encrypted" : field.to_s
    baseline = intake_original_employee || self
    baseline.new_record? || baseline.attribute_in_database(attribute).blank?
  end

  def invalidate_intake_payroll_confirmation
    return if intake_exception.blank? || will_save_change_to_intake_payroll_confirmed_at?
    sensitive = %w[employment_type salary_type contractor_type contractor_pay_type pay_rate pay_frequency hire_date ssn_encrypted contractor_ein] + EmployeeW4Election::PROFILE_ATTRIBUTES.map(&:to_s)
    self.intake_payroll_confirmed_at = nil if (changes_to_save.keys & sensitive).any?
  end

  def clear_verification_on_contact_change
    if email.blank?
      self.email_verified_at = nil
    elsif will_save_change_to_email? && !will_save_change_to_email_verified_at?
      old_email, new_email = changes_to_save["email"]
      if EmployeeContactValidator.normalize_email(old_email) != EmployeeContactValidator.normalize_email(new_email)
        self.email_verified_at = nil
      end
    end

    if phone.blank?
      self.phone_confirmed_by_employee_at = nil
    elsif will_save_change_to_phone? && !will_save_change_to_phone_confirmed_by_employee_at?
      old_phone, new_phone = changes_to_save["phone"]
      normalized_old, = EmployeeContactValidator.normalize_phone(old_phone)
      normalized_new, new_error = EmployeeContactValidator.normalize_phone(new_phone)
      if new_error.present? || (normalized_old || old_phone.to_s.strip.presence) != normalized_new
        self.phone_confirmed_by_employee_at = nil
      end
    end
  end

  def configuration_review_allows_blank?(field)
    return false unless configuration_source == "quickbooks_history" && configuration_review_status == "needs_review"

    Array(configuration_review_items).any? do |item|
      next false unless item.is_a?(Hash)
      next false unless SOURCE_FIELD_CONFIGURATION_REVIEW_CODES.include?(item["code"])

      Array(item["fields"]).include?(field.to_s)
    end
  end

  def portal_pending_employee_is_inactive
    return unless portal_pending_approval?
    return if status == "inactive"

    errors.add(:status, "must be inactive while client-submitted payroll details await approval")
  end

  def filing_ssn_format
    return if ssn_encrypted.blank?
    return if valid_filing_ssn?

    errors.add(:ssn, "must contain exactly 9 digits")
  end

  def filing_ssn_required?
    individual_filer?
  end

  def business_ein_format
    return if contractor_ein.blank?
    return if contractor_ein.to_s.gsub(/\D/, "").length == 9

    errors.add(:contractor_ein, "must contain exactly 9 digits")
  end

  def ssn_confirmation_required?
    ActiveModel::Type::Boolean.new.cast(require_ssn_confirmation) && individual_filer? && ssn_encrypted.present?
  end

  def matching_ssn_confirmation
    if ssn_confirmation.blank?
      errors.add(:ssn_confirmation, "can't be blank")
    elsif ssn_digits != ssn_confirmation.to_s.gsub(/\D/, "")
      errors.add(:ssn_confirmation, "does not match Social Security Number")
    end
  end

  def normalize_filing_status_value
    self.filing_status = normalized_filing_status if filing_status.present?
  end

  def normalize_default_payroll_adjustments
    self.default_payroll_adjustments = self.class.normalize_payroll_adjustments(default_payroll_adjustments)
  end

  def cached_ytd_matches?(year, as_of_pay_date, before_pay_period_id)
    if as_of_pay_date.nil? && before_pay_period_id.nil?
      return !defined?(@cached_ytd_year) || @cached_ytd_year.nil? || @cached_ytd_year == year
    end

    defined?(@cached_ytd_year) &&
      @cached_ytd_year == year &&
      defined?(@cached_ytd_as_of_pay_date) &&
      @cached_ytd_as_of_pay_date == as_of_pay_date &&
      defined?(@cached_ytd_before_pay_period_id) &&
      @cached_ytd_before_pay_period_id == before_pay_period_id
  end

  def restore_cached_ytd_ivar(name, value)
    if value.nil?
      remove_instance_variable(name) if instance_variable_defined?(name)
    else
      instance_variable_set(name, value)
    end
  end

  def ytd_aggregate_totals(year:, pay_date:, pay_period_id:, include_current_period:, for_reporting:)
    scope = payroll_items
      .joins(:pay_period)
      .financially_reportable
      .where(pay_periods: {
        id: PayPeriod.reportable_for_company(company)
          .where(pay_date: pay_date_range_for_year(year))
          .select(:id)
      })

    comparator = include_current_period ? "<=" : "<"
    scope = scope.where(
      "(pay_periods.pay_date < ?) OR (pay_periods.pay_date = ? AND pay_periods.id #{comparator} ?)",
      pay_date, pay_date, pay_period_id
    )
    return ytd_totals_for_scope(scope, tax_year: year) unless for_reporting

    # Statements report the same population as their YTD breakdowns: no
    # legacy-disposed rows, only an opening balance already paid by this date,
    # and live pay inside that balance only once recorded as a distinct
    # payment (PayrollBridgeOverlap). Payroll calculation keeps the
    # unfiltered totals.
    balance = reportable_historical_ytd_balance(year, pay_date)
    scope = scope.reportable
    if balance
      distinct = PayrollBridgeOverlap.distinct_item_ids(company_id: company_id, batch_id: balance.historical_ytd_bridge.historical_import_batch_id)
      scope = scope.where("pay_periods.pay_date > ? OR payroll_items.id IN (?)", balance.through_pay_date, distinct)
    end
    ytd_totals_for_scope(scope, tax_year: year, for_reporting: true, historical_balance: balance)
  end

  def historical_ytd_value(year, field)
    balance = applied_historical_ytd_balance(year)
    return 0.to_d unless balance

    balance.public_send(field).to_d
  end

  def applied_historical_ytd_balance(year)
    historical_employee_ytd_balances
      .joins(:historical_ytd_bridge)
      .where(tax_year: year, historical_ytd_bridges: { status: "applied" })
      .order(
        through_pay_date: :desc,
        "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc,
        id: :desc
      )
      .first
  end

  # The opening balance a statement paid on pay_date reports: the latest
  # applied bridge balance dated on or before it, as the statement breakdowns use.
  def reportable_historical_ytd_balance(year, pay_date)
    historical_employee_ytd_balances
      .joins(:historical_ytd_bridge)
      .where(tax_year: year, historical_ytd_bridges: { status: "applied" })
      .where("historical_employee_ytd_balances.through_pay_date <= ?", pay_date)
      .order(
        through_pay_date: :desc,
        "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc,
        id: :desc
      )
      .first
  end

  def pay_date_range_for_year(year)
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def compensation_change_timeline
    employee_compensation_changes.to_a.sort_by { |change| [ change.effective_on, change.id ] }
  end

  def wage_rate_versions_by_row
    employee_wage_rate_versions.to_a.sort_by { |version| [ version.effective_on, version.id ] }.group_by(&:employee_wage_rate_id)
  end

  def guard_compensation_mutation
    return if (changes_to_save.keys & EmployeeCompensationChangeService::COMPENSATION_ATTRIBUTES).empty?
    return if EmployeeCompensationChangeService.writing?(id)

    raise EmployeeCompensationChangeService::CompensationMutationError,
          "Change pay rates through EmployeeCompensationChangeService so the effective date and history are recorded"
  end

  def record_initial_compensation_history
    actor = initial_compensation_actor || Current.user || Current.actor || created_by ||
      AuditActor.operator("Employee initial pay setup")
    EmployeeCompensationChangeService.record_initial!(self, actor: actor, source: initial_compensation_source)
  end

  def normalize_pay_rate_precision
    self.pay_rate = round_currency_value(pay_rate)
  end

  def normalize_w4_currency_precision
    self.additional_withholding = round_currency_value(additional_withholding)
    self.w4_dependent_credit = round_currency_value(w4_dependent_credit)
    self.w4_step4a_other_income = round_currency_value(w4_step4a_other_income)
    self.w4_step4b_deductions = round_currency_value(w4_step4b_deductions)
  end

  def round_currency_value(value)
    return value if value.nil?

    BigDecimal(value.to_s).round(2)
  end
end
