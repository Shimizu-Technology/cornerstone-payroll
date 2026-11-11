# frozen_string_literal: true

# A published, scheduled AIRE period: Oct 1-15, payday Oct 31, policy lock
# Oct 22 at 5:00 PM Guam (seven days after the Oct 15 payday). Admin lock
# times may fall from Oct 16 00:00 through Oct 29 11:59 PM.
RSpec.shared_context "aire cutoff change fixture" do
  include ActiveSupport::Testing::TimeHelpers

  let(:guam) { Time.find_zone!("Pacific/Guam") }
  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:org_admin) { create(:user, company: company, organization: company.organization, role: "org_admin", name: "Chels") }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services", cutoff_enforcement_starts_on: Date.new(2026, 10, 1))
  end
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company, frequency: "semimonthly", period_rule: "semimonthly",
      pay_date_rule: "semimonthly_15th_and_month_end", time_tracking_cutoff_rule: "after_previous_regular_payday",
      time_tracking_cutoff_days: 7, payroll_cutoff_at_minutes: 1020, timezone: "Pacific/Guam",
      source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: org_admin,
      confirmed_at: Time.current, effective_on: Date.new(2026, 1, 1), notes: "Confirmed semimonthly calendar"
    )
  end
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
      source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: org_admin,
      confirmed_at: Time.current, effective_on: Date.new(2026, 1, 1), notes: "Confirmed Sunday workweek"
    )
  end
  let!(:previous_regular) do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 9, 16), end_date: Date.new(2026, 9, 30), pay_date: Date.new(2026, 10, 15))
  end
  let(:pay_period) do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 15), pay_date: Date.new(2026, 10, 31))
  end
  let(:policy_cutoff) { guam.local(2026, 10, 22, 17) }

  before do
    travel_to(guam.local(2026, 10, 17, 9))
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
  end
  after { travel_back }

  # Publishes version 1 and records AIRE's delivery confirmation.
  def publish_delivered_calendar!
    publication = AirePayrollCalendar::Publisher.new(pay_period: pay_period, source: source, actor: org_admin).call.publication
    publication.update_columns(delivery_status: "delivered", delivered_at: Time.current, next_delivery_attempt_at: nil)
    publication
  end

  # Records that AIRE applied a publication.
  def confirm_delivery!(publication)
    publication.update_columns(delivery_status: "delivered", delivered_at: Time.current, next_delivery_attempt_at: nil)
    publication
  end

  # Records that AIRE answered and refused a publication.
  def reject_delivery!(publication, message = "cutoff_at must be in the future when published", status: 422)
    publication.update_columns(delivery_status: "failed", delivery_attempts: 1, last_response_status: status,
      last_error: "TimeTracking::Client::Error: #{message}", next_delivery_attempt_at: nil)
    publication
  end

  def aire_actor(role: "admin", name: "Chels Admin")
    { "system" => "aire_services", "user_id" => 2, "name" => name, "email" => "chels@example.com", "role" => role }
  end
end
