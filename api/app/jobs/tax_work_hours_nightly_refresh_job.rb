# frozen_string_literal: true

# Nightly refresh of last month and this month for every organization that
# has chosen its practice company. Does nothing until Cornerstone Tax is
# connected (CORNERSTONE_TAX_API_URL and PAYROLL_WORK_HOURS_SECRET).
class TaxWorkHoursNightlyRefreshJob < ApplicationJob
  queue_as :default

  def perform(today: PayrollBusinessClock.today)
    return unless TaxWorkHours::Configuration.current.connected?

    ClientProfitabilitySetting.where.not(practice_company_id: nil).find_each do |setting|
      next if WorkHourImport.in_progress.exists?(organization_id: setting.organization_id)

      import = WorkHourImport.create!(organization_id: setting.organization_id, trigger: "scheduled",
                                      range_start: today.prev_month.beginning_of_month, range_end: today)
      TaxWorkHours::Importer.call(import)
    end
  end
end
