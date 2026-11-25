# frozen_string_literal: true

require "set"

class Company < ApplicationRecord
  validates :kind_of_employer, inclusion: { in: %w[N F S T Y] }
  validates :employment_code, inclusion: { in: %w[R F A M] }
  validates :establishment_number, length: { maximum: 4 }, format: { with: /\A[ -~]*\z/ }, allow_blank: true
  include TracksRecordCreation

  belongs_to :created_by, class_name: "User", optional: true
  CHECK_STOCK_TYPES = %w[bottom_check top_check first_hawaiian_4up].freeze
  PAYROLL_INTAKE_SOURCE_TYPES = %w[spike_email mosa_revel].freeze
  PAYROLL_ENVIRONMENTS = %w[live migration_rehearsal].freeze
  MIGRATION_REHEARSAL_STATUSES = %w[pending ready failed].freeze
  TEST_WORKSPACE_PURPOSES = %w[sandbox migration_rehearsal training_replay backup_snapshot demo].freeze
  TEST_WORKSPACE_PURPOSE_LABELS = {
    "sandbox" => "General test workspace",
    "migration_rehearsal" => "Migration rehearsal",
    "training_replay" => "Training replay",
    "backup_snapshot" => "Backup snapshot",
    "demo" => "Demo company"
  }.freeze
  # Shown wherever a demo company refuses an action a live client could take
  # (filing transmission, payments, firm billing). It reads like an ordinary
  # unavailable state so the demo never announces itself to clients or staff.
  DEMO_UNAVAILABLE_MESSAGE = "This option isn't available for this client yet."
  DEMO_ACCESS_DENIED_MESSAGE = "Your access does not allow this action for this client."
  # Mirrors the database check on a demo's fixture key.
  DEMO_FIXTURE_KEY_PATTERN = /\A[a-z0-9][a-z0-9-]{2,62}\z/

  before_destroy :protect_retained_portal_documents, prepend: true

  def protect_retained_portal_documents
    return unless client_documents.any?(&:retained_evidence?)

    errors.add(:base, "This company has retained portal files and cannot be deleted. Archive its files instead.")
    throw :abort
  end

  belongs_to :organization
  belongs_to :active_printer_profile, class_name: "PrinterProfile", optional: true
  belongs_to :migration_source_company, class_name: "Company", optional: true
  belongs_to :migration_source_batch, class_name: "HistoricalImportBatch", optional: true
  belongs_to :migration_rehearsal_created_by, class_name: "User", optional: true

  has_many :migration_rehearsals,
           -> { where(test_workspace_purpose: "migration_rehearsal") },
           class_name: "Company",
           foreign_key: :migration_source_company_id,
           inverse_of: :migration_source_company,
           dependent: :restrict_with_error
  has_many :test_workspaces,
           class_name: "Company",
           foreign_key: :migration_source_company_id,
           inverse_of: :migration_source_company,
           dependent: :restrict_with_error

  has_many :departments, dependent: :destroy
  has_many :company_assignments, dependent: :destroy
  before_destroy :purge_test_workspace_compensation_history, if: :test_workspace?, prepend: true
  has_many :employees, dependent: :destroy
  has_many :time_tracking_sources, dependent: :destroy
  has_many :time_tracking_delegations, dependent: :destroy
  has_many :aire_payroll_calendar_periods, dependent: :restrict_with_error
  has_many :pay_periods, dependent: :destroy
  has_many :company_pay_schedules, dependent: :restrict_with_error
  has_many :company_workweeks, dependent: :restrict_with_error
  has_many :client_operating_profiles, dependent: :restrict_with_error
  has_many :employee_work_profiles, dependent: :restrict_with_error
  has_many :employee_status_events, dependent: :restrict_with_error
  has_many :daily_time_records, dependent: :restrict_with_error
  has_many :payroll_time_allocations, dependent: :restrict_with_error
  has_many :payroll_items, dependent: :restrict_with_error
  has_many :payroll_field_definitions, dependent: :destroy
  has_many :deduction_types, dependent: :destroy
  has_many :company_ytd_totals, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :user_invitations, dependent: :destroy
  has_many :non_employee_checks, dependent: :destroy
  has_many :check_print_runs, dependent: :restrict_with_error
  has_many :check_print_generations, dependent: :restrict_with_error
  has_many :training_replay_benchmarks, dependent: :restrict_with_error
  has_many :check_reconciliation_events, dependent: :restrict_with_error
  has_many :general_transmittals, dependent: :destroy
  has_many :general_transmittal_artifacts, dependent: :restrict_with_error
  has_many :invoice_recipients, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :invoice_chat_sessions, dependent: :destroy
  has_many :employee_loans, dependent: :destroy
  has_many :employee_w4_elections, dependent: :restrict_with_error
  has_many :client_documents, dependent: :destroy
  # Deleting events cascades their delivery rows in the database.
  has_many :portal_notification_events, dependent: :delete_all
  has_many :portal_notification_recipients, dependent: :delete_all
  has_many :employee_document_requirements, dependent: :restrict_with_error
  has_many :employee_document_requirement_events, dependent: :restrict_with_error
  has_many :employee_notes, dependent: :restrict_with_error
  has_many :employee_change_requests, dependent: :destroy
  has_many :form500_filings, dependent: :destroy
  has_many :pay_component_tax_rules, dependent: :restrict_with_error
  has_many :payroll_liability_postings, dependent: :restrict_with_error
  has_many :payroll_liability_entries, dependent: :restrict_with_error
  has_many :payroll_liability_check_allocations, dependent: :restrict_with_error
  has_many :payroll_liability_obligation_due_dates, dependent: :restrict_with_error
  has_many :quarterly_compliance_packets, dependent: :destroy
  has_many :payroll_filing_responsibilities, dependent: :restrict_with_error
  has_many :year_end_acknowledgements, dependent: :restrict_with_error
  has_many :payroll_filing_records, dependent: :restrict_with_error
  has_many :historical_import_batches, dependent: :restrict_with_error
  has_one :prior_provider_history_draft, dependent: :delete
  has_many :historical_import_source_files, dependent: :restrict_with_error
  has_many :historical_workers, dependent: :restrict_with_error
  has_many :historical_pay_periods, dependent: :restrict_with_error
  has_many :historical_paychecks, dependent: :restrict_with_error
  has_many :historical_client_bootstraps, dependent: :restrict_with_error
  has_many :historical_tax_wage_reports, dependent: :restrict_with_error
  has_many :historical_ytd_bridges, dependent: :restrict_with_error
  has_many :historical_employee_ytd_balances, dependent: :restrict_with_error
  has_many :employee_configuration_review_resolutions, dependent: :restrict_with_error
  has_one :payroll_go_live_review, dependent: :restrict_with_error
  has_many :source_payroll_go_live_reviews,
           class_name: "PayrollGoLiveReview",
           foreign_key: :source_company_id,
           inverse_of: :source_company,
           dependent: :restrict_with_error
  has_many :payroll_parallel_run_reviews, dependent: :restrict_with_error
  has_one :payroll_reminder_config, dependent: :destroy
  has_many :payroll_reminder_logs, dependent: :destroy
  has_many :help_contacts, -> { order(:position) }, class_name: "CompanyHelpContact", inverse_of: :company, dependent: :delete_all
  # Printer profiles are organization-scoped so every operator in the same
  # accounting firm can share the same physical printer calibration.

  before_validation :normalize_blanks
  before_validation :default_test_workspace_purpose

  validates :name, presence: true
  validates :subdomain_slug,
            format: { with: TenantSubdomainRegistry::SLUG_PATTERN },
            exclusion: { in: TenantSubdomainRegistry::RESERVED_SLUGS },
            uniqueness: { case_sensitive: false, conditions: -> { where("companies.payroll_environment = 'live' OR companies.test_workspace_purpose = 'demo'") } },
            allow_nil: true
  validate :subdomain_slug_change_requires_disabled_profile, if: -> { persisted? && will_save_change_to_subdomain_slug? }
  validate :valid_public_branding
  after_commit { TenantSubdomainRegistry.invalidate! }

  validate :subdomain_requires_live_payroll, if: -> { !subdomain_slug.nil? && !live_payroll? }
  validates :ein, uniqueness: { conditions: -> { where(payroll_environment: "live") } }, allow_blank: true, unless: :test_workspace?
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :payroll_environment, inclusion: { in: PAYROLL_ENVIRONMENTS }
  validates :migration_rehearsal_status, inclusion: { in: MIGRATION_REHEARSAL_STATUSES }, allow_nil: true
  validates :test_workspace_purpose, inclusion: { in: TEST_WORKSPACE_PURPOSES }, allow_nil: true
  validates :migration_source_company, presence: true, if: :practice_copy?
  validates :migration_rehearsal_status, presence: true, if: :test_workspace?
  validate :test_workspace_source_is_valid
  validate :demo_shape_is_permanent, if: :demo?
  validate :demo_outputs_stay_simulated, if: :demo?
  validate :company_type_is_unchanged, on: :update
  validates :check_stock_type, inclusion: { in: CHECK_STOCK_TYPES }
  validates :check_offset_x, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :check_offset_y, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validate :check_layout_config_must_be_hash
  validate :payroll_intake_source_types_are_supported
  validate :payroll_intake_settings_are_supported

  scope :active, -> { where(active: true) }
  scope :live_payroll, -> { where(payroll_environment: "live") }
  scope :migration_rehearsal, -> { where(payroll_environment: "migration_rehearsal") }
  scope :test_workspace, -> { where(payroll_environment: "migration_rehearsal") }
  scope :demo, -> { test_workspace.where(test_workspace_purpose: "demo") }
  scope :not_demo, -> { where(test_workspace_purpose: nil).or(where.not(test_workspace_purpose: "demo")) }

  def test_workspace?
    payroll_environment == "migration_rehearsal"
  end

  def migration_rehearsal?
    test_workspace? && test_workspace_purpose.in?([ nil, "migration_rehearsal" ])
  end

  def live_payroll?
    payroll_environment == "live"
  end

  def training_replay?
    test_workspace? && test_workspace_purpose == "training_replay"
  end

  def sandbox?
    test_workspace? && test_workspace_purpose == "sandbox"
  end

  def backup_snapshot?
    test_workspace? && test_workspace_purpose == "backup_snapshot"
  end

  # A permanent, source-free company for staff training and client demos. It
  # is a test workspace for containment (filings, payments, integrations and
  # firm totals stay closed) but presents and behaves like a live client.
  def demo?
    test_workspace? && test_workspace_purpose == "demo"
  end

  # A copied or replayed workspace that is visibly labelled as practice: every
  # test workspace except a demo. Use this, not test_workspace?, for labels,
  # practice stamps, expiry/read-only rules and source lineage.
  def practice_copy?
    test_workspace? && !demo?
  end

  def test_workspace_ready?
    test_workspace? && migration_rehearsal_status == "ready" && test_workspace_archived_at.nil?
  end

  def test_workspace_expired?
    test_workspace? && test_workspace_expires_at.present? && test_workspace_expires_at <= Time.current
  end

  def test_workspace_read_only?
    backup_snapshot? || test_workspace_sealed_at.present? || test_workspace_archived_at.present? || test_workspace_expired?
  end

  def test_workspace_purpose_label
    return unless practice_copy?

    TEST_WORKSPACE_PURPOSE_LABELS.fetch(test_workspace_purpose, "Test workspace")
  end

  # ---------------------------------------------------------------------------
  # Check number sequencing — thread-safe via row-level lock
  # ---------------------------------------------------------------------------

  # Assign check numbers to a set of payroll_items (unsaved or without check #).
  # All assignments happen inside a single locked transaction — no collisions.
  # @param items [ActiveRecord::Relation or Array<PayrollItem>] items needing a check #
  # @return [Integer] the number of check numbers assigned
  def assign_check_numbers!(items)
    items = items.to_a
    return 0 if items.empty?
    if items.any? { |item| item.effective_payment_delivery_method == "direct_deposit" }
      raise ArgumentError, "Direct-deposit payments cannot receive paper check numbers"
    end

    assigned = 0
    self.class.transaction do
      lock!  # SELECT … FOR UPDATE on this company row
      next_number = next_check_number
      window_size = [ items.size * 2, 100 ].max
      window_end = next_number + window_size - 1
      issued_numbers = issued_check_numbers_in_range(next_number, window_end)
      assignments = {}

      items.each do |item|
        while issued_numbers.include?(next_number.to_s)
          next_number += 1
          if next_number > window_end
            window_end = next_number + window_size - 1
            issued_numbers.merge(issued_check_numbers_in_range(next_number, window_end))
          end
        end
        check_number = next_number.to_s
        assignments[item.id] = check_number
        issued_numbers.add(check_number)
        next_number += 1
      end

      timestamp = Time.current
      rows = items.map do |item|
        {
          id: item.id,
          company_id: item.company_id,
          employee_id: item.employee_id,
          employment_type: item.employment_type,
          pay_period_id: item.pay_period_id,
          pay_rate: item.pay_rate,
          created_at: item.created_at,
          updated_at: timestamp,
          check_number: assignments.fetch(item.id)
        }
      end
      PayrollItem.upsert_all(
        rows,
        unique_by: :id,
        update_only: [ :check_number, :updated_at ],
        record_timestamps: false
      )

      assigned = items.size
      update_column(:next_check_number, next_number)
    end
    assigned
  rescue ActiveRecord::StatementInvalid => e
    if e.message.include?("index_payroll_items_on_check_number") ||
       e.message.include?("index_payroll_items_on_company_check_number") ||
       e.message.downcase.include?("unique")
      raise ArgumentError, "Check number collision detected while assigning checks. Please verify company check settings and retry."
    end
    raise
  end

  # Reserve exactly one check number (for reprint flow).
  # @return [String] the newly reserved check number string
  def next_check_number!
    reserved = nil
    self.class.transaction do
      lock!
      next_number = next_check_number
      window_size = 100
      window_end = next_number + window_size - 1
      issued_numbers = issued_check_numbers_in_range(next_number, window_end)

      while issued_numbers.include?(next_number.to_s)
        next_number += 1
        if next_number > window_end
          window_end = next_number + window_size - 1
          issued_numbers.merge(issued_check_numbers_in_range(next_number, window_end))
        end
      end

      reserved = next_number.to_s
      update_column(:next_check_number, next_number + 1)
    end
    reserved
  end

  def full_address
    [ address_line1, address_line2, "#{city}, #{state} #{zip}" ].compact_blank.join("\n")
  end

  def first_hawaiian_4up_checks?
    check_stock_type == "first_hawaiian_4up"
  end

  def payroll_intake_source_enabled?(source_type)
    payroll_intake_source_types.include?(source_type.to_s)
  end

  # Source files that make a complete intake package for this client. A
  # client-specific list replaces the source's default; an empty list means
  # any single file can be applied.
  def payroll_intake_required_sources(source_type)
    configured = payroll_intake_settings.to_h.dig(source_type.to_s, "required_sources")
    return PayrollIntake::SourceCompleteness.default_required_roles(source_type) if configured.nil?

    Array(configured).map(&:to_s)
  end

  BRAND_LOGO_EXTENSIONS = { "image/png" => "png", "image/webp" => "webp" }.freeze

  # The first 16 hex characters of the uploaded logo's SHA-256. Public logo
  # URLs carry it, so a replaced logo gets a new address.
  def brand_logo_digest
    brand_logo_sha256&.first(16) if brand_logo_storage_key.present?
  end

  def brand_logo_extension
    BRAND_LOGO_EXTENSIONS[brand_logo_content_type]
  end

  private

  def normalize_blanks
    self.ein = nil if ein.blank?
    self.payroll_intake_source_types = Array(payroll_intake_source_types).compact_blank.map(&:to_s).uniq
  end

  def default_test_workspace_purpose
    self.test_workspace_purpose ||= "migration_rehearsal" if test_workspace?
  end

  def check_layout_config_must_be_hash
    return if check_layout_config.is_a?(Hash)

    errors.add(:check_layout_config, "must be a JSON object")
  end

  def payroll_intake_source_types_are_supported
    unsupported = Array(payroll_intake_source_types) - PAYROLL_INTAKE_SOURCE_TYPES
    return if unsupported.empty?

    errors.add(:payroll_intake_source_types, "contains unsupported source type(s): #{unsupported.join(', ')}")
  end

  def payroll_intake_settings_are_supported
    unless payroll_intake_settings.is_a?(Hash)
      errors.add(:payroll_intake_settings, "must be a JSON object")
      return
    end

    payroll_intake_settings.each do |source_type, settings|
      unless PAYROLL_INTAKE_SOURCE_TYPES.include?(source_type.to_s) && settings.is_a?(Hash)
        errors.add(:payroll_intake_settings, "contains an unsupported source type: #{source_type}")
        next
      end
      next unless settings.key?("required_sources")

      required = settings["required_sources"]
      unknown = Array(required).map(&:to_s) - PayrollIntake::SourceCompleteness.roles_for(source_type).keys
      next if required.is_a?(Array) && unknown.empty?

      errors.add(:payroll_intake_settings, "lists unknown #{source_type} source files: #{Array(required).join(', ')}")
    end
  end

  def subdomain_slug_change_requires_disabled_profile
    profile = ClientOperatingProfile.for_date(id)
    if profile&.option_value("subdomain_enabled") == true
      errors.add(:subdomain_slug, "cannot change while the current operating profile enables the subdomain")
    end
  end

  def valid_public_branding
    unless branding.is_a?(Hash)
      errors.add(:branding, "must be an object")
      return
    end

    values = branding.stringify_keys
    if (values.keys - TenantSubdomainRegistry::BRANDING_KEYS).any?
      errors.add(:branding, "has unsupported keys")
    end
    if values["logo_url"] != nil && !TenantSubdomainRegistry.https_url(values["logo_url"])
      errors.add(:branding, "logo_url must be a public HTTPS URL without credentials, query parameters or a fragment")
    end
    %w[primary_color accent_color].each do |key|
      if values[key] != nil && !TenantSubdomainRegistry.hex_color(values[key])
        errors.add(:branding, "#{key} must be a six-digit hex color")
      end
    end
    { "display_name" => TenantSubdomainRegistry::DISPLAY_NAME_MAX, "app_name" => TenantSubdomainRegistry::APP_NAME_MAX }.each do |key, max|
      if values[key] != nil && !TenantSubdomainRegistry.display_text(values[key], max)
        errors.add(:branding, "#{key} must be plain text of #{max} characters or fewer")
      end
    end
    if values.key?("show_main_phone") && ![ true, false ].include?(values["show_main_phone"])
      errors.add(:branding, "show_main_phone must be true or false")
    end
  end

  def subdomain_requires_live_payroll
    errors.add(:subdomain_slug, "is only available to live companies") unless demo?
  end

  def demo_shape_is_permanent
    errors.add(:migration_source_company, "must be blank for a demo company") if migration_source_company_id.present?
    errors.add(:migration_source_batch, "must be blank for a demo company") if migration_source_batch_id.present?
    errors.add(:test_workspace_expires_at, "must be blank for a demo company") if test_workspace_expires_at.present?
    errors.add(:test_workspace_archived_at, "must be blank for a demo company") if test_workspace_archived_at.present?
    errors.add(:test_workspace_sealed_at, "must be blank for a demo company") if test_workspace_sealed_at.present?
    unless test_workspace_manifest.to_h["demo_fixture_key"].to_s.match?(DEMO_FIXTURE_KEY_PATTERN)
      errors.add(:test_workspace_manifest, "must name the demo fixture")
    end
  end

  # A demo never creates FIT deposit checks or prints on preprinted bank stock.
  def demo_outputs_stay_simulated
    errors.add(:auto_create_fit_check, "isn't available for this client") if auto_create_fit_check?
    errors.add(:check_stock_type, "isn't available for this client") if first_hawaiian_4up_checks?
  end

  def company_type_is_unchanged
    was_demo = test_workspace_purpose_in_database == "demo"
    if was_demo != (test_workspace_purpose == "demo") || (was_demo && will_save_change_to_payroll_environment?)
      errors.add(:base, "A demo company cannot be converted to or from another company type")
    end
    if was_demo && test_workspace_manifest_in_database.to_h["demo_fixture_key"] != test_workspace_manifest.to_h["demo_fixture_key"]
      errors.add(:test_workspace_manifest, "demo fixture key cannot change")
    end
  end

  def test_workspace_source_is_valid
    if live_payroll? && (migration_source_company_id.present? || migration_source_batch_id.present? || migration_rehearsal_status.present? || test_workspace_purpose.present?)
      errors.add(:base, "Production clients cannot reference a test workspace source")
      return
    end
    return unless practice_copy? && migration_source_company

    errors.add(:migration_source_company, "must be a production client") unless migration_source_company.live_payroll?
    errors.add(:migration_source_company, "must belong to the same organization") if migration_source_company.organization_id != organization_id
    errors.add(:migration_source_company, "cannot reference itself") if migration_source_company_id == id
    if migration_rehearsal? && (migration_source_batch.blank? || migration_source_batch.company_id != migration_source_company_id || !migration_source_batch.locked?)
      errors.add(:migration_source_batch, "must be a locked import from the source client")
    end
  end

  def issued_check_numbers_in_range(start_number, end_number)
    numbers = (start_number..end_number).map(&:to_s)
    payroll_numbers = PayrollItem.where(company_id: id, check_number: numbers).pluck(:check_number)
    non_employee_numbers = NonEmployeeCheck.where(company_id: id, check_number: numbers).pluck(:check_number)

    historical_numbers = CheckEvent.joins(:payroll_item)
      .where(payroll_items: { company_id: id }, check_number: numbers)
      .pluck(:check_number)

    Set.new(payroll_numbers + non_employee_numbers + historical_numbers)
  end
  def purge_test_workspace_compensation_history
    EmployeeCompensationChangeService.purge_test_workspace_history!(self)
  end
  private :purge_test_workspace_compensation_history
end
