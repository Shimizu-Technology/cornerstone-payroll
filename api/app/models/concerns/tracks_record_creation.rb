# frozen_string_literal: true

# Stores who created a record. The "created" audit row comes from the action
# that created it (the request audit in Auditable, or the action's own domain
# audit such as test_workspace#create or client_employees#create), so the
# model never writes a second, competing one.
module TracksRecordCreation
  extend ActiveSupport::Concern

  TYPES = { "Company" => "companies", "Employee" => "employees", "PayPeriod" => "pay_periods" }.freeze

  included do
    before_create :assign_record_creator
  end

  private

  def record_creation_actor
    return Current.user if Current.user
    return migration_rehearsal_created_by if is_a?(Company) && migration_rehearsal_created_by
    company.migration_rehearsal_created_by if !is_a?(Company) && company&.practice_copy?
  end

  def assign_record_creator
    return unless TYPES.key?(self.class.name) && has_attribute?(:created_by_id)

    self[:created_by_id] ||= record_creation_actor&.id
  end
end
