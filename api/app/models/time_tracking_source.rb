# frozen_string_literal: true

class TimeTrackingSource < ApplicationRecord
  SOURCE_TYPES = %w[aire_services cornerstone_tax custom].freeze
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  belongs_to :company
  has_many :time_tracking_employee_mappings, dependent: :destroy
  has_many :time_tracking_imports, dependent: :destroy
  has_many :time_tracking_delegations, dependent: :destroy
  has_many :aire_payroll_calendar_periods, dependent: :restrict_with_error

  encrypts :shared_secret

  before_validation :assign_connection_uuid, on: :create

  validates :name, :source_type, :base_url, :shared_secret, presence: true
  validates :connection_uuid, presence: true, uniqueness: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :expected_source_instance_id, format: { with: UUID_PATTERN }, allow_nil: true
  validates :source_protocol, :source_protocol_version, :identity_verified_at, presence: true, if: :remote_identity_pinned?
  validate :source_capabilities_are_strings
  validate :remote_identity_fields_are_complete
  validates :name, uniqueness: { scope: :company_id }
  validates :company_id, uniqueness: { conditions: -> { where(active: true) }, message: "can only have one active time tracking source" }, if: :active?
  validate :base_url_must_be_http_url
  validate :source_type_must_not_change, on: :update

  scope :active, -> { where(active: true) }

  def shared_secret_configured?
    shared_secret.present?
  end

  def remote_identity_pinned?
    expected_source_instance_id.present?
  end

  def delegation_for(user)
    return unless user

    if time_tracking_delegations.loaded?
      time_tracking_delegations.find { |delegation| delegation.user_id == user.id }
    else
      time_tracking_delegations.find_by(user_id: user.id)
    end
  end

  private

  def assign_connection_uuid
    self.connection_uuid ||= SecureRandom.uuid
  end

  def base_url_must_be_http_url
    uri = URI.parse(base_url.to_s)
    TimeTracking::DestinationPolicy.new.validate_configuration!(
      uri,
      enforce_production: Rails.env.production? && active?
    )
  rescue TimeTracking::DestinationPolicy::Error => e
    errors.add(:base_url, e.message)
  rescue URI::InvalidURIError
    errors.add(:base_url, "must be an HTTP or HTTPS URL with a host and no embedded credentials")
  end

  def source_type_must_not_change
    return unless will_save_change_to_source_type?

    errors.add(:source_type, "cannot be changed after creation")
  end

  def source_capabilities_are_strings
    values = source_capabilities
    unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.match?(/\A[a-z0-9_]+\z/) }
      errors.add(:source_capabilities, "must contain only capability keys")
    end
  end

  def remote_identity_fields_are_complete
    values = [ expected_source_instance_id, source_protocol, source_protocol_version, identity_verified_at ]
    return if values.all?(&:blank?) || values.all?(&:present?)

    errors.add(:base, "Remote source identity must be saved as one complete verified record")
  end
end
