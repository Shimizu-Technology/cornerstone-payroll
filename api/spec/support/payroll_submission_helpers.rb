# frozen_string_literal: true

# Synthetic pay-period submission fixtures. No real client data.
module PayrollSubmissionHelpers
  def synthetic_pdf(name = "payroll_2026-11-17.pdf", marker: SecureRandom.hex(6))
    portal_upload(name, "%PDF-1.4\n% synthetic #{marker}\n%%EOF\n", "application/pdf")
  end

  def synthetic_workbook(name = "changes.xlsx")
    portal_upload(name, office_zip, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  def manual_biweekly_schedule!(company, anchor: nil, effective_on: Date.new(2026, 1, 1))
    CompanyPaySchedule.create!(company: company, frequency: "biweekly", period_rule: anchor ? "biweekly" : "manual",
      period_start_weekday: anchor&.wday, period_anchor_date: anchor, pay_date_rule: "manual", timezone: "Pacific/Guam",
      source: "operator_confirmed", confirmation_status: "needs_confirmation", effective_on: effective_on)
  end

  def stub_portal_user(controller, user, company)
    allow_any_instance_of(controller).to receive(:current_user) { User.find(user.id) }
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
  end
end

RSpec.configure do |config|
  config.include PayrollSubmissionHelpers
end
