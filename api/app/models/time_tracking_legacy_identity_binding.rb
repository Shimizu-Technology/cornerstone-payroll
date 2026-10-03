# frozen_string_literal: true

# Approved evidence linking a historical numeric-only allocation to a permanent
# source identity. The allocation and earlier acknowledgements remain unchanged.
class TimeTrackingLegacyIdentityBinding < ApplicationRecord
  belongs_to :time_tracking_entry_allocation
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :employee
  belongs_to :time_tracking_employee_mapping
  belongs_to :approved_by, class_name: "User"

  attr_accessor :approved_rollout_digest
  validates :source_user_uuid, :source_instance_id, format: { with: TimeTrackingSource::UUID_PATTERN }
  validates :accepted_manifest_sha256, :batch_checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :source_time_entry_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source_time_entry_id, :source_user_id, :source_line_key, :original_work_date,
            :release_owner, :external_batch_id, presence: true
  validates :time_tracking_entry_allocation_id, uniqueness: true
  validate :approved_rollout_required, on: :create
  validate :immutable_coordinates_match
  before_update :prevent_mutation
  before_destroy :prevent_mutation

  def matching_allocation?(allocation)
    allocation.source_user_uuid.nil? && allocation.company_id == company_id &&
      allocation.time_tracking_source_id == time_tracking_source_id && allocation.employee_id == employee_id &&
      allocation.source_user_id == source_user_id && allocation.source_time_entry_id == source_time_entry_id &&
      allocation.line_key == source_line_key && allocation.original_work_date == original_work_date &&
      allocation.time_tracking_import.external_batch_id == external_batch_id &&
      allocation.time_tracking_import.external_batch_checksum == batch_checksum &&
      allocation.time_tracking_source.expected_source_instance_id == source_instance_id
  end

  private

  def approved_rollout_required
    errors.add(:base, "An explicitly accepted rollout manifest is required") unless
      approved_rollout_digest.present? && approved_rollout_digest == accepted_manifest_sha256
  end

  def immutable_coordinates_match
    allocation = time_tracking_entry_allocation
    mapping = time_tracking_employee_mapping
    return if allocation.nil? || mapping.nil? || approved_by.nil?

    valid = matching_allocation?(allocation) && mapping.company_id == company_id &&
      mapping.time_tracking_source_id == time_tracking_source_id && mapping.employee_id == employee_id &&
      mapping.source_user_id == source_user_id && (mapping.source_user_uuid.nil? || mapping.source_user_uuid == source_user_uuid) &&
      approved_by.active? && approved_by.organization_id == company.organization_id &&
      StaffRolePolicy.allowed?(approved_by, :manage_client_configuration)
    errors.add(:base, "Legacy identity binding tenant, source, owner, or batch evidence changed") unless valid
  end

  def prevent_mutation
    errors.add(:base, "Legacy identity bindings are append-only")
    throw :abort
  end
end
