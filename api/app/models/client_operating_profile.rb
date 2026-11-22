# frozen_string_literal: true

class ClientOperatingProfile < ApplicationRecord
  OFFERINGS = OperatingProfileCatalog::OFFERINGS
  HOURS_SOURCES = OperatingProfileCatalog::HOURS_SOURCES

  belongs_to :company
  belongs_to :changed_by, class_name: "User", optional: true

  before_validation :normalize_attributes

  validates :effective_on, presence: true, uniqueness: { scope: :company_id }
  validates :version, presence: true,
                      numericality: { only_integer: true, greater_than_or_equal_to: 1 },
                      uniqueness: { scope: :company_id }
  validates :offering, inclusion: { in: OFFERINGS }
  validates :hours_source, inclusion: { in: HOURS_SOURCES }
  validates :client_portal_enabled, inclusion: { in: [ true, false ] }
  validates :employee_portal_enabled, inclusion: { in: [ true, false ] }

  validate :ends_on_not_before_effective_on
  validate :intake_adapter_matches_hours_source
  validate :no_overlapping_versions
  validate :options_valid_against_catalog

  scope :active_on, ->(date) {
    resolved_date = date.to_date
    where("effective_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", resolved_date, resolved_date)
      .order(effective_on: :desc, version: :desc)
  }

  scope :history_order, -> { order(effective_on: :desc, version: :desc, id: :desc) }

  def self.for_date(company_id, date = PayrollBusinessClock.today)
    active_on(date).find_by(company_id: company_id)
  end

  def option_value(key)
    OperatingProfileCatalog.option_value(options, key)
  end

  def resolved_options
    OperatingProfileCatalog.resolve_options(options)
  end

  def serialize_payload
    {
      id: id,
      company_id: company_id,
      effective_on: effective_on&.iso8601,
      ends_on: ends_on&.iso8601,
      version: version,
      lock_version: lock_version,
      offering: offering,
      hours_source: hours_source,
      intake_adapter: intake_adapter,
      client_portal_enabled: client_portal_enabled,
      employee_portal_enabled: employee_portal_enabled,
      options: resolved_options,
      changed_by_id: changed_by_id,
      reason: reason,
      confirmed_at: confirmed_at&.utc&.iso8601,
      persisted: persisted?,
      created_at: created_at&.utc&.iso8601,
      updated_at: updated_at&.utc&.iso8601
    }
  end

  private

  def normalize_attributes
    self.intake_adapter = nil if intake_adapter.blank?
    if options.nil?
      self.options = {}
    elsif options.is_a?(Hash)
      self.options = options.deep_stringify_keys
    end
  end

  def ends_on_not_before_effective_on
    return if ends_on.blank? || effective_on.blank? || ends_on >= effective_on

    errors.add(:ends_on, "must be on or after the effective date")
  end

  def intake_adapter_matches_hours_source
    if hours_source == "intake_adapter"
      if intake_adapter.blank?
        errors.add(:intake_adapter, "is required when hours_source is intake_adapter")
      elsif !OperatingProfileCatalog.registered_intake_adapters.include?(intake_adapter)
        errors.add(:intake_adapter, "must be a registered intake adapter")
      end
    elsif intake_adapter.present?
      errors.add(:intake_adapter, "must be blank unless hours_source is intake_adapter")
    end
  end

  def no_overlapping_versions
    return if company_id.blank? || effective_on.blank?
    return if ends_on.present? && ends_on < effective_on

    scope = self.class.where(company_id: company_id)
    scope = scope.where.not(id: id) if persisted?

    overlaps = if ends_on.present?
      scope.where("effective_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", ends_on, effective_on)
    else
      scope.where("ends_on IS NULL OR ends_on >= ?", effective_on)
    end

    return unless overlaps.exists?

    errors.add(:base, "Operating profile effective dates overlap an existing version for this company")
  end

  def options_valid_against_catalog
    OperatingProfileCatalog.validate_options(options, intake_adapter: intake_adapter).each do |message|
      errors.add(:options, message)
    end
  end
end
