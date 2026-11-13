# frozen_string_literal: true

module PayrollImport
  # The unapplied MoSa import review that is open for a pay period, if any.
  module CurrentReview
    module_function

    def source_package_for(pay_period)
      pay_period.payroll_intake_sessions.current
                .where(source_type: "mosa_revel", status: %w[previewed reviewed])
                .order(package_revision: :desc, id: :desc)
                .first
    end

    def import_record_for(pay_period, source_package = source_package_for(pay_period))
      return unless source_package

      PayrollImportRecord.find_by(pay_period: pay_period, payroll_intake_session: source_package, status: "previewed")
    end
  end
end
