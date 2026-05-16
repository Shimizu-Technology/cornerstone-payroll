# frozen_string_literal: true

class AddActivePrinterProfileToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_reference :companies,
      :active_printer_profile,
      foreign_key: { to_table: :printer_profiles, on_delete: :nullify },
      index: true
  end
end
