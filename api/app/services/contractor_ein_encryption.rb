# frozen_string_literal: true

# Finds and encrypts business-contractor EINs that were stored before
# Employee#contractor_ein was encrypted. Rewrites only that column, without
# callbacks or timestamps, so it is safe to rerun after a deploy.
class ContractorEinEncryption
  def self.plaintext_ids
    stored_eins.reject { |employee| employee.encrypted_attribute?(:contractor_ein) }.map(&:id)
  end

  def self.backfill!
    stored_eins.count do |employee|
      next false if employee.encrypted_attribute?(:contractor_ein)

      # update_columns serializes through the encrypted attribute type.
      employee.update_columns(contractor_ein: employee.contractor_ein)
      true
    end
  end

  def self.stored_eins
    Employee.unscoped.where.not(contractor_ein: nil).select(:id, :contractor_ein).find_each(batch_size: 100)
  end
  private_class_method :stored_eins
end
