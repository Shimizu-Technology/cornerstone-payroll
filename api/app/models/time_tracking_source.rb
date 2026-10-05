# frozen_string_literal: true

class TimeTrackingSource < ApplicationRecord
  SOURCE_TYPES = %w[aire_services cornerstone_tax custom].freeze
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  belongs_to :company
  has_many :time_tracking_entry_allocations, dependent: :restrict_with_error
  has_many :time_tracking_legacy_identity_bindings, dependent: :restrict_with_error
  has_many :time_tracking_employee_mappings, dependent: :destroy
  has_many :time_tracking_manual_allocations, dependent: :restrict_with_error
  has_many :time_tracking_classification_reconciliations, dependent: :restrict_with_error
  has_many :aire_verified_history_rollout_receipts, dependent: :restrict_with_error
  has_many :time_tracking_imports, dependent: :destroy
  has_many :time_tracking_delegations, dependent: :destroy
  has_many :aire_payroll_calendar_periods, dependent: :restrict_with_error

  encrypts :shared_secret

  before_validation :assign_connection_uuid, on: :create
  before_validation :require_existing_payroll_history, on: :create
  before_validation :require_history_when_enabling_complete_protocol, on: :update

  validates :name, :source_type, :base_url, :shared_secret, presence: true
  validates :connection_uuid, presence: true, uniqueness: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :expected_source_instance_id, format: { with: UUID_PATTERN }, allow_nil: true
  validates :source_protocol, :source_protocol_version, :identity_verified_at, presence: true, if: :remote_identity_pinned?
  validate :history_gate_cannot_be_disabled, on: :update
  validate :authorization_origin_is_secure
  validate :producer_identity_is_immutable, on: :update
  validates :remote_source_identifier, format: { with: /\A[a-z0-9_]+\z/ }, allow_nil: true
  validate :source_capabilities_are_strings
  validate :remote_identity_fields_are_complete
  validates :name, uniqueness: { scope: :company_id }
  validates :company_id, uniqueness: { conditions: -> { where(active: true) }, message: "can only have one active time tracking source" }, if: :active?
  validate :base_url_must_be_http_url
  validate :source_type_must_not_change, on: :update

  scope :active, -> { where(active: true) }

  def connector
    TimeTracking::Connector.new(self)
  end

  def supports?(capability)
    connector.supports?(capability)
  end

  def historical_reconciliation_complete?
    return true unless historical_reconciliation_required?
    return false unless remote_identity_pinned?

    aire_verified_history_rollout_receipts.where(company_id: company_id,
      source_instance_id: expected_source_instance_id, coverage_verified: true)
      .where("accepted_manifest_sha256 = manifest_sha256").where.not(approved_by_id: nil).where.not(release_owner: nil).exists?
  end

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

  def require_existing_payroll_history
    return unless company

    if company.pay_periods.where(status: "committed", cycle: "regular", run_purpose: "regular").exists?
      self.historical_reconciliation_required = true
    end
  end

  def require_history_when_enabling_complete_protocol
    return unless source_type == "custom" && remote_source_identifier.present?

    gated_capabilities = %w[payroll_calendar_v2 finalized_batch_v2 exact_line_receipts_v2]
    newly_added = (Array(source_capabilities) & gated_capabilities) -
      (Array(source_capabilities_in_database) & gated_capabilities)
    return if newly_added.empty?

    # Only an applied batch proves this source has already processed payroll.
    # A calendar-only publication cannot exempt newly enabled batch receipts.
    return if time_tracking_imports.where(contract_version: "2.0", status: "applied").exists?
    return if newly_added == [ "payroll_calendar_v2" ] && aire_payroll_calendar_periods.exists?

    require_existing_payroll_history
  end

  def history_gate_cannot_be_disabled
    if historical_reconciliation_required_change == [ true, false ]
      errors.add(:historical_reconciliation_required, "cannot be cleared through ordinary source setup")
    end
  end

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

  def producer_identity_is_immutable
    if remote_source_identifier_in_database.present? && will_save_change_to_remote_source_identifier?
      errors.add(:remote_source_identifier, "cannot change after verification")
    end
  end

  def authorization_origin_is_secure
    return if authorization_origin.blank?

    uri = URI.parse(authorization_origin)
    unless uri.scheme == "https" && uri.port == 443 && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.path.in?([ "", "/" ])
      errors.add(:authorization_origin, "must be an HTTPS origin without a path or credentials")
    end
  rescue URI::InvalidURIError
    errors.add(:authorization_origin, "must be a valid HTTPS origin")
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
