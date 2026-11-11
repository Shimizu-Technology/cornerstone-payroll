# frozen_string_literal: true

# Encrypts existing business-contractor EINs in place. The application reads
# both forms during rollout (support_unencrypted_data on Employee), so running
# this before or after the code switch never breaks reads. Rerun
# `bin/rails employees:encrypt_contractor_eins` after deploy to sweep any value
# an old process wrote while the deploy was in progress.
class EncryptEmployeeContractorEins < ActiveRecord::Migration[8.1]
  class MigrationEmployee < ActiveRecord::Base
    self.table_name = "employees"
    self.inheritance_column = nil
    encrypts :contractor_ein, deterministic: true, support_unencrypted_data: true
  end

  def up
    MigrationEmployee.reset_column_information
    MigrationEmployee.where.not(contractor_ein: nil).select(:id, :contractor_ein).find_each(batch_size: 100) do |employee|
      next if employee.encrypted_attribute?(:contractor_ein)

      employee.update_columns(contractor_ein: employee.contractor_ein)
    end
  end

  def down
    MigrationEmployee.reset_column_information
    MigrationEmployee.where.not(contractor_ein: nil).select(:id, :contractor_ein).find_each(batch_size: 100) do |employee|
      next unless employee.encrypted_attribute?(:contractor_ein)

      plaintext = employee.contractor_ein
      ActiveRecord::Encryption.without_encryption { employee.update_columns(contractor_ein: plaintext) }
    end
  end
end
