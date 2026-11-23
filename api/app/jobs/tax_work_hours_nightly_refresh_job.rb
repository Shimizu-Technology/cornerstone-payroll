# frozen_string_literal: true

# Nightly refresh of last month and this month for every organization that
# has chosen its practice company. Does nothing until Cornerstone Tax is
# connected (CORNERSTONE_TAX_API_URL and PAYROLL_WORK_HOURS_SECRET). Uses the
# same reservation as the manual refresh, so the two never run at once.
class TaxWorkHoursNightlyRefreshJob < ApplicationJob
  self.rls_mode = :exempt_tables_only

  queue_as :default

  def perform(today: PayrollBusinessClock.today)
    return unless TaxWorkHours::Configuration.current.connected?

    ClientProfitabilitySetting.where.not(practice_company_id: nil).includes(:organization).find_each do |setting|
      import = WorkHourImport.reserve!(organization: setting.organization, trigger: "scheduled",
                                       range_start: today.prev_month.beginning_of_month, range_end: today)
      TaxWorkHours::Importer.call(import)
    rescue WorkHourImport::Busy
      next
    end
  end
end
