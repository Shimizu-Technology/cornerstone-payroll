# frozen_string_literal: true

module EmployeeLinks
  # Separates employee-app activation identity prerequisites (DOB, 9-digit SSN,
  # valid personal email) from the full Ready-to-pay checklist (§6.6, §12 Q3).
  #
  # Today (Milestone 4), readiness_gate_enforced employees must complete the
  # full Ready-to-pay checklist before receiving an employee-app invite. Keeping
  # activation_prerequisites separate lets Milestone 5 W-4 self-onboarding toggle
  # invite eligibility to DOB + SSN + email in one place without rewriting Invite.
  class InviteEligibility
    INCOMPLETE_READINESS_MESSAGE = "Finish this employee's Pay setup checklist before inviting them to the employee app."

    PrerequisiteResult = Data.define(:eligible, :missing) do
      def eligible?
        eligible
      end
    end

    def self.activation_prerequisites(employee)
      today = PayrollBusinessClock.today
      missing = []
      dob = employee.date_of_birth
      missing << "date_of_birth" unless dob.present? && dob.year >= 1900 && dob < today
      missing << "ssn" unless employee.valid_filing_ssn?
      missing << "email" unless EmployeeLinks.email_format?(employee.email)

      PrerequisiteResult.new(eligible: missing.empty?, missing: missing)
    end

    def self.eligible?(employee, require_full_readiness: true)
      return true unless employee.readiness_gate_enforced?

      if require_full_readiness
        EmployeeReadinessEvaluator.ready?(employee)
      else
        activation_prerequisites(employee).eligible?
      end
    end

    def self.check!(employee, require_full_readiness: true)
      return unless employee.readiness_gate_enforced?
      return if eligible?(employee, require_full_readiness: require_full_readiness)

      if require_full_readiness
        raise Error, INCOMPLETE_READINESS_MESSAGE
      else
        missing = activation_prerequisites(employee).missing.map { |field| field.tr("_", " ") }.join(", ")
        raise Error, "Add #{missing} before inviting this employee to the employee app."
      end
    end
  end
end
