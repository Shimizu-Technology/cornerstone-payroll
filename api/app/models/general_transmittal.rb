# frozen_string_literal: true

class GeneralTransmittal < ApplicationRecord
  STATUSES = %w[draft generated].freeze

  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :items,
           -> { order(:position, :id) },
           class_name: "GeneralTransmittalItem",
           dependent: :destroy,
           inverse_of: :general_transmittal

  accepts_nested_attributes_for :items, allow_destroy: true

  before_validation :normalize_notes

  validates :title, presence: true
  validates :transmittal_date, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :must_have_at_least_one_item, if: :generated?

  scope :recent, -> { order(transmittal_date: :desc, created_at: :desc) }

  def generated?
    status == "generated"
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
    return if items.reject(&:marked_for_destruction?).any?

    errors.add(:items, "must include at least one item")
  end
end
