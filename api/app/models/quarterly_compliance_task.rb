# frozen_string_literal: true

class QuarterlyComplianceTask < ApplicationRecord
  STATUSES = %w[not_started in_progress needs_review ready_to_file filed paid filed_and_paid not_required exception].freeze
  TASK_TYPES = QuarterlyCompliancePacket::TASK_TYPES

  belongs_to :quarterly_compliance_packet
  belongs_to :assigned_to, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :task_type, inclusion: { in: TASK_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :task_type, uniqueness: { scope: :quarterly_compliance_packet_id }
  validates :payment_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  before_validation :infer_status_from_dates

  def workflow_payload
    {
      id: id,
      task_type: task_type,
      title: title,
      status: status,
      due_date: due_date&.iso8601,
      internal_target_date: internal_target_date&.iso8601,
      assigned_to: assigned_to&.name,
      reviewed_by: reviewed_by&.name,
      reviewed_at: reviewed_at&.iso8601,
      filed_at: filed_at&.iso8601,
      paid_at: paid_at&.iso8601,
      payment_amount: payment_amount&.to_f,
      filing_confirmation_number: filing_confirmation_number,
      payment_confirmation_number: payment_confirmation_number,
      proof_attached: proof_attached,
      notes: notes,
      data: data
    }
  end

  def title
    {
      "form_500" => "Form 500 deposits",
      "w1" => "Guam W-1 quarterly return",
      "swica" => "SWICA / SW-2 wage report",
      "federal_941" => "Federal Form 941",
      "schedule_b" => "Schedule B liability schedule"
    }.fetch(task_type, task_type.humanize)
  end

  private

  def infer_status_from_dates
    return unless will_save_change_to_filed_at? || will_save_change_to_paid_at?

    self.status = "filed_and_paid" if filed_at.present? && paid_at.present? && status.in?(%w[not_started in_progress ready_to_file filed paid])
    self.status = "filed" if filed_at.present? && paid_at.blank? && status.in?(%w[not_started in_progress ready_to_file filed_and_paid])
    self.status = "paid" if paid_at.present? && filed_at.blank? && status.in?(%w[not_started in_progress ready_to_file filed_and_paid])
    self.status = "ready_to_file" if filed_at.blank? && paid_at.blank? && status.in?(%w[filed paid filed_and_paid])
  end
end
