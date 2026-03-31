class PunchEntry < ApplicationRecord
  belongs_to :timecard

  enum :review_state, { unresolved: 0, approved: 1 }

  validates :reviewed_by_name, presence: true, if: :approved?

  before_save :calculate_hours
  before_save :sync_day_of_week
  before_validation :sync_review_audit_fields
  before_update :reset_review_state_if_attention_changed
  after_commit :require_rereview_if_changed, on: :update

  def calculate_hours
    pairs = punch_pairs
    return unless pairs.any?

    worked = pairs.sum { |pin, pout| (pout - pin) / 3600.0 }
    self.hours_worked = [worked, 0].max.round(2)
  end

  def needs_attention?
    return false if blank_day?

    missing_core_punch? || low_confidence? || notes.present?
  end

  def low_confidence?
    confidence.to_f < 0.85
  end

  def all_punch_fields
    [clock_in, lunch_out, lunch_in, clock_out, in3, out3]
  end

  def blank_day?
    all_punch_fields.all?(&:blank?) && (notes.blank? || blank_row_note?)
  end

  def missing_core_punch?
    punch_count.positive? && (first_in.blank? || last_out.blank?)
  end

  def punch_count
    all_punch_fields.count(&:present?)
  end

  def first_in
    clock_in
  end

  def last_out
    out3.presence || clock_out
  end

  def blank_row_note?
    notes.to_s.strip.match?(/\Ablank row\.?\z/i)
  end

  private

  def sync_day_of_week
    return unless date_changed? && date.present?
    self.day_of_week = date.strftime('%a')
  end

  def sync_review_audit_fields
    if unresolved?
      self.reviewed_by_name = nil
      self.reviewed_at = nil
    elsif approved?
      self.reviewed_at = Time.current if reviewed_at.blank? || will_save_change_to_review_state? || will_save_change_to_reviewed_by_name?
    end
  end

  def punch_pairs
    ordered = [clock_in, lunch_out, lunch_in, clock_out, in3, out3].compact
    ordered.each_slice(2).select { |pair| pair.size == 2 }
  end

  def reset_review_state_if_attention_changed
    changed_fields = changes_to_save.keys
    attention_fields = %w[clock_in clock_out lunch_out lunch_in in3 out3 notes confidence]
    return if (changed_fields & attention_fields).empty?
    return unless needs_attention?

    self.review_state = :unresolved
  end

  def require_rereview_if_changed
    return unless saved_changes?
    return unless timecard.reviewed?

    changed_fields = saved_changes.keys - %w[updated_at manually_edited]
    return if changed_fields.empty?

    timecard.clear_review_audit!
  end
end
