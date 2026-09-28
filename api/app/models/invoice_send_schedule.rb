# frozen_string_literal: true

class InvoiceSendSchedule < ApplicationRecord
  STATUSES = %w[pending queued sending sent failed cancelled].freeze
  SEND_LOCK_NAMESPACE = 714_291

  belongs_to :organization
  belongs_to :invoice
  belongs_to :created_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :send_at, presence: true
  validate :invoice_belongs_to_organization
  validate :recipients_are_valid

  scope :due, ->(at = Time.current) { where(status: "pending").where("send_at <= ?", at) }

  def self.normalize_recipients(values)
    Array(values).flat_map { |value| value.to_s.split(/[;,]/) }.map(&:strip).reject(&:blank?).uniq
  end

  # A session advisory lock survives individual database transactions, so
  # provider I/O need not hold a row lock or an open transaction.
  def self.with_active_send_lock(id)
    connection_pool.with_connection do |connection|
      key = Integer(id)
      locked = connection.exec_query("SELECT pg_try_advisory_lock($1, $2)", "InvoiceSendSchedule send lock",
                                     advisory_lock_binds(key)).rows.first.first
      return false unless ActiveModel::Type::Boolean.new.cast(locked)

      begin
        yield
      ensure
        connection.exec_query("SELECT pg_advisory_unlock($1, $2)", "InvoiceSendSchedule send unlock",
                              advisory_lock_binds(key))
      end
    end
  end

  # Call only inside a transaction. A recovery attempt cannot overtake a sender
  # that still holds the session lock for this schedule.
  def self.recovery_lock_available?(id)
    key = Integer(id)
    locked = connection.exec_query("SELECT pg_try_advisory_xact_lock($1, $2)", "InvoiceSendSchedule recovery lock",
                                   advisory_lock_binds(key)).rows.first.first
    ActiveModel::Type::Boolean.new.cast(locked)
  end

  def self.advisory_lock_binds(key)
    [ SEND_LOCK_NAMESPACE, key ].map.with_index do |value, index|
      ActiveRecord::Relation::QueryAttribute.new("lock_key_#{index}", value, ActiveRecord::Type::Integer.new)
    end
  end
  private_class_method :advisory_lock_binds

  private

  def invoice_belongs_to_organization
    return if invoice.blank? || organization.blank? || invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end

  def recipients_are_valid
    if recipients.blank? || recipients.size > 10 || recipients.any? { |email| email !~ URI::MailTo::EMAIL_REGEXP }
      errors.add(:recipients, "must contain 1 to 10 valid email addresses")
    end
  end
end
