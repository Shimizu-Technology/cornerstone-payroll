# frozen_string_literal: true

module PayrollIntake
  # Which source files a package needs before it can be applied. Each adapter
  # names its files and a default; a client can override the required list in
  # companies.payroll_intake_settings[source_type]["required_sources"].
  # A waivable file can be skipped only through an explicit, recorded choice
  # (for MoSa: "No tips or loans this period").
  class SourceCompleteness
    def self.roles_for(source_type)
      adapter = PayrollIntake::PreviewService::SOURCE_ADAPTERS[source_type.to_s]
      adapter.respond_to?(:source_roles) ? adapter.source_roles : {}
    end

    def self.default_required_roles(source_type)
      adapter = PayrollIntake::PreviewService::SOURCE_ADAPTERS[source_type.to_s]
      adapter.respond_to?(:default_required_source_roles) ? adapter.default_required_source_roles : []
    end

    def initialize(session:, company: session.company)
      @session = session
      @company = company
    end

    def sources
      present = session.documents.reject { |document| document.verification_status == "legacy_unverified" }.index_by(&:source_role)
      roles.map do |role, definition|
        document = present[role]
        {
          role: role,
          label: definition.fetch(:label),
          required: required_roles.include?(role),
          present: document.present?,
          filename: document&.filename,
          waiver_label: definition[:waiver_label]
        }
      end
    end

    def missing_required_roles(waived_roles: [])
      waivable = roles.select { |_role, definition| definition[:waiver_label].present? }.keys
      waived = Array(waived_roles).map(&:to_s) & waivable
      sources.select { |source| source[:required] && !source[:present] }.map { |source| source[:role] } - waived
    end

    def complete?(waived_roles: [])
      missing_required_roles(waived_roles: waived_roles).empty?
    end

    def waivable_missing_roles
      sources.select { |source| source[:required] && !source[:present] && source[:waiver_label].present? }.map { |source| source[:role] }
    end

    def labels_for(roles_list)
      roles_list.map { |role| roles.dig(role, :label) || role.humanize }
    end

    private

    attr_reader :session, :company

    def roles
      @roles ||= self.class.roles_for(session.source_type)
    end

    def required_roles
      @required_roles ||= company.payroll_intake_required_sources(session.source_type)
    end
  end
end
