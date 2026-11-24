# frozen_string_literal: true

class PostEmployeePayStubsJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform
    now = Time.current
    guam_now = now.in_time_zone(PayStubGenerator::GUAM_TIME_ZONE)
    through_date = guam_now.hour >= 6 ? guam_now.to_date : guam_now.to_date.yesterday

    Company.where(payroll_environment: "live").find_each do |company|
      next unless CompanyFeatures.for(company).employee_portal_feature?(:stubs)

      due_items(company.id, through_date).find_each do |item|
        EmployeeDocuments::PostPayStub.new(item, now: now).call
      rescue R2StorageService::UploadError, R2StorageService::ConfigurationError => e
        Rails.logger.error("Employee pay stub posting failed for payroll item #{item.id}: #{e.class}")
      end
    end
  end

  private

  def due_items(company_id, through_date)
    eligible_periods = PayPeriod.reportable_committed.where(company_id: company_id, pay_date: ..through_date)
    items = PayrollItem.where(company_id: company_id)
    posted = EmployeeDocument.posted.where(company_id: company_id).where.not(payroll_item_id: nil)
    pending = items.reportable.where(pay_period_id: eligible_periods, payroll_reversed_at: nil)
      .where("COALESCE(payroll_items.net_pay, 0) <= 0 OR payroll_items.payment_delivery_method = 'direct_deposit' OR payroll_items.check_number IS NOT NULL")
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM employee_documents
          WHERE employee_documents.company_id = payroll_items.company_id
            AND employee_documents.payroll_item_id = payroll_items.id
            AND employee_documents.status = 'posted'
            AND employee_documents.posted_at >= payroll_items.updated_at
        )
      SQL
    withdrawn = items.where(id: posted.select(:payroll_item_id))
      .where.not(pay_period_id: PayPeriod.reportable_committed.where(company_id: company_id))
    reversed = items.where(id: posted.select(:payroll_item_id)).where.not(payroll_reversed_at: nil)
    pending.or(withdrawn).or(reversed)
  end
end
