# frozen_string_literal: true

# Moves business-contractor EINs between plaintext and ciphertext in place.
# There is no migration for this: the column type does not change, and old
# processes read the column as a plain string, so the rewrite runs only once
# every web and worker process can read both forms (support_unencrypted_data
# on Employee).
#
# - backfill! (employees:encrypt_contractor_eins) runs after the deploy.
# - restore_plaintext! (employees:decrypt_contractor_eins) runs on the new
#   revision before a code rollback, so the old code reads plaintext again.
#
# Both rewrite only that column, without callbacks or timestamps, and are safe
# to rerun. Blank values become NULL, not ciphertext of "", so the raw
# missing-EIN check in Employee.intake_incomplete still sees them. A row is
# rewritten only while it still holds the value that was read, so an EIN
# saved concurrently (for example by an approval) is never overwritten.
class ContractorEinEncryption
  def self.plaintext_ids
    stored_eins.reject { |employee| employee.encrypted_attribute?(:contractor_ein) }.map(&:id)
  end

  def self.encrypted_ids
    stored_eins.select { |employee| employee.encrypted_attribute?(:contractor_ein) }.map(&:id)
  end

  # Returns the number of rows rewritten.
  def self.backfill!
    stored_eins.count do |employee|
      next false if employee.encrypted_attribute?(:contractor_ein)

      # update_all with a hash serializes through the encrypted attribute type.
      rewrite(employee, employee.contractor_ein.to_s.strip.presence)
    end
  end

  # Returns the number of rows rewritten.
  def self.restore_plaintext!
    stored_eins.count do |employee|
      plaintext = employee.contractor_ein.to_s.strip.presence
      next false unless employee.encrypted_attribute?(:contractor_ein) || plaintext.nil?

      ActiveRecord::Encryption.without_encryption { rewrite(employee, plaintext) }
    end
  end

  def self.stored_eins
    Employee.unscoped.where.not(contractor_ein: nil).select(:id, :contractor_ein).find_each(batch_size: 100)
  end
  private_class_method :stored_eins

  def self.rewrite(employee, value)
    Employee.unscoped
            .where(id: employee.id)
            .where("contractor_ein = ?", employee.contractor_ein_before_type_cast)
            .update_all(contractor_ein: value)
            .positive?
  end
  private_class_method :rewrite
end
