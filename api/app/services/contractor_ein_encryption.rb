# frozen_string_literal: true

# Finds and encrypts business-contractor EINs that were stored before
# Employee#contractor_ein was encrypted. Rewrites only that column, without
# callbacks or timestamps, so it is safe to rerun after a deploy.
class ContractorEinEncryption
  def self.plaintext_ids
    stored_eins.reject { |employee| employee.encrypted_attribute?(:contractor_ein) }.map(&:id)
  end

  # Returns the number of rows rewritten. Blank values become NULL so the raw
  # missing-EIN check in Employee.intake_incomplete still sees them. A row is
  # rewritten only while it still holds the value that was read, so an EIN
  # saved concurrently (for example by an approval) is never overwritten.
  def self.backfill!
    stored_eins.count do |employee|
      next false if employee.encrypted_attribute?(:contractor_ein)

      # update_all with a hash serializes through the encrypted attribute type.
      Employee.unscoped
              .where(id: employee.id)
              .where("contractor_ein = ?", employee.contractor_ein_before_type_cast)
              .update_all(contractor_ein: employee.contractor_ein.to_s.strip.presence)
              .positive?
    end
  end

  def self.stored_eins
    Employee.unscoped.where.not(contractor_ein: nil).select(:id, :contractor_ein).find_each(batch_size: 100)
  end
  private_class_method :stored_eins
end
