# frozen_string_literal: true

require "digest"

class TrainingReplayBenchmark < ApplicationRecord
  SOURCE_STATUSES = %w[calculated approved committed].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :source_company, class_name: "Company"
  belongs_to :source_pay_period, class_name: "PayPeriod"
  belongs_to :captured_by, class_name: "User", optional: true

  validates :source_status, inclusion: { in: SOURCE_STATUSES }
  validates :snapshot, presence: true
  validates :sha256, :captured_at, presence: true
  validates :pay_period_id, uniqueness: true
  validates :source_pay_period_id, uniqueness: { scope: :company_id }
  validate :lineage_is_valid
  validate :checksum_is_valid

  before_update :prevent_mutation
  before_destroy :prevent_destroy

  def period_snapshot
    snapshot.fetch("period")
  end

  def item_snapshots
    snapshot.fetch("items")
  end

  def self.checksum_for(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical_value(value)))
  end

  def self.canonical_value(value)
    case value
    when Hash
      value.deep_stringify_keys.sort.to_h.transform_values { |nested| canonical_value(nested) }
    when Array
      value.map { |nested| canonical_value(nested) }
    else
      value
    end
  end
  private_class_method :canonical_value

  private

  def lineage_is_valid
    return if company.blank? || pay_period.blank? || source_company.blank? || source_pay_period.blank?

    errors.add(:pay_period, "must belong to the training workspace") unless pay_period.company_id == company_id
    errors.add(:pay_period, "must be a practice payroll") unless pay_period.training_practice?
    errors.add(:source_pay_period, "must belong to the live source client") unless source_pay_period.company_id == source_company_id
    unless company.training_replay? && company.migration_source_company_id == source_company_id
      errors.add(:company, "must be a training replay for the source client")
    end
  end

  def checksum_is_valid
    return if snapshot.blank? || sha256.blank?

    expected = self.class.checksum_for(snapshot)
    errors.add(:sha256, "does not match the frozen benchmark") unless ActiveSupport::SecurityUtils.secure_compare(expected, sha256)
  end

  def prevent_mutation
    errors.add(:base, "Training replay benchmarks are immutable")
    throw :abort
  end

  def prevent_destroy
    errors.add(:base, "Training replay benchmark history is immutable")
    throw :abort
  end
end
