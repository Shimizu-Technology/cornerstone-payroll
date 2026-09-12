# frozen_string_literal: true

module PayrollReview
  class RevisionService
    class Error < StandardError; end

    def initialize(pay_period:, actor: nil)
      @pay_period = pay_period
      @actor = actor
    end

    def issue!
      review_package = nil

      pay_period.with_lock do
        pay_period.reload
        raise Error, "Calculate payroll before preparing client review" unless pay_period.calculated?
        next unless pay_period.payroll_items.exists?

        evidence = CalculationSnapshot.new(pay_period: pay_period).call
        current = pay_period.payroll_review_packages.current.order(revision: :desc).first
        if current&.calculation_checksum == evidence.fetch(:checksum)
          review_package = current
          next
        end

        now = Time.current
        current&.update!(
          status: "superseded",
          superseded_at: now,
          supersession_reason: "Payroll inputs or calculation changed; a new review revision was generated."
        )

        review_package = pay_period.payroll_review_packages.create!(
          company: pay_period.company,
          revision: pay_period.payroll_review_packages.maximum(:revision).to_i + 1,
          schema_version: CalculationSnapshot::SCHEMA_VERSION,
          calculation_checksum: evidence.fetch(:checksum),
          source_manifest: evidence.fetch(:source_manifest),
          calculation_snapshot: evidence.fetch(:snapshot),
          status: "pending",
          generated_by: actor,
          generated_at: now
        )
      end

      review_package
    end

    def approve!(approver:, recorded_by:, method:, acknowledgement:, notes: nil, evidence_reference: nil)
      approval_method = method.to_s
      review_package = nil

      pay_period.with_lock do
        pay_period.reload
        raise Error, "This payroll is no longer calculated. Recalculate before client approval." unless pay_period.calculated?

        review_package = pay_period.payroll_review_packages.current.lock.order(revision: :desc).first
        raise Error, "Prepare the current payroll review revision before approval." unless review_package
        raise Error, "This payroll review revision has already been approved." if review_package.approved?
        validate_approver!(approver)
        validate_recording_method!(approval_method, approver, recorded_by, evidence_reference)
        verify_current_checksum!(review_package)

        review_package.update!(
          status: "approved",
          approved_at: Time.current,
          approved_by: approver,
          approval_recorded_by: recorded_by,
          approval_method: approval_method,
          approval_acknowledgement: acknowledgement,
          approval_notes: notes.to_s.strip.presence,
          approval_evidence_reference: evidence_reference.to_s.strip.presence
        )
      end

      review_package
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.join(", ")
    end

    def verify_required_approval!
      return true unless pay_period.company.client_payroll_approval_required?

      review_package = pay_period.payroll_review_packages.current.order(revision: :desc).first
      raise Error, "Generate the current client payroll review revision before approval." unless review_package
      raise Error, "Client approval is still required for payroll review revision #{review_package.revision}." unless review_package.approved?

      verify_current_checksum!(review_package)
      true
    end

    def verify_current_checksum!(review_package)
      current_checksum = CalculationSnapshot.new(pay_period: pay_period).call.fetch(:checksum)
      return true if ActiveSupport::SecurityUtils.secure_compare(review_package.calculation_checksum, current_checksum)

      raise Error, "Payroll changed after client review revision #{review_package.revision}. Recalculate and request approval for the new revision."
    end

    private

    attr_reader :pay_period, :actor

    def validate_approver!(approver)
      unless approver&.active? && approver.client? && approver.can_access_company?(pay_period.company_id)
        raise Error, "Select an active client portal user assigned to this client."
      end
    end

    def validate_recording_method!(method, approver, recorded_by, evidence_reference)
      case method
      when "client_portal"
        unless recorded_by&.id == approver.id && recorded_by.client?
          raise Error, "Client portal approval must be recorded by the approving client user."
        end
      when "email_attestation"
        raise Error, "Only payroll staff can record an email approval." unless recorded_by&.staff_member?
        if evidence_reference.to_s.strip.blank?
          raise Error, "Record the email message reference or retained evidence location."
        end
      else
        raise Error, "Choose a supported client approval method."
      end
    end
  end
end
