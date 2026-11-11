# frozen_string_literal: true

# Encrypts existing business-contractor EINs in place. The application reads
# both forms during rollout (support_unencrypted_data on Employee), so running
# this before or after the code switch never breaks reads. Rerun
# `bin/rails employees:encrypt_contractor_eins` after deploy to sweep any value
# an old process wrote while the deploy was in progress.
#
# Blank values become NULL, not ciphertext of "", so Employee.intake_incomplete, which checks the
# raw column, keeps flagging business contractors with no EIN. Each rewrite only
# applies while the column still holds the value that was read, so an EIN saved
# by a running process during the migration is never overwritten.
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

      MigrationEmployee.where(id: employee.id)
                       .where("contractor_ein = ?", employee.contractor_ein_before_type_cast)
                       .update_all(contractor_ein: employee.contractor_ein.to_s.strip.presence)
    end
  end

  def down
    MigrationEmployee.reset_column_information
    MigrationEmployee.where.not(contractor_ein: nil).select(:id, :contractor_ein).find_each(batch_size: 100) do |employee|
      next unless employee.encrypted_attribute?(:contractor_ein)

      plaintext = employee.contractor_ein
      ActiveRecord::Encryption.without_encryption do
        MigrationEmployee.where(id: employee.id)
                         .where("contractor_ein = ?", employee.contractor_ein_before_type_cast)
                         .update_all(contractor_ein: plaintext)
      end
    end
  end
end
