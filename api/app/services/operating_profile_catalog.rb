# frozen_string_literal: true

class OperatingProfileCatalog
  Entry = Data.define(
    :id,
    :label,
    :section,
    :storage,
    :type,
    :default,
    :allowed,
    :capability,
    :what,
    :example,
    :effect,
    :requires
  ) do
    def option?
      storage == :option
    end

    def column?
      storage == :column
    end

    def path
      id.split(".")
    end

    def as_json(*)
      {
        id: id,
        label: label,
        section: section,
        storage: storage.to_s,
        type: type,
        default: default,
        allowed: allowed,
        capability: capability.to_s,
        what: what,
        example: example,
        effect: effect,
        requires: requires
      }
    end
  end

  REQUIRED_METADATA_FIELDS = %i[
    id label section storage type default allowed capability what example effect requires
  ].freeze

  OFFERINGS = %w[payroll_service payroll_portals workforce_suite].freeze
  HOURS_SOURCES = %w[connected_app intake_adapter manual salaried_only].freeze
  REGISTERED_INTAKE_ADAPTERS = Company::PAYROLL_INTAKE_SOURCE_TYPES
  TIPS_DEFAULTS = %w[paid_in_check already_paid_out].freeze
  OVERTIME_MODES = %w[source_reports weekly_split total_as_regular_warn_over_80 daily_records].freeze
  WORKWEEK_ALIGNMENTS = %w[aligned warn_if_offset].freeze
  CONFIGURABLE_REVIEW_FIRST_GROUPS = %w[profile contact address pay termination].freeze
  ALWAYS_REVIEWED_GROUPS = %w[bank w4 identity].freeze
  ALL_REVIEW_FIRST_GROUPS = (CONFIGURABLE_REVIEW_FIRST_GROUPS + ALWAYS_REVIEWED_GROUPS).freeze
  EMPLOYEE_PORTAL_FEATURES = %w[
    stubs tax_forms profile_requests documents pto bank_requests w4_requests
  ].freeze
  KIND_OF_EMPLOYER_VALUES = %w[N F S T Y].freeze
  FORMER_ACCESS_YEARS_RANGE = (1..10).freeze

  M4_TO_M6_TOGGLE_IDS = (
    [ "employee_portal_enabled" ] +
    EMPLOYEE_PORTAL_FEATURES.map { |feature| "employee_portal.features.#{feature}" } +
    [ "subdomain_enabled", "time_module_enabled" ]
  ).freeze

  ENTRIES = [
    Entry.new(
      id: "offering",
      label: "Service offering",
      section: "core",
      storage: :column,
      type: "enum",
      default: "payroll_service",
      allowed: OFFERINGS,
      capability: :manage_client_administration,
      what: "Named service tier preset describing which Cornerstone payroll, portal, and workforce capabilities are active for this client.",
      example: "payroll_portals for MoSa's; workforce_suite for AIRE; payroll_service for Spike.",
      effect: "Guides default portal and workflow posture for the client; individual switches remain explicit in the operating profile.",
      requires: [].freeze
    ),
    Entry.new(
      id: "hours_source",
      label: "Hours source",
      section: "core",
      storage: :column,
      type: "enum",
      default: "manual",
      allowed: HOURS_SOURCES,
      capability: :manage_organization,
      what: "How employee work hours enter payroll for each pay period.",
      example: "connected_app for AIRE finalized batches, intake_adapter for MoSa's Revel PDF + workbook, manual for direct staff entry.",
      effect: "Determines which hours-import path is expected for open pay periods.",
      requires: [].freeze
    ),
    Entry.new(
      id: "intake_adapter",
      label: "Intake adapter",
      section: "core",
      storage: :column,
      type: "nullable_enum",
      default: nil,
      allowed: REGISTERED_INTAKE_ADAPTERS,
      capability: :manage_organization,
      what: "Registered payroll intake parser used when hours_source is set to intake_adapter.",
      example: "mosa_revel for MoSa's Revel PDF + workbook; spike_email for Spike Coffee Roasters emailed hours.",
      effect: "Selects the registered intake adapter descriptor, file roles, and parsing rules. Must be blank unless hours_source is intake_adapter.",
      requires: [ "hours_source=intake_adapter" ].freeze
    ),
    Entry.new(
      id: "client_portal_enabled",
      label: "Client portal enabled",
      section: "client_portal",
      storage: :column,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Controls whether employer managers and client office users can access the Cornerstone client portal for this company.",
      example: "true for MoSa's and KPI; false for clients who email hours directly to Cornerstone.",
      effect: "Enables client portal routes, payroll submissions, document exchange, and review workflows.",
      requires: [].freeze
    ),
    Entry.new(
      id: "employee_portal_enabled",
      label: "Employee portal enabled",
      section: "employee_portal",
      storage: :column,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Master switch for employee self-service sign-in and employee API access for this company (Milestone 4).",
      example: "false for all clients during Milestone 3; true for MoSa's when the Milestone 4 pilot starts.",
      effect: "When false, all /api/v1/employee/* endpoints reject access for this company's workers. Never enabled on test workspaces.",
      requires: [].freeze
    ),
    Entry.new(
      id: "intake.required_sources",
      label: "Required intake source files",
      section: "intake",
      storage: :option,
      type: "nullable_string_array",
      default: nil,
      allowed: nil,
      capability: :manage_client_configuration,
      what: "Overrides which source file roles must be present (or explicitly waived) before an intake package can be applied.",
      example: '["revel_hours", "supplemental_workbook"] for MoSa default; [] to allow applying a single file; null to inherit the adapter default.',
      effect: "Controls package completeness checks before staff can apply an imported payroll package.",
      requires: [ "hours_source=intake_adapter" ].freeze
    ),
    Entry.new(
      id: "tips.default",
      label: "Default tip treatment",
      section: "intake",
      storage: :option,
      type: "enum",
      default: "paid_in_check",
      allowed: TIPS_DEFAULTS,
      capability: :manage_client_configuration,
      what: "Determines whether imported reported tips default to being paid on the paycheck or marked as already paid out in cash/daily.",
      example: "paid_in_check for MoSa's; already_paid_out for Spike.",
      effect: "Seeds the default tips-already-paid treatment during intake normalization unless overridden on an individual row.",
      requires: [].freeze
    ),
    Entry.new(
      id: "overtime.mode",
      label: "Overtime calculation mode",
      section: "intake",
      storage: :option,
      type: "enum",
      default: "weekly_split",
      allowed: OVERTIME_MODES,
      capability: :manage_client_configuration,
      what: "How regular and overtime hours are determined from imported or recorded hours.",
      example: "source_reports for MoSa's Revel and AIRE; weekly_split for Spike weekly totals; total_as_regular_warn_over_80 for biweekly totals without weekly split.",
      effect: "Controls whether Payroll trusts source-reported overtime or splits hours using the company's legal workweek.",
      requires: [].freeze
    ),
    Entry.new(
      id: "workweek.alignment",
      label: "Workweek alignment policy",
      section: "intake",
      storage: :option,
      type: "enum",
      default: "aligned",
      allowed: WORKWEEK_ALIGNMENTS,
      capability: :manage_client_configuration,
      what: "Controls how intake handles a pay period whose start weekday differs from the client's saved legal workweek.",
      example: "warn_if_offset for MoSa's where Revel splits overtime; aligned when Payroll calculates weekly overtime itself.",
      effect: "Determines whether an offset pay period blocks weekly overtime calculation or proceeds with an explicit warning.",
      requires: [].freeze
    ),
    Entry.new(
      id: "client_portal.review_first.profile",
      label: "Review client profile edits first",
      section: "client_portal",
      storage: :option,
      type: "boolean",
      default: true,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Requires Cornerstone staff approval before a client admin's employee profile changes take effect.",
      example: "true to route client edits through the staff review queue; false to allow direct edits.",
      effect: "When true, client admin profile edits create pending EmployeeChangeRequests instead of applying immediately.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "client_portal.review_first.contact",
      label: "Review client contact edits first",
      section: "client_portal",
      storage: :option,
      type: "boolean",
      default: true,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Requires Cornerstone staff approval before a client admin's employee phone or email edits take effect.",
      example: "true for full Cornerstone review; false to let client admins update employee contact details directly.",
      effect: "Controls whether client admin contact updates enter the approval queue or apply directly.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "client_portal.review_first.address",
      label: "Review client address edits first",
      section: "client_portal",
      storage: :option,
      type: "boolean",
      default: true,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Requires Cornerstone staff approval before a client admin's employee mailing address edits take effect.",
      example: "true during year-end or for supervised clients; false for direct client admin address updates.",
      effect: "Controls whether client admin address updates enter the approval queue or apply directly.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "client_portal.review_first.pay",
      label: "Review client pay-rate edits first",
      section: "client_portal",
      storage: :option,
      type: "boolean",
      default: true,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Requires Cornerstone staff approval before a client admin's effective-dated pay-rate edits take effect.",
      example: "true when Cornerstone verifies every wage change; false when trusted client admins record effective-dated raises directly.",
      effect: "Controls whether client admin pay changes enter the approval queue before creating a new compensation version.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "client_portal.review_first.termination",
      label: "Review client terminations first",
      section: "client_portal",
      storage: :option,
      type: "boolean",
      default: true,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Requires Cornerstone staff approval before a client admin's employee termination request finalizes.",
      example: "true so Cornerstone reviews final paycheck timing and Guam compliance before terminating.",
      effect: "Routes client-initiated employee terminations through Cornerstone staff review.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "client_portal.uploaders",
      label: "Allowed client portal uploaders",
      section: "client_portal",
      storage: :option,
      type: "uploaders",
      default: "all_client_users",
      allowed: [ "all_client_users", "user_id_array" ].freeze,
      capability: :manage_client_administration,
      what: "Specifies whether every active client portal user for this company can submit payroll files or only an explicit list of user IDs.",
      example: '"all_client_users" for MoSa\'s; [42, 43] to restrict submissions to named client admins.',
      effect: "Restricts which client portal users can upload payroll packages and supporting documents.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "client_portal.sensitive_documents_visible",
      label: "Sensitive documents visible to client users",
      section: "client_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Controls whether client portal users can view and download documents marked sensitive (such as W-4s or ID copies).",
      example: "false by default to limit PII exposure; true only if the employer explicitly needs portal access to sensitive files.",
      effect: "Hides sensitive client documents from client portal listings and downloads when false.",
      requires: [ "client_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.stubs",
      label: "Employee portal: pay stubs",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Allows active and former employees to view and download committed pay stubs in the employee portal (Milestone 4).",
      example: "false during Milestone 3; true when MoSa's pilot launches.",
      effect: "Gates /api/v1/employee/pay_stubs endpoints when employee_portal_enabled is true.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.tax_forms",
      label: "Employee portal: tax forms",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Allows employees to view and download posted W-2GU and 1099-NEC copies and manage electronic delivery consent (Milestone 4).",
      example: "false during Milestone 3; true when electronic year-end forms are posted.",
      effect: "Gates /api/v1/employee/tax_forms and consent endpoints when employee_portal_enabled is true.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.profile_requests",
      label: "Employee portal: profile & contact change requests",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Allows employees to submit verified contact and address update requests through the employee portal (Milestone 4).",
      example: "false during Milestone 3; true once Milestone 4 change requests are enabled.",
      effect: "Gates employee-submitted contact and address change requests.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.documents",
      label: "Employee portal: HR documents",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Allows employees to access employee-visible documents and acknowledgments in the employee portal (Milestone 5).",
      example: "false during Milestone 3; true when employee handbook and document distribution turns on.",
      effect: "Gates /api/v1/employee/documents endpoints.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.pto",
      label: "Employee portal: PTO balances & requests",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Shows employee PTO balances and enables leave requests in the employee portal (Milestone 5).",
      example: "false during Milestone 3; true once a client configures PTO policies.",
      effect: "Gates employee PTO balance views and leave request submissions.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.bank_requests",
      label: "Employee portal: direct deposit bank change requests",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Allows employees to submit direct deposit bank account change requests subject to OTP verification and Cornerstone staff approval.",
      example: "false until SMS/OTP verification and Cornerstone bank-verification workflow are active.",
      effect: "Gates employee bank-change submissions; bank changes always require Payroll verification and staff approval.",
      requires: [ "employee_portal_enabled", "sms_provider" ].freeze
    ),
    Entry.new(
      id: "employee_portal.features.w4_requests",
      label: "Employee portal: electronic W-4 requests",
      section: "employee_portal",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_client_administration,
      what: "Allows employees to submit electronic W-4 withholding elections with jurat and e-signature (Milestone 5).",
      example: "false during Milestone 3; true once electronic W-4 signing ships.",
      effect: "Gates employee electronic W-4 submission endpoints.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "employee_portal.former_access_years",
      label: "Former employee portal access window (years)",
      section: "employee_portal",
      storage: :option,
      type: "integer",
      default: 6,
      allowed: { min: FORMER_ACCESS_YEARS_RANGE.min, max: FORMER_ACCESS_YEARS_RANGE.max }.freeze,
      capability: :manage_client_administration,
      what: "Number of years after termination that a former employee retains read-only access to pay stubs and tax forms.",
      example: "6 years by default to align with payroll retention expectations.",
      effect: "Sets former_access_until when an employee link transitions to former status.",
      requires: [ "employee_portal_enabled" ].freeze
    ),
    Entry.new(
      id: "year_end.kind_of_employer",
      label: "Year-end kind of employer (W-3SS / EFW2)",
      section: "year_end",
      storage: :option,
      type: "enum",
      default: "N",
      allowed: KIND_OF_EMPLOYER_VALUES,
      capability: :manage_filing_review,
      what: "SSA / Guam DRT Kind of Employer code reported on W-3SS and EFW2 filings.",
      example: "N (None apply) for standard private employers; F (Federal), S (State/local), T (501c non-govt), Y (State/local 501c).",
      effect: "Populates the Kind of Employer code on year-end W-2GU / W-3SS filings.",
      requires: [].freeze
    ),
    Entry.new(
      id: "year_end.contact.name",
      label: "Year-end filing contact name",
      section: "year_end",
      storage: :option,
      type: "nullable_string",
      default: nil,
      allowed: nil,
      capability: :manage_filing_review,
      what: "Contact person name listed on year-end W-2GU / 1099-NEC employer filing records.",
      example: "Jane Cruz",
      effect: "Populates the employer contact name on year-end transmittals and electronic filing headers.",
      requires: [].freeze
    ),
    Entry.new(
      id: "year_end.contact.phone",
      label: "Year-end filing contact phone",
      section: "year_end",
      storage: :option,
      type: "nullable_string",
      default: nil,
      allowed: nil,
      capability: :manage_filing_review,
      what: "Contact phone number listed on year-end employer filing records.",
      example: "671-555-1234",
      effect: "Populates the employer contact phone number on year-end transmittals and electronic filing headers.",
      requires: [].freeze
    ),
    Entry.new(
      id: "year_end.contact.email",
      label: "Year-end filing contact email",
      section: "year_end",
      storage: :option,
      type: "nullable_string",
      default: nil,
      allowed: nil,
      capability: :manage_filing_review,
      what: "Contact email address listed on year-end employer filing records.",
      example: "payroll@example.com",
      effect: "Populates the employer contact email address on year-end transmittals and electronic filing headers.",
      requires: [].freeze
    ),
    Entry.new(
      id: "subdomain_enabled",
      label: "Branded client subdomain enabled",
      section: "platform",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_organization,
      what: "Enables the client's branded <slug>.shimizu-technology.com subdomain in public tenant branding, CORS, and Clerk azp allowlists (M3-6 / Milestone 4).",
      example: "false for all clients during Milestone 3; true for mosas.shimizu-technology.com when MoSa's pilot launches.",
      effect: "When false, tenant branding returns 404 and the subdomain origin is not allowlisted. Never enabled on test workspaces.",
      requires: [].freeze
    ),
    Entry.new(
      id: "time_module_enabled",
      label: "Built-in time tracking module enabled",
      section: "platform",
      storage: :option,
      type: "boolean",
      default: false,
      allowed: [ true, false ].freeze,
      capability: :manage_organization,
      what: "Enables the platform's built-in clock-in, kiosk, schedule, and time-approval module for this company (Milestone 6).",
      example: "false for all clients during Milestones 3–5; true when a client adopts the platform time module.",
      effect: "Activates platform time-tracking features once Milestone 6 ships.",
      requires: [].freeze
    )
  ].freeze

  BY_ID = ENTRIES.index_by(&:id).freeze
  COLUMN_ENTRIES = ENTRIES.select(&:column?).freeze
  OPTION_ENTRIES = ENTRIES.select(&:option?).freeze
  OPTION_BY_ID = OPTION_ENTRIES.index_by(&:id).freeze

  # Precomputed nested tree of valid option groups and leaf entries so validation
  # rejects both unknown top-level/nested keys and structural mismatches.
  OPTION_TREE = begin
    tree = {}
    OPTION_ENTRIES.each do |entry|
      cursor = tree
      entry.path[0...-1].each do |segment|
        cursor[segment] ||= {}
        cursor = cursor[segment]
      end
      cursor[entry.path.last] = entry
    end
    tree.freeze
  end

  class << self
    def entries
      ENTRIES
    end

    def option_entries
      OPTION_ENTRIES
    end

    def column_entries
      COLUMN_ENTRIES
    end

    def ids
      BY_ID.keys
    end

    def option_ids
      OPTION_BY_ID.keys
    end

    def column_ids
      COLUMN_ENTRIES.map(&:id)
    end

    def registered_intake_adapters
      REGISTERED_INTAKE_ADAPTERS
    end

    def find(id)
      BY_ID[id.to_s]
    end

    def fetch(id)
      BY_ID.fetch(id.to_s)
    end

    def default_for(id)
      deep_dup_value(fetch(id).default)
    end

    def default_options
      result = {}
      OPTION_ENTRIES.each do |entry|
        write_nested_value(result, entry.path, deep_dup_value(entry.default))
      end
      result
    end

    def resolve_options(raw_options)
      resolved = default_options
      return resolved unless raw_options.is_a?(Hash)

      OPTION_ENTRIES.each do |entry|
        found, value = fetch_nested_value(raw_options, entry.path)
        write_nested_value(resolved, entry.path, deep_dup_value(value)) if found
      end
      resolved
    end

    def option_value(raw_options, id)
      entry = OPTION_BY_ID.fetch(id.to_s)
      if raw_options.is_a?(Hash)
        found, value = fetch_nested_value(raw_options, entry.path)
        return deep_dup_value(value) if found
      end
      deep_dup_value(entry.default)
    end

    def validate_options(raw_options, intake_adapter: nil)
      return [ "must be a JSON object" ] unless raw_options.is_a?(Hash)

      errors = []
      validate_node(raw_options, OPTION_TREE, [], errors, intake_adapter: intake_adapter)
      errors
    end

    def editable_keys_for(user:, company:)
      return [] unless user && company
      return [] if company.test_workspace_read_only?

      ENTRIES.filter_map do |entry|
        next unless StaffRolePolicy.allowed?(user, entry.capability, company: company)
        next unless TestWorkspaceAccessPolicy.allowed?(
          user: user,
          company: company,
          request_method: "PATCH",
          capability: entry.capability
        )

        entry.id
      end
    end

    def serialize
      ENTRIES.map(&:as_json)
    end

    private

    def validate_node(node, schema, prefix, errors, intake_adapter:)
      node.each do |raw_key, value|
        key = raw_key.to_s
        path = prefix + [ key ]
        dotted = path.join(".")

        unless schema.key?(key)
          errors << "contains unknown option key '#{dotted}'"
          next
        end

        spec = schema.fetch(key)
        if spec.is_a?(Entry)
          validate_entry_value(spec, value, errors, intake_adapter: intake_adapter)
        elsif value.is_a?(Hash)
          validate_node(value, spec, path, errors, intake_adapter: intake_adapter)
        else
          errors << "option group '#{dotted}' must be a JSON object"
        end
      end
    end

    def validate_entry_value(entry, value, errors, intake_adapter:)
      case entry.type
      when "boolean"
        unless value == true || value == false
          errors << "option '#{entry.id}' must be a boolean"
        end
      when "enum"
        unless value.is_a?(String) && entry.allowed.include?(value)
          errors << "option '#{entry.id}' must be one of: #{entry.allowed.join(', ')}"
        end
      when "integer"
        min = entry.allowed.fetch(:min)
        max = entry.allowed.fetch(:max)
        unless value.is_a?(Integer) && value >= min && value <= max
          errors << "option '#{entry.id}' must be an integer between #{min} and #{max}"
        end
      when "nullable_string"
        unless value.nil? || value.is_a?(String)
          errors << "option '#{entry.id}' must be a string or null"
        end
      when "nullable_string_array"
        validate_required_sources(entry, value, errors, intake_adapter: intake_adapter)
      when "uploaders"
        validate_uploaders(entry, value, errors)
      else
        errors << "option '#{entry.id}' has unsupported catalog type '#{entry.type}'"
      end
    end

    def validate_required_sources(entry, value, errors, intake_adapter:)
      return if value.nil?

      unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && item.present? }
        errors << "option '#{entry.id}' must be null or an array of source role strings"
        return
      end

      if intake_adapter.blank?
        return if value.empty?

        errors << "option '#{entry.id}' cannot specify source roles without an intake_adapter"
        return
      end

      known_roles = PayrollIntake::SourceCompleteness.roles_for(intake_adapter).keys
      unknown = value - known_roles
      return if unknown.empty?

      errors << "option '#{entry.id}' lists unknown #{intake_adapter} source role(s): #{unknown.join(', ')}"
    end

    def validate_uploaders(entry, value, errors)
      return if value == "all_client_users"
      return if value.is_a?(Array) && value.all? { |item| item.is_a?(Integer) && item.positive? }

      errors << "option '#{entry.id}' must be 'all_client_users' or an array of positive user IDs"
    end

    def fetch_nested_value(hash, path)
      cursor = hash
      path.each_with_index do |segment, index|
        return [ false, nil ] unless cursor.is_a?(Hash)

        if cursor.key?(segment)
          value = cursor[segment]
        elsif cursor.key?(segment.to_sym)
          value = cursor[segment.to_sym]
        else
          return [ false, nil ]
        end

        return [ true, value ] if index == path.length - 1

        cursor = value
      end
      [ false, nil ]
    end

    def write_nested_value(hash, path, value)
      cursor = hash
      path[0...-1].each do |segment|
        cursor[segment] ||= {}
        cursor = cursor[segment]
      end
      cursor[path.last] = value
    end

    def deep_dup_value(value)
      case value
      when Hash
        value.transform_values { |item| deep_dup_value(item) }
      when Array
        value.map { |item| deep_dup_value(item) }
      when String
        value.dup
      else
        value
      end
    end
  end
end
