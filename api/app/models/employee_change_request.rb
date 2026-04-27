# frozen_string_literal: true

class EmployeeChangeRequest < ApplicationRecord
  belongs_to :company
  belongs_to :employee
  belongs_to :requested_by, class_name: "User"
  belongs_to :reviewed_by, class_name: "User", optional: true

  enum :status, { pending: 0, approved: 1, rejected: 2 }

  validates :proposed_changes, presence: true

  scope :recent_first, -> { order(created_at: :desc) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }

  def apply!(actor:, review_notes: nil)
    ActiveRecord::Base.transaction do
      apply_proposed_changes!
      update!(
        status: :approved,
        reviewed_by: actor,
        review_notes: review_notes,
        reviewed_at: Time.current
      )
    end
  end

  def reject!(actor:, review_notes:)
    update!(
      status: :rejected,
      reviewed_by: actor,
      review_notes: review_notes,
      reviewed_at: Time.current
    )
  end

  private

  def apply_proposed_changes!
    attrs = proposed_changes.deep_symbolize_keys
    wage_rates = attrs.delete(:wage_rates)

    employee.update!(attrs) if attrs.present?
    return unless wage_rates.present?

    EmployeeWageRateSyncService.new(employee: employee, wage_rates: wage_rates).sync!
  end
end
