# frozen_string_literal: true

class TimeTrackingCategoryMapping < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :reviewed_by, class_name: "User"
  validates :source_category_key, presence: true, uniqueness: { scope: :time_tracking_source_id }
  validates :reason, :evidence, length: { in: 10..2_000 }
  validates :earning_label, presence: true, if: :import_enabled?
  validates :history_through_on, presence: true, if: :historical_attribution?
  validate :valid_scope

  def self.category_key(category)
    category ||= {}
    value = category["key"].presence || category[:key].presence || category["name"].presence || category[:name]
    value.present? ? normalized(value).delete_prefix("aire ").delete_suffix(" hours").tr(" ", "_") : "uncategorized"
  end

  def self.normalized(value)
    value.to_s.unicode_normalize(:nfc).downcase.gsub(/[^\p{Alnum}]+/u, " ").squish
  end

  def matching_rate(rates)
    [ earning_label, fallback_earning_label ].compact_blank.each do |label|
      matches = rates.select { |rate| rate.active? && rate.rate&.positive? && self.class.normalized(rate.label) == self.class.normalized(label) }
      return nil if matches.many?
      return matches.sole if matches.one?
    end
    nil
  end

  def required_rate_description
    [ earning_label, fallback_earning_label ].compact_blank.join(" or ")
  end

  def historical_for?(employee_id, date, run_id: nil)
    limits = historical_run_limits[employee_id.to_s]
    historical_attribution? && date <= history_through_on && historical_employee_ids.include?(employee_id) &&
      (limits.nil? || limits.include?(run_id))
  end

  private

  def valid_scope
    errors.add(:company, "must own the AIRE source") unless time_tracking_source&.company_id == company_id && time_tracking_source&.source_type == "aire_services"
    ids = historical_employee_ids
    limits = historical_run_limits
    valid_limits = ids.is_a?(Array) && limits.is_a?(Hash) && limits.all? do |id, runs|
      ids.map(&:to_s).include?(id) && runs.is_a?(Array) && runs.any? && runs.uniq == runs && runs.all? { |run| run.is_a?(Integer) && run.positive? } &&
        PayPeriod.where(company_id: company_id, status: "committed", id: runs).count == runs.length
    end
    errors.add(:historical_run_limits, "must identify committed company-owned runs in the employee scope") unless valid_limits
    unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) } && ids.uniq == ids && Employee.where(company_id: company_id, id: ids).count == ids.length
      errors.add(:historical_employee_ids, "must be distinct employees of this company")
    end
  end
end
