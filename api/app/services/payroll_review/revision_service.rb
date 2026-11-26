# frozen_string_literal: true

module PayrollReview
  class RevisionService
    class Error < StandardError; end
    class StaleRevisionError < Error; end

    def initialize(pay_period:, actor: nil)
      @pay_period = pay_period
      @actor = actor
    end

    def issue!(publishing: false)
      review_package = nil

      company = Company.find(pay_period.company_id)
      company.with_lock do
        # Every issuing caller takes Company before PayPeriod. with_lock reloads
        # the setting so publication and setting changes serialize.
        pay_period.with_lock do
          pay_period.reload
          raise Error, "Calculate payroll before preparing client review" unless pay_period.calculated? || (publishing && pay_period.approved?)
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
            generated_at: now,
            sent_for_client_approval_at: nil,
            client_review_history_unknown: false
          )
        end
      end

      review_package
    rescue EmployeeYearFicaContext::UnreconciledLedgerError
      raise Error, EmployeeYearFicaContext::STALE_MESSAGE
    end

    # Called inside the lifecycle transaction, after staff approval. Legacy
    # approved runs can be explicitly republished without changing their pay.
    def publish!
      return unless Company.find(pay_period.company_id).client_payroll_approval_required?

      raise Error, "Only approved payroll can be published." unless pay_period.approved?
      package = pay_period.payroll_review_packages.current.first
      if package&.approved? && !package.published_at
        package.update!(status: "superseded", superseded_at: Time.current,
          supersession_reason: "Pre-publication client approval withdrawn; review the staff-approved preview.")
        audit!(package, "withdrawn")
      end
      package = issue!(publishing: true)
      raise Error, "No payroll is available to publish." unless package

      verify_current_checksum!(package)
      unless package.published_at
        package.update!(published_at: Time.current, sent_for_client_approval_at: package.sent_for_client_approval_at || Time.current)
        audit!(package, "published")
      end
      # record! deduplicates by package ID. Retry even after publication so a
      # previous notification failure never makes the missing event permanent.
      notify!(package, "payroll_review_published")
      package
    end

    def retry_publication_notification!
      return unless pay_period.approved? && Company.find(pay_period.company_id).client_payroll_approval_required?

      package = pay_period.payroll_review_packages.current.first
      notify!(package, "payroll_review_published") if package&.published_at
    end

    def withdraw!
      package = pay_period.payroll_review_packages.current.first
      return unless package

      package.update!(status: "superseded", superseded_at: Time.current,
        supersession_reason: "Staff unapproved payroll; client review and any approval were withdrawn.")
      audit!(package, "withdrawn")
    end

    def self.client_can_decide?(package, actor)
      package&.pending? && !package.changes_requested_at && actor&.active? && actor.client? && !actor.client_viewer? &&
        package.generated_by_id != actor.id && Current.view_as_grant.nil?
    end

    def request_changes!(revision_id:, note:)
      package = nil
      with_decision_lock do
        package = decision_package!(revision_id)
        validate_approver!(actor)
        deny_self_decision!(package, actor)
        note = note.to_s.strip
        raise Error, "Describe the change you need." if note.blank?
        raise Error, "Keep the note under 2,000 characters." if note.length > 2_000

        package.update!(changes_requested_at: Time.current, changes_requested_by: actor, change_request_note: note)
        audit!(package, "changes_requested")
        notify!(package, "payroll_review_decided", decision: "changes_requested")
      end
      package
    end

    def approve!(approver:, recorded_by:, method:, acknowledgement:, notes: nil, evidence_reference: nil, revision_id: nil)
      approval_method = method.to_s
      review_package = nil

      with_decision_lock do
        review_package = decision_package!(revision_id)
        validate_approver!(approver)
        deny_self_decision!(review_package, approver) if approval_method == "client_portal"
        validate_recording_method!(approval_method, approver, recorded_by, evidence_reference)

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
        audit!(review_package, "approved")
        notify!(review_package, "payroll_review_decided", decision: "approved")
      end

      review_package
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.join(", ")
    end

    def verify_required_approval!
      review_package = pay_period.payroll_review_packages.current.includes(:changes_requested_by).order(revision: :desc).first
      if review_package&.changes_requested_at
        raise Error, "#{review_package.changes_requested_by&.name || 'Client'} requested changes: #{review_package.change_request_note}. Unapprove to make changes."
      end
      return true unless Company.find(pay_period.company_id).client_payroll_approval_required?

      raise Error, "Generate the current client payroll review revision before commit." unless review_package
      raise Error, "Client approval is still required for payroll review revision #{review_package.revision}." unless review_package.approved? && review_package.published_at

      verify_current_checksum!(review_package)
      true
    end

    def verify_current_checksum!(review_package)
      current_checksum = CalculationSnapshot.new(pay_period: pay_period).call.fetch(:checksum)
      return true if ActiveSupport::SecurityUtils.secure_compare(review_package.calculation_checksum, current_checksum)

      raise StaleRevisionError, "Payroll changed after client review revision #{review_package.revision}. Recalculate and request approval for the new revision."
    rescue EmployeeYearFicaContext::UnreconciledLedgerError
      raise Error, EmployeeYearFicaContext::STALE_MESSAGE
    end

    private

    attr_reader :pay_period, :actor

    def with_decision_lock
      Company.find(pay_period.company_id).with_lock do
        pay_period.with_lock { yield }
      end
    end

    def decision_package!(revision_id)
      unless Company.find(pay_period.company_id).client_payroll_approval_required?
        raise Error, "Client payroll review is disabled for this company."
      end
      pay_period.reload
      raise Error, "Cornerstone must approve payroll before client review." unless pay_period.approved?

      package = pay_period.payroll_review_packages.current.lock.order(revision: :desc).first
      unless package && package.published_at
        raise Error, "Publish the current payroll preview before client review."
      end
      if revision_id.to_s != package.id.to_s
        raise StaleRevisionError, "This review revision changed. Reload the preview before deciding."
      end
      if package.approved? || package.changes_requested_at
        raise Error, "This revision already has a client decision. Cornerstone must unapprove and publish a new revision."
      end
      verify_current_checksum!(package)
      package
    end

    def audit!(package, event)
      previous_domain_audit = Current.domain_audit_recorded
      AuditLog.record!(user: actor, actor: Current.actor || AuditActor.system_job(self.class.name),
        company_id: pay_period.company_id, action: "payroll_review##{event}", record_type: "PayrollReviewPackage", record_id: package.id,
        metadata: { pay_period_id: pay_period.id, revision: package.revision })
    ensure
      # Publication/withdrawal accompany a separate lifecycle audit containing
      # the run's before/after values. Do not suppress that controller audit.
      Current.domain_audit_recorded = previous_domain_audit if event.in?(%w[published withdrawn])
    end

    def notify!(package, event, decision: nil)
      # A savepoint prevents notification failures (including SQL errors) from
      # aborting the financial transaction or leaving a partial delivery ledger.
      ApplicationRecord.transaction(requires_new: true) do
        PortalNotifications.record!(event_type: event, company: pay_period.company, actor: actor, subject: pay_period,
          dedupe_key: "#{event}:#{package.id}", metadata: { pay_period_id: pay_period.id, revision: package.revision, decision: decision }.compact)
      end
    rescue StandardError => e
      Rails.logger.error("Payroll review notification failed: package=#{package.id} event=#{event} error=#{e.class}")
    end

    def deny_self_decision!(package, user)
      raise Error, "You cannot decide a payroll preview you prepared." if package.generated_by_id == user.id
    end

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
