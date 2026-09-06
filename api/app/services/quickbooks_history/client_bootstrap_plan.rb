# frozen_string_literal: true

require "digest"

module QuickbooksHistory
  class ClientBootstrapPlan
    attr_reader :batch, :profiles, :errors, :warnings, :review_items, :summary, :digest

    def initialize(batch:)
      @batch = batch
    end

    def call
      @profiles = batch.historical_workers.order(:id).map do |worker|
        WorkerProfileParser.new(worker: worker, pay_frequency: batch.company.pay_frequency).call
      end
      @errors = base_errors + profile_errors
      @warnings = aggregate_warnings
      @review_items = aggregate_review_items
      @summary = build_summary
      @digest = Digest::SHA256.hexdigest(JSON.generate(digest_payload))
      self
    end

    def ready?
      errors.empty?
    end

    private

    def base_errors
      values = []
      values << "The QuickBooks history must still be a preview" unless batch.previewed?
      values << "Every retained source file must pass integrity verification" unless batch.source_files_complete_and_verified?
      values << "QuickBooks paycheck reconciliation must pass" unless batch.reconciliation_summary.to_h["passed"] && Array(batch.validation_errors).empty?

      company = batch.company
      unless clean_company?(company)
        values << "Current payroll can only be prepared in a clean client with no employees, payroll runs, YTD balances, or payroll-field setup"
      end
      values
    end

    def clean_company?(company)
      Employee.where(company_id: company.id).none? &&
        PayPeriod.where(company_id: company.id).none? &&
        EmployeeYtdTotal.joins(:employee).where(employees: { company_id: company.id }).none? &&
        CompanyYtdTotal.where(company_id: company.id).none? &&
        PayrollFieldDefinition.where(company_id: company.id).none? &&
        DeductionType.where(company_id: company.id).none?
    end

    def profile_errors
      profiles.flat_map do |profile|
        profile.errors.map do |message|
          "Worker ##{profile.worker.id}: #{message}"
        end
      end
    end

    def aggregate_warnings
      profiles.flat_map(&:warnings).tally.map do |message, count|
        { "message" => message, "worker_count" => count }
      end.sort_by { |item| [ item.fetch("message"), item.fetch("worker_count") ] }
    end

    def aggregate_review_items
      profiles.flat_map do |profile|
        profile.review_items.map { |item| item.merge("historical_worker_id" => profile.worker.id) }
      end.group_by { |item| [ item.fetch("code"), item.fetch("message") ] }
        .map do |(code, message), items|
          {
            "code" => code,
            "message" => message,
            "worker_count" => items.size,
            "historical_worker_ids" => items.map { |item| item.fetch("historical_worker_id") }.sort
          }
        end.sort_by { |item| item.fetch("code") }
    end

    def build_summary
      {
        "worker_count" => profiles.size,
        "active_employee_count" => profiles.count(&:active?),
        "inactive_employee_count" => profiles.count { |profile| !profile.active? },
        "hourly_employee_count" => profiles.count { |profile| profile.employee_attributes.fetch(:employment_type) == "hourly" },
        "variable_pay_employee_count" => profiles.count { |profile| profile.employee_attributes.fetch(:salary_type) == "variable" },
        "wage_rate_count" => profiles.sum { |profile| profile.wage_rates.size },
        "payroll_field_assignment_count" => profiles.sum { |profile| profile.payroll_fields.size },
        "employees_with_recurring_setup_count" => profiles.count do |profile|
          attrs = profile.employee_attributes
          profile.payroll_fields.any? || %i[
            retirement_rate roth_retirement_rate employer_retirement_match_rate employer_roth_match_rate
          ].any? { |key| attrs.fetch(key).positive? }
        end,
        "employees_needing_review_count" => profiles.count { |profile| profile.review_items.any? },
        "error_count" => errors.size
      }
    end

    def digest_payload
      {
        batch_id: batch.id,
        batch_digest: batch.bundle_digest,
        company_id: batch.company_id,
        pay_frequency: batch.company.pay_frequency,
        profiles: profiles.map(&:digest_payload),
        errors: errors
      }
    end
  end
end
