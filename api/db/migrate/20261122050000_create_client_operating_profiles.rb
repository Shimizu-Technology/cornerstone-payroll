# frozen_string_literal: true

class CreateClientOperatingProfiles < ActiveRecord::Migration[8.1]
  class MigrationCompany < ActiveRecord::Base
    self.table_name = "companies"
  end

  class MigrationTimeTrackingSource < ActiveRecord::Base
    self.table_name = "time_tracking_sources"
  end

  class MigrationPayPeriod < ActiveRecord::Base
    self.table_name = "pay_periods"
  end

  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationCompanyAssignment < ActiveRecord::Base
    self.table_name = "company_assignments"
  end

  class MigrationClientOperatingProfile < ActiveRecord::Base
    self.table_name = "client_operating_profiles"
  end

  CLIENT_ROLE_ENUM = 4
  GUAM_TIME_ZONE = "Pacific/Guam"

  def up
    enable_extension "btree_gist" unless extension_enabled?("btree_gist")

    create_table :client_operating_profiles do |t|
      t.references :company, null: false, foreign_key: true
      t.date :effective_on, null: false
      t.date :ends_on
      t.integer :version, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.string :offering, null: false
      t.string :hours_source, null: false
      t.string :intake_adapter
      t.boolean :client_portal_enabled, null: false, default: false
      t.boolean :employee_portal_enabled, null: false, default: false
      t.jsonb :options, null: false, default: {}
      t.references :changed_by, foreign_key: { to_table: :users }
      t.text :reason
      t.datetime :confirmed_at
      t.timestamps

      t.index [ :company_id, :version ], unique: true, name: "idx_client_operating_profiles_company_version"
      t.index [ :company_id, :effective_on ], unique: true, name: "idx_client_operating_profiles_company_effective_on"
      t.index :company_id, unique: true, where: "ends_on IS NULL", name: "idx_client_operating_profiles_one_current"

      t.check_constraint "ends_on IS NULL OR ends_on >= effective_on",
                         name: "client_operating_profiles_dates_check"
      t.check_constraint "version >= 1",
                         name: "client_operating_profiles_version_check"
      t.check_constraint "offering IN ('payroll_service', 'payroll_portals', 'workforce_suite')",
                         name: "client_operating_profiles_offering_check"
      t.check_constraint "hours_source IN ('connected_app', 'intake_adapter', 'manual', 'salaried_only')",
                         name: "client_operating_profiles_hours_source_check"
      t.check_constraint "(hours_source = 'intake_adapter' AND intake_adapter IS NOT NULL) OR " \
                         "(hours_source <> 'intake_adapter' AND intake_adapter IS NULL)",
                         name: "client_operating_profiles_intake_adapter_shape_check"
      t.check_constraint "jsonb_typeof(options) = 'object'",
                         name: "client_operating_profiles_options_object_check"

      t.exclusion_constraint "company_id WITH =, daterange(effective_on, ends_on, '[]') WITH &&",
                             using: :gist,
                             name: "client_operating_profiles_no_overlapping_dates"
    end

    backfill_existing_companies!
  end

  def down
    drop_table :client_operating_profiles
  end

  private

  def backfill_existing_companies!
    today = Time.current.in_time_zone(GUAM_TIME_ZONE).to_date
    active_aire_company_ids = MigrationTimeTrackingSource
      .where(active: true, source_type: "aire_services")
      .distinct
      .pluck(:company_id)
      .to_set

    MigrationCompany.find_each do |company|
      next if MigrationClientOperatingProfile.exists?(company_id: company.id)

      offering, hours_source, intake_adapter = classify_company(company, active_aire_company_ids)
      client_portal_enabled = offering == "payroll_portals" ||
        company.client_payroll_approval_required == true ||
        active_client_portal_users?(company.id)

      effective_on = earliest_effective_date_for(company, today)

      MigrationClientOperatingProfile.create!(
        company_id: company.id,
        effective_on: effective_on,
        ends_on: nil,
        version: 1,
        offering: offering,
        hours_source: hours_source,
        intake_adapter: intake_adapter,
        client_portal_enabled: client_portal_enabled,
        employee_portal_enabled: false,
        options: build_options(company, hours_source: hours_source, intake_adapter: intake_adapter),
        reason: "Backfilled from legacy company configuration"
      )
    end
  end

  def classify_company(company, active_aire_company_ids)
    return [ "workforce_suite", "connected_app", nil ] if active_aire_company_ids.include?(company.id)

    sources = Array(company.payroll_intake_source_types).map(&:to_s)
    return [ "payroll_portals", "intake_adapter", "mosa_revel" ] if sources.include?("mosa_revel")
    return [ "payroll_service", "intake_adapter", "spike_email" ] if sources.include?("spike_email")

    [ "payroll_service", "manual", nil ]
  end

  def active_client_portal_users?(company_id)
    now = Time.current
    active_assignment_exists = MigrationCompanyAssignment
      .joins("INNER JOIN users ON users.id = company_assignments.user_id")
      .where(company_id: company_id)
      .where("company_assignments.expires_at IS NULL OR company_assignments.expires_at > ?", now)
      .where("users.role = ? AND users.active = TRUE", CLIENT_ROLE_ENUM)
      .exists?
    return true if active_assignment_exists

    assigned_user_ids = MigrationCompanyAssignment
      .where("expires_at IS NULL OR expires_at > ?", now)
      .select(:user_id)

    MigrationUser
      .where(company_id: company_id, role: CLIENT_ROLE_ENUM, active: true)
      .where.not(id: assigned_user_ids)
      .exists?
  end

  def earliest_effective_date_for(company, today)
    earliest_period = MigrationPayPeriod.where(company_id: company.id).minimum(:start_date)
    created_date = company.created_at&.in_time_zone(GUAM_TIME_ZONE)&.to_date
    [ earliest_period, created_date, today, Date.current ].compact.min
  end

  def build_options(company, hours_source:, intake_adapter:)
    required_sources = nil
    if hours_source == "intake_adapter" && intake_adapter.present?
      raw = company.payroll_intake_settings.is_a?(Hash) ? company.payroll_intake_settings.dig(intake_adapter, "required_sources") : nil
      required_sources = Array(raw).map(&:to_s) unless raw.nil?
    end

    tips_default = intake_adapter == "spike_email" ? "already_paid_out" : "paid_in_check"
    overtime_mode = if hours_source == "connected_app" || intake_adapter == "mosa_revel"
      "source_reports"
    else
      "weekly_split"
    end
    workweek_alignment = intake_adapter == "mosa_revel" ? "warn_if_offset" : "aligned"

    {
      "intake" => {
        "required_sources" => required_sources
      },
      "tips" => {
        "default" => tips_default
      },
      "overtime" => {
        "mode" => overtime_mode
      },
      "workweek" => {
        "alignment" => workweek_alignment
      },
      "client_portal" => {
        "review_first" => {
          "profile" => true,
          "contact" => true,
          "address" => true,
          "pay" => true,
          "termination" => true
        },
        "uploaders" => "all_client_users",
        "sensitive_documents_visible" => false
      },
      "employee_portal" => {
        "features" => {
          "stubs" => false,
          "tax_forms" => false,
          "profile_requests" => false,
          "documents" => false,
          "pto" => false,
          "bank_requests" => false,
          "w4_requests" => false
        },
        "former_access_years" => 6
      },
      "year_end" => {
        "kind_of_employer" => company.kind_of_employer.presence || "N",
        "contact" => {
          "name" => company.filing_contact_name.presence,
          "phone" => company.phone.presence,
          "email" => company.email.presence
        }
      },
      "subdomain_enabled" => false,
      "time_module_enabled" => false
    }
  end
end
