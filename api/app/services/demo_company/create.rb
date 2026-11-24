# frozen_string_literal: true

module DemoCompany
  # Provisions an empty, permanent demo company. Seeding its employees and
  # payroll is a separate step; this only creates the company shape.
  class Create
    FIXTURE_KEY_PATTERN = /\A[a-z0-9][a-z0-9-]{2,62}\z/
    PAY_FREQUENCIES = %w[biweekly weekly semimonthly monthly].freeze
    PROFILE_FIELDS = %i[ein address_line1 address_line2 city state zip phone email filing_contact_name].freeze

    def initialize(organization:, actor:, name:, fixture_key:, pay_frequency: "biweekly", profile: {})
      @organization = organization
      @actor = actor
      @name = name.to_s.strip
      @fixture_key = fixture_key.to_s.strip
      @pay_frequency = pay_frequency.to_s
      @profile = profile.to_h.symbolize_keys.slice(*PROFILE_FIELDS)
    end

    def call
      authorize!
      raise ArgumentError, "Name the demo company" if name.blank?
      raise ArgumentError, "Fixture key must be 3–63 lowercase letters, numbers or hyphens" unless fixture_key.match?(FIXTURE_KEY_PATTERN)
      raise ArgumentError, "Choose a supported pay frequency" unless PAY_FREQUENCIES.include?(pay_frequency)

      Company.transaction do
        organization.lock!
        if Company.demo.where(organization_id: organization.id).where("test_workspace_manifest ->> 'demo_fixture_key' = ?", fixture_key).exists?
          raise ArgumentError, "A demo company with this fixture key already exists"
        end

        timestamp = Time.current
        company = Company.create!(
          profile.merge(
            organization: organization,
            name: name,
            pay_frequency: pay_frequency,
            active: true,
            payroll_environment: "migration_rehearsal",
            test_workspace_purpose: "demo",
            migration_rehearsal_status: "ready",
            migration_rehearsal_created_by: actor,
            migration_rehearsal_created_at: timestamp,
            migration_rehearsal_completed_at: timestamp,
            test_workspace_manifest: { "version" => 1, "purpose" => "demo", "demo_fixture_key" => fixture_key },
            auto_create_fit_check: false,
            check_stock_type: "top_check",
            check_offset_x: 0.0,
            check_offset_y: 0.0,
            next_check_number: 1001,
            created_by: actor
          )
        )
        # Staff history shows an ordinary client creation; the fixture key
        # stays on the company row, which only organization admins can see.
        AuditLog.record!(
          user: actor,
          organization_id: organization.id,
          company_id: company.id,
          action: "companies#create",
          record_type: "Company",
          record_id: company.id,
          subject_name: company.name,
          metadata: {}
        )
        company
      end
    end

    private

    attr_reader :organization, :actor, :name, :fixture_key, :pay_frequency, :profile

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator is required" unless allowed
    end
  end
end
