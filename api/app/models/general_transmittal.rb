# frozen_string_literal: true

class GeneralTransmittal < ApplicationRecord
  STATUSES = %w[draft generated].freeze
  SOURCE_KINDS = %w[standalone pay_period].freeze

  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  belongs_to :pay_period, optional: true

  has_many :items,
           -> { order(:position, :id) },
           class_name: "GeneralTransmittalItem",
           dependent: :destroy,
           inverse_of: :general_transmittal
  has_many :artifacts,
           -> { newest_first },
           class_name: "GeneralTransmittalArtifact",
           dependent: :restrict_with_error,
           inverse_of: :general_transmittal

  accepts_nested_attributes_for :items, allow_destroy: true

  before_validation :normalize_notes

  validates :title, presence: true
  validates :transmittal_date, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :source_kind, presence: true, inclusion: { in: SOURCE_KINDS }
  validates :pay_period_id, uniqueness: true, allow_nil: true
  validates :pay_period_id, presence: true, if: :pay_period_source?
  validate :must_have_at_least_one_item, if: :generated?
  validate :items_have_unique_sources
  validate :pay_period_matches_company

  scope :recent, -> { order(transmittal_date: :desc, created_at: :desc) }

  def generated?
    status == "generated"
  end

  def pay_period_source?
    source_kind == "pay_period"
  end

  def included_items
    items.reject(&:marked_for_destruction?).select(&:included?)
  end

  def mark_generated!(actor:)
    update!(
      status: "generated",
      generated_at: Time.current,
      updated_by: actor
    )
  end

  private

  def normalize_notes
    self.notes = Array(notes).map(&:to_s).map(&:strip).reject(&:blank?)
  end

  def must_have_at_least_one_item
    return if items.reject(&:marked_for_destruction?).any?(&:included?)

    errors.add(:items, "must include at least one item")
  end

  def pay_period_matches_company
    return if pay_period.blank? || company_id.blank?
    return if pay_period.company_id == company_id

    errors.add(:pay_period_id, "must belong to the transmittal company")
  end

  def items_have_unique_sources
    seen_sources = {}

    items.reject(&:marked_for_destruction?).each do |item|
      next unless item.source_type.present? && item.source_id.present?

      source_key = [ item.source_type, item.source_id.to_s ]
      if seen_sources[source_key]
        errors.add(:items, "#{item.source_type} #{item.source_id} has already been added to this transmittal")
        item.errors.add(:source_id, "has already been added to this transmittal")
      else
        seen_sources[source_key] = true
      end
    end
  end
end
