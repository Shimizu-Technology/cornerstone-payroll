# frozen_string_literal: true

# Run through Rails runner against the production service. This is deliberately
# read-only: it reads committed payroll items and AIRE's manual-review endpoint,
# then writes one JSON document to stdout. It does not update either database.

require "json"

abort "Set AIRE_ROLLOUT_READ_ONLY_EXPORT=yes" unless ENV["AIRE_ROLLOUT_READ_ONLY_EXPORT"] == "yes"
abort "Usage: rails runner export_aire_rollout_increment.rb PAY_PERIOD_ID=DELIVERED_ON [...]" if ARGV.empty?

company = Company.find(Integer(ENV.fetch("AIRE_ROLLOUT_COMPANY_ID"), 10))
source = company.time_tracking_sources.find(Integer(ENV.fetch("AIRE_ROLLOUT_SOURCE_ID"), 10))
actor = User.find(Integer(ENV.fetch("AIRE_ROLLOUT_ACTOR_ID"), 10))
actor_client_supported = TimeTracking::Client.respond_to?(:for_payroll_actor)
client = if actor_client_supported
  TimeTracking::Client.for_payroll_actor(source, actor: actor)
else
  # The deployed client predating account linking still supports the same
  # read-only review endpoint through the source's shared-secret transport.
  TimeTracking::Client.new(source)
end

pay_periods = ARGV.map do |argument|
  pay_period_id, delivered_on = argument.split("=", 2)
  abort "Expected PAY_PERIOD_ID=DELIVERED_ON, got #{argument.inspect}" if pay_period_id.blank? || delivered_on.blank?

  period = company.pay_periods.includes(payroll_items: :employee).find(Integer(pay_period_id, 10))
  abort "Pay period #{period.id} is not committed" unless period.committed?

  checks = period.payroll_items.filter_map do |item|
    next unless item.net_pay.to_d.positive?
    abort "Payroll item #{item.id} is not a paper check" unless item.effective_payment_delivery_method == "paper_check"
    abort "Payroll item #{item.id} has no check number" if item.check_number.blank?

    {
      payroll_item_id: item.id,
      employee_id: item.employee_id,
      employee_name: item.employee.full_name,
      employment_type: item.employee.employment_type,
      payment_delivery_method: item.effective_payment_delivery_method,
      check_number: item.check_number,
      net_pay: format("%.2f", item.net_pay),
      regular_hours: format("%.2f", item.hours_worked),
      overtime_hours: format("%.2f", item.overtime_hours)
    }
  end

  review = if actor_client_supported
    client.payroll_cockpit_manual_review(
      start_date: period.start_date.iso8601,
      end_date: period.end_date.iso8601,
      external_pay_period_id: period.id
    )
  else
    # Ask the deployed AIRE endpoint for its current, actor-scoped shape even
    # when the deployed payroll client predates actor-aware review support.
    query = {
      start_date: period.start_date.iso8601,
      end_date: period.end_date.iso8601,
      external_pay_period_id: period.id
    }
    uri = client.send(:payroll_cockpit_uri, "/manual_review", query)
    client.send(
      :request_json,
      uri,
      validate_source: false,
      headers: { "X-Cornerstone-Actor-Id" => actor.id.to_s },
      surface_remote_error: true
    )
  end

  current_employees = Array(review.fetch("employees")).filter_map do |employee|
    adjustments = Array(employee.fetch("adjustments")).select do |adjustment|
      Date.iso8601(adjustment.fetch("original_work_date")).between?(period.start_date, period.end_date)
    end
    next if adjustments.empty?

    employee.slice("source_user_id", "source_user_uuid", "display_name").merge("adjustments" => adjustments)
  end

  {
    pay_period_id: period.id,
    start_date: period.start_date.iso8601,
    end_date: period.end_date.iso8601,
    delivered_on: Date.iso8601(delivered_on).iso8601,
    checks: checks,
    aire_employees: current_employees,
    excluded_source_entry_ids: Array(review["exclusions"]).map { |row| row["source_time_entry_id"].to_s }.reject(&:blank?).sort
  }
end

puts JSON.generate(version: 1, company_id: company.id, source_id: source.id, actor_id: actor.id, pay_periods: pay_periods)
