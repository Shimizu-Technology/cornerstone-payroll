# frozen_string_literal: true

class PostEmployeePayStubsJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform(company_id = nil)
    now = Time.current
    guam_now = now.in_time_zone(PayStubGenerator::GUAM_TIME_ZONE)
    through_date = guam_now.hour >= 6 ? guam_now.to_date : guam_now.to_date.yesterday

    # Demo companies post like a live client; the stubs stay inside Payroll.
    companies = Company.operating
    companies = companies.where(id: company_id) if company_id
    companies.find_each do |company|
      features = CompanyFeatures.for(company)
      next unless features.employee_portal_feature?(:stubs)

      notice_since = features.employee_stubs_enabled_since

      due_items(company.id, through_date).find_each do |item|
        EmployeeDocuments::PostPayStub.new(item, now: now, notice_since: notice_since).call
      rescue StandardError => e
        Rails.logger.error("Employee pay stub posting failed for payroll item #{item.id}: #{e.class}")
        Rails.error.report(e, handled: true, context: { payroll_item_id: item.id })
      end
    end
  end

  private

  def due_items(company_id, through_date)
    eligible_periods = PayPeriod.reportable_committed.where(company_id: company_id, pay_date: ..through_date)
    items = PayrollItem.joins(:pay_period, :employee).where(company_id: company_id)
    posted = EmployeeDocument.posted.where(company_id: company_id).where.not(payroll_item_id: nil)
    pending = items.reportable.where(pay_period_id: eligible_periods, payroll_reversed_at: nil, voided: false)
      .where("COALESCE(payroll_items.net_pay, 0) <= 0 OR payroll_items.payment_delivery_method = 'direct_deposit' OR payroll_items.check_number IS NOT NULL")
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM employee_documents
          WHERE employee_documents.company_id = payroll_items.company_id
            AND employee_documents.payroll_item_id = payroll_items.id
            AND employee_documents.status = 'posted'
            AND employee_documents.payroll_facts_checked_at >= GREATEST(payroll_items.updated_at, pay_periods.updated_at, employees.updated_at)
            AND (payroll_items.correction_for_payroll_item_id IS NULL OR employee_documents.replaces_document_id IS NOT NULL)
        )
      SQL
    withdrawn = items.where(id: posted.select(:payroll_item_id))
      .where.not(pay_period_id: PayPeriod.reportable_committed.where(company_id: company_id))
    reversed = items.where(id: posted.select(:payroll_item_id)).where.not(payroll_reversed_at: nil)
    canceled = items.where(id: posted.select(:payroll_item_id), voided: true)
    pending.or(withdrawn).or(reversed).or(canceled)
  end
end
