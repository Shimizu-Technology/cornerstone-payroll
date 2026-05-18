# frozen_string_literal: true

class QuarterlyCompliancePacket < ApplicationRecord
  STATUSES = %w[not_started in_progress needs_review ready_to_file filed paid filed_and_paid not_required exception].freeze
  MONTHS_BY_QUARTER = QuarterlyCompliancePacketBuilder::MONTHS_BY_QUARTER
  TASK_TYPES = %w[form_500 w1 swica federal_941 schedule_b].freeze

  belongs_to :company
  belongs_to :assigned_to, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :quarterly_compliance_tasks, dependent: :destroy

  validates :year, numericality: { only_integer: true, greater_than: 2000 }
  validates :quarter, inclusion: { in: 1..4 }
  validates :status, inclusion: { in: STATUSES }
  validates :company_id, uniqueness: { scope: [ :year, :quarter ] }

  before_validation :set_due_dates, on: :create

  def self.find_or_create_for!(company:, year:, quarter:, user: nil)
    packet = find_or_initialize_by(company: company, year: year.to_i, quarter: quarter.to_i)
    packet.assigned_to ||= user if user&.staff_member?
    packet.save! if packet.new_record? || packet.changed?
    packet.ensure_default_tasks!
    packet
  end

  def ensure_default_tasks!
    TASK_TYPES.each do |task_type|
      quarterly_compliance_tasks.find_or_create_by!(task_type: task_type) do |task|
        task.status = "not_started"
        task.due_date = official_due_date
        task.internal_target_date = internal_target_date
        task.assigned_to = assigned_to
      end
    end
  end

  def workflow_payload
    {
      id: id,
      status: status,
      assigned_to: assigned_to&.name,
      reviewed_by: reviewed_by&.name,
      reviewed_at: reviewed_at&.iso8601,
      notes: notes,
      tasks: quarterly_compliance_tasks.order(:id).map(&:workflow_payload)
    }
  end

  private

  def set_due_dates
    months = MONTHS_BY_QUARTER.fetch(quarter)
    quarter_end = Date.new(year, months.last, -1)
    self.official_due_date ||= (quarter_end >> 1).end_of_month
    self.internal_target_date ||= quarter_end + 7.days
  end
end
