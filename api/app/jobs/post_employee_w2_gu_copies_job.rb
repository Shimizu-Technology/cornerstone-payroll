# frozen_string_literal: true

# Posts one company's W-2GU employee copies to the employee app for a tax
# year (M4-5), after staff ask for it. Idempotent: a rerun posts only the
# copies still missing (EmployeeDocuments::PostW2GuCopies).
class PostEmployeeW2GuCopiesJob < ApplicationJob
  class InputsChanged < StandardError; end

  self.rls_mode = :company

  queue_as :default
  retry_on InputsChanged, wait: 1.minute, attempts: 3

  def perform(company_id, tax_year, user_id = nil)
    company = Company.find(company_id)
    user = user_id && User.find_by(id: user_id)
    result = EmployeeDocuments::PostW2GuCopies.new(company: company, year: tax_year, user: user).call
    raise InputsChanged if result.status == :changed

    Rails.logger.info("[PostEmployeeW2GuCopiesJob] company=#{company_id} year=#{tax_year} status=#{result.status} posted=#{result.posted_count}")
    result
  end
end
