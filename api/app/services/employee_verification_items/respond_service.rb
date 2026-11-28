# frozen_string_literal: true

module EmployeeVerificationItems
  # Handles client resubmission of a returned_to_client verification item under
  # the canonical Company -> EmployeeVerificationItem lock order.
  class RespondService
    Result = Data.define(:item, :error, :code, :status, :employee_lifecycle_mode) do
      def success?
        error.nil?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(company:, actor:, item_id:, note:, expected_lifecycle_mode: nil,
                   ip_address: nil, user_agent: nil, on_company_locked: nil)
      @company = company
      @actor = actor
      @item_id = item_id
      @note = note
      @expected_lifecycle_mode = expected_lifecycle_mode
      @ip_address = ip_address
      @user_agent = user_agent
      @on_company_locked = on_company_locked
    end

    def call
      result = nil
      ActiveRecord::Base.transaction do
        Company.lock.find(@company.id)
        @on_company_locked&.call

        current_mode = CompanyFeatures.for(@company).employee_lifecycle_mode
        if @expected_lifecycle_mode.present? && current_mode != @expected_lifecycle_mode
          result = error_result(
            error: "This company's employee lifecycle mode changed. Reload and submit your change again.",
            code: "lifecycle_mode_changed",
            status: :conflict,
            employee_lifecycle_mode: current_mode
          )
          next
        end

        unless current_mode == "client_managed"
          result = error_result(
            error: "Client-managed employee lifecycle is not enabled for this company.",
            code: "client_lifecycle_disabled",
            status: :forbidden
          )
          next
        end

        item = EmployeeVerificationItem.where(company_id: @company.id).lock.find_by(id: @item_id)
        unless item
          result = error_result(error: "Verification item not found", status: :not_found)
          next
        end

        unless item.status == "returned_to_client"
          result = error_result(
            error: "Only sent-back verification items can be responded to.",
            status: :unprocessable_entity
          )
          next
        end

        saved_item = apply_response!(item)
        record_audit!(saved_item)
        PortalNotifications.employee_verification_queued!(saved_item)
        result = Result.new(
          item: saved_item.reload,
          error: nil,
          code: nil,
          status: :ok,
          employee_lifecycle_mode: nil
        )
      end

      result
    end

    private

    def apply_response!(item)
      now = Time.current
      response_metadata = {
        "client_response_note" => @note,
        "client_responded_by_id" => @actor.id,
        "client_responded_at" => now.utc.iso8601
      }

      if item.acknowledged_in_committed_run?
        apply_acknowledged_response!(item, now: now, response_metadata: response_metadata)
      else
        item.update!(
          status: "pending_verification",
          resubmitted_at: now,
          source_actor: @actor,
          metadata: item.metadata.to_h.merge(response_metadata)
        )
        item
      end
    end

    def apply_acknowledged_response!(item, now:, response_metadata:)
      existing_linked = EmployeeVerificationItem
        .where(company_id: item.company_id, employee_id: item.employee_id)
        .open_items
        .where("metadata ->> 'prior_unverified_item_id' = ?", item.id.to_s)
        .order(created_at: :desc, id: :desc)
        .lock
        .to_a
        .find { |candidate| !candidate.acknowledged_in_committed_run? }

      if existing_linked
        existing_note = existing_linked.metadata.to_h["client_response_note"].to_s.strip.presence
        appended_note = existing_note.present? ? "#{existing_note}\n\n#{@note}" : @note
        existing_linked.update!(
          status: "pending_verification",
          resubmitted_at: now,
          source_actor: @actor,
          metadata: existing_linked.metadata.to_h.merge(response_metadata, "client_response_note" => appended_note)
        )
        existing_linked
      else
        EmployeeVerificationItem.create!(
          company_id: item.company_id,
          employee: item.employee,
          event_kind: item.event_kind,
          status: "pending_verification",
          affects_pay: item.affects_pay,
          effective_on: item.effective_on,
          source_actor: @actor,
          source_record: item.source_record,
          changed_fields: item.changed_fields,
          before_values: item.before_values,
          after_values: item.after_values,
          resubmitted_at: now,
          metadata: item.metadata.to_h.merge(response_metadata).merge("prior_unverified_item_id" => item.id)
        )
      end
    end

    def record_audit!(item)
      AuditLog.record!(
        user: @actor,
        company_id: @company.id,
        action: "employee_verification_items#respond",
        record_type: "employee_verification_items",
        record_id: item.id,
        subject_name: item.employee.full_name,
        metadata: {
          employee_id: item.employee_id,
          event_kind: item.event_kind,
          response_note: @note
        },
        ip_address: @ip_address,
        user_agent: @user_agent
      )
    end

    def error_result(error:, status:, code: nil, employee_lifecycle_mode: nil)
      Result.new(
        item: nil,
        error: error,
        code: code,
        status: status,
        employee_lifecycle_mode: employee_lifecycle_mode
      )
    end
  end
end
