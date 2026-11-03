# frozen_string_literal: true

class TimeTrackingEarningChoice < ApplicationRecord
  belongs_to :time_tracking_source
  belongs_to :employee
  belongs_to :employee_wage_rate
  belongs_to :reviewed_by, class_name: "User"
  validate :same_employee_and_company

  def self.solo_category?(category)
    [ category[:key], category["key"], category[:name], category["name"] ].any? do |value|
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish.delete_suffix(" hours") == "solo"
    end
  end

  def current_rate
    rate = employee_wage_rate
    rate if rate.active? && rate_snapshot == rate.attributes.slice("id", "employee_id", "label", "rate", "active").as_json
  end

  private

  def same_employee_and_company
    unless employee&.company_id == time_tracking_source&.company_id && employee_wage_rate&.employee_id == employee_id
      errors.add(:employee_wage_rate, "must belong to this client's mapped employee")
    end
  end
end
