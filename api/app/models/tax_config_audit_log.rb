# frozen_string_literal: true

# Immutable audit log for tax configuration changes.
# Records every create, update, activation, and deactivation.
class TaxConfigAuditLog < ApplicationRecord
  ACTIONS = %w[created updated activated deactivated].freeze

  belongs_to :annual_tax_config

  validates :action, presence: true, inclusion: { in: ACTIONS }

  # No updated_at - these records are immutable
  def readonly?
    persisted?
  end

  # Log a creation
  def self.log_created(config, user_id: nil, ip_address: nil)
    create!(
      annual_tax_config: config,
      user_id: user_id,
      action: "created",
      new_value: "Tax year #{config.tax_year} created",
      ip_address: ip_address
    )
  end

  # Log a field update
  def self.log_updated(config, field_name:, old_value:, new_value:, user_id: nil, ip_address: nil)
    create!(
      annual_tax_config: config,
      user_id: user_id,
      action: "updated",
      field_name: field_name,
      old_value: old_value.to_s,
      new_value: new_value.to_s,
      ip_address: ip_address
    )
  end

  # Log activation
  def self.log_activated(config, user_id: nil, ip_address: nil)
    create!(
      annual_tax_config: config,
      user_id: user_id,
      action: "activated",
      new_value: "Tax year #{config.tax_year} activated",
      ip_address: ip_address
    )
  end

  # Log deactivation
  def self.log_deactivated(config, user_id: nil, ip_address: nil)
    create!(
      annual_tax_config: config,
      user_id: user_id,
      action: "deactivated",
      new_value: "Tax year #{config.tax_year} deactivated",
      ip_address: ip_address
    )
  end
end
