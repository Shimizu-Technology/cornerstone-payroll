# frozen_string_literal: true

# A saved alignment/layout preset for a particular physical printer.
# Scoped to the organization so everyone in the same accounting firm can reuse
# the same calibration across that firm's client companies.
class PrinterProfile < ApplicationRecord
  belongs_to :organization
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  belongs_to :source_profile, class_name: "PrinterProfile", optional: true
  has_many :derived_profiles, class_name: "PrinterProfile", foreign_key: :source_profile_id,
    dependent: :nullify, inverse_of: :source_profile
  has_many :user_printer_profile_selections, dependent: :destroy
  has_many :check_print_runs, dependent: :nullify

  validates :name, presence: true,
    uniqueness: { scope: :organization_id, conditions: -> { where(archived_at: nil) } }
  validates :check_stock_type, inclusion: { in: Company::CHECK_STOCK_TYPES }
  validates :check_offset_x, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :check_offset_y, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :revision_number, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :selected_profile_stock_type_is_stable

  scope :active, -> { where(archived_at: nil) }
  scope :ordered, -> { active.order(:name) }

  def archived?
    archived_at.present?
  end

  def calibration_locked?
    user_printer_profile_selections.exists? || check_print_runs.exists?
  end

  def next_available_copy_name
    base_name = "#{name} copy"
    candidate = base_name
    suffix = 2
    while organization.printer_profiles.active.where("LOWER(name) = ?", candidate.downcase).exists?
      candidate = "#{base_name} #{suffix}"
      suffix += 1
    end
    candidate
  end

  # Only one default profile per organization — the rest get cleared automatically
  # when a new default is set so we never end up with multiple defaults.
  after_save :clear_other_defaults, if: :is_default?

  private

  def clear_other_defaults
    self.class.transaction do
      PrinterProfile.where(organization_id: organization_id, is_default: true)
                    .where.not(id: id)
                    .update_all(is_default: false)
    end
  end

  def selected_profile_stock_type_is_stable
    return unless will_save_change_to_check_stock_type?
    return unless user_printer_profile_selections.exists?

    errors.add(:check_stock_type, "cannot change while operators are using this profile; create a new profile instead")
  end
end
