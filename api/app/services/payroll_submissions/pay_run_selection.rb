# frozen_string_literal: true

module PayrollSubmissions
  # Build only: the caller must persist the selection and any period claim in
  # the successful apply transaction. Failed payroll rows must leave both unsaved.
  class PayRunSelection
    def initialize(pay_period:, actor:, period:, submission_id:)
      @run = pay_period
      @actor = actor
      @period = period
      @submission_id = submission_id
    end

    def build(record)
      @period&.lock!
      source = @period&.current_submission
      unless source && source.id.to_s == @submission_id.to_s && @period.pending_source_review? &&
          @period.company_id == @run.company_id && @period.start_date == @run.start_date && @period.end_date == @run.end_date
        raise ArgumentError, "Choose the current pending client revision for this company and pay period"
      end
      unless @run.cycle == "regular" && @run.run_purpose == "regular" && @run.correction_status.nil?
        raise ArgumentError, "Only the matching regular pay run may use a client revision"
      end
      if @period.pay_period_id.nil?
        catalog = Catalog.new(company: @run.company)
        eligible = catalog.live_pay_period(catalog.resolve(@period.id))
        unless eligible&.id == @run.id
          raise ArgumentError, "Only the matching regular pay run offered by the portal may use this revision"
        end
        @period.pay_period = @run
        source.period = @period
      elsif @period.pay_period_id != @run.id
        raise ArgumentError, "This client revision is not linked to this pay run"
      end
      package = record.payroll_intake_session
      unless record.pay_period_id == @run.id && package&.company_id == @run.company_id && package&.source_type == "mosa_revel"
        raise ArgumentError, "Only a MoSa import may be linked to a client revision"
      end
      PayrollSubmissionImport.new(payroll_import: record, payroll_submission: source, current_submission: source,
        selected_by: @actor, source_route: "pay_run")
    end
  end
end
