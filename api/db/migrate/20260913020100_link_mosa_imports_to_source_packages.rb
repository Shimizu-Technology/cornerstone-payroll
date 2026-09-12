# frozen_string_literal: true

class LinkMosaImportsToSourcePackages < ActiveRecord::Migration[8.1]
  def change
    add_reference :payroll_imports,
                  :payroll_intake_session,
                  foreign_key: { on_delete: :restrict },
                  index: { unique: true, name: "idx_payroll_imports_intake_session" }
  end
end
