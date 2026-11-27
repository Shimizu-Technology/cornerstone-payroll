# frozen_string_literal: true

module PayrollImport
  # The unapplied MoSa import review that is open for a pay period, if any.
  module CurrentReview
    module_function

    # Returns the newest current intake session that has an open previewed
    # PayrollImportRecord so direct intake previews (which have no
    # PayrollImportRecord) never hide an open reviewed-hours or portal review.
    def source_package_for(pay_period, source_type: nil)
      source_types = if source_type.present?
        [ source_type.to_s ]
      else
        (PayrollIntake::Registry.tracks_reviewed_hours_keys +
          PayrollIntake::Registry.all.select(&:portal_submittable?).map(&:key)).uniq
      end
      pay_period.payroll_intake_sessions.current
                .joins("INNER JOIN payroll_imports ON payroll_imports.payroll_intake_session_id = payroll_intake_sessions.id")
                .where(source_type: source_types, status: %w[previewed reviewed])
                .where(payroll_imports: { pay_period_id: pay_period.id, status: "previewed" })
                .order(package_revision: :desc, id: :desc)
                .first
    end

    def import_record_for(pay_period, source_package = source_package_for(pay_period))
      return unless source_package

      PayrollImportRecord.find_by(pay_period: pay_period, payroll_intake_session: source_package, status: "previewed")
    end
  end
end
