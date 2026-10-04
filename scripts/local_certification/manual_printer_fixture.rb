# frozen_string_literal: true

# Synthetic alignment only: this never represents a physical printer test.
module ManualPrinterFixture
  def self.seed!(company:, accountant:, admin:)
    database = ActiveRecord::Base.connection_db_config.database.to_s
    unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" &&
           database.match?(/\Acornerstone_aire_certification_\d+_\d+\z/) &&
           accountant.accountant? && accountant.organization_id == company.organization_id &&
           StaffRolePolicy.historical_reconciliation_allowed?(accountant, company) &&
           !StaffRolePolicy.allowed?(accountant, :manage_client_configuration)
      abort "Refusing printer fixtures outside the isolated assigned-accountant drill"
    end
    profile = company.organization.printer_profiles.create!(name: "Synthetic certification printer",
      check_stock_type: company.check_stock_type, check_offset_x: 0, check_offset_y: 0,
      created_by: admin, updated_by: admin, notes: "Synthetic PDF alignment; no physical printer or real check")
    UserPrinterProfileSelection.create!(organization: company.organization, user: accountant,
      printer_profile: profile, check_stock_type: company.check_stock_type)
    profile
  end
end
