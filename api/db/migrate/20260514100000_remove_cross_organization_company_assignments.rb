# frozen_string_literal: true

class RemoveCrossOrganizationCompanyAssignments < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationCompany < ActiveRecord::Base
    self.table_name = "companies"
  end

  class MigrationCompanyAssignment < ActiveRecord::Base
    self.table_name = "company_assignments"

    belongs_to :user, class_name: "RemoveCrossOrganizationCompanyAssignments::MigrationUser"
    belongs_to :company, class_name: "RemoveCrossOrganizationCompanyAssignments::MigrationCompany"
  end

  def up
    MigrationCompanyAssignment
      .joins(:user, :company)
      .where("users.organization_id IS DISTINCT FROM companies.organization_id")
      .delete_all
  end

  def down
    # Deleted assignments were invalid tenant-boundary rows and cannot be restored safely.
  end
end
