# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # Electronic-delivery consent records for pay statements and Form W-2GU (M4-6).
      # Gated by employee_portal.features.delivery_consent (defaults to off).
      # Giving consent requires step-up verification (and PDF access-proof for W-2GU)
      # and an active employee link.
      # Withdrawal is intentionally one-tap without step-up (owner decision per §8a):
      # it can only move an employee back to paper delivery, and is permitted on
      # eligible former links as well as active links.
      class DeliveryConsentsController < BaseController
        include RecentVerification

        AUDIT_ACTION = "employee_delivery_consents"

        before_action :no_store, :require_delivery_consent!, :load_employee
        before_action :require_active_link!, only: %i[create w2gu_access_proof]

        # GET /api/v1/employee/delivery_consents
        def show
          audit!("show", record: @employee_link || @view_as_employee_context&.link || @employee)
          render json: status_payload
        end

        # POST /api/v1/employee/delivery_consents/w2gu_access_proof/pdf
        def w2gu_access_proof
          disclosure = DeliveryDisclosure.current_for("w2gu")
          return render json: { error: "W-2GU disclosure is not available.", code: "disclosure_unavailable" },
            status: :unprocessable_entity unless disclosure

          challenge = DeliveryConsents::W2guAccessProof.issue(
            link: @employee_link,
            user: @current_user,
            disclosure: disclosure
          )
          audit!("w2gu_access_proof", record: @employee_link,
            metadata: { disclosure_version: disclosure.version, disclosure_digest: disclosure.digest })
          response.headers["X-Content-Type-Options"] = "nosniff"
          render json: challenge.as_json, status: :ok
        end

        # POST /api/v1/employee/delivery_consents
        def create
          created = false
          consent_record = nil
          error_response = nil

          Employee.transaction(requires_new: true) do
            lock_consent_context!
            unless writable_link?
              head :not_found
              next
            end

            require_recent_verification!
            next if performed?

            kind = params[:kind].to_s
            unless DeliveryDisclosure::KINDS.include?(kind)
              error_response = [ { error: "Unsupported delivery consent type.", code: "invalid_kind" }, :unprocessable_entity ]
              next
            end

            unless params[:acknowledged] == true || params[:acknowledged] == "true"
              error_response = [ { error: "You must confirm that you have read and agree to the disclosure.", code: "acknowledgement_required" }, :unprocessable_entity ]
              next
            end

            disclosure = DeliveryDisclosure.current_for(kind)
            unless disclosure
              error_response = [ { error: "Disclosure is not available.", code: "disclosure_unavailable" }, :unprocessable_entity ]
              next
            end

            version = params[:disclosure_version].to_s
            digest = params[:disclosure_digest].to_s
            unless version == disclosure.version && digest == disclosure.digest
              error_response = [ { error: "The disclosure wording has been updated. Reload and review the latest version.", code: "disclosure_outdated" }, :unprocessable_entity ]
              next
            end

            now = Time.current
            if kind == "w2gu"
              verified = DeliveryConsents::W2guAccessProof.verify?(
                token: params[:access_proof_token],
                code: params[:access_proof_code],
                link: @employee_link,
                user: @current_user,
                disclosure: disclosure,
                now: now
              )
              unless verified
                error_response = [ { error: "Open the test PDF and enter the confirmation code shown inside it.", code: "access_proof_invalid" }, :unprocessable_entity ]
                next
              end
            end

            existing = DeliveryConsent.active
              .where(company_id: current_company_id, employee_id: @employee.id, kind: kind)
              .order(given_at: :desc, id: :desc)
              .first

            if existing&.matches_disclosure?(disclosure)
              consent_record = existing
            else
              if existing
                existing.update!(
                  withdrawn_at: now,
                  withdrawn_by_user: @current_user,
                  withdrawn_ip_address: request_ip,
                  withdrawn_user_agent: request_user_agent
                )
              end
              consent_record = DeliveryConsent.create!(
                company_id: current_company_id,
                user: @current_user,
                employee: @employee,
                employee_account_link: @employee_link,
                delivery_disclosure: disclosure,
                kind: kind,
                disclosure_version: disclosure.version,
                disclosure_digest: disclosure.digest,
                given_at: now,
                ip_address: request_ip,
                user_agent: request_user_agent,
                method: kind == "w2gu" ? "employee_portal_pdf_verified" : "employee_portal_checkbox",
                access_proof_verified_at: (now if kind == "w2gu")
              )
              created = true
            end
          end

          return if performed?
          return render json: error_response.first, status: error_response.last if error_response

          if created
            audit!("create", record: consent_record, metadata: {
              kind: consent_record.kind,
              disclosure_version: consent_record.disclosure_version,
              disclosure_digest: consent_record.disclosure_digest,
              method: consent_record.method
            })
          else
            skip_default_audit_log!
          end

          render json: status_payload, status: (created ? :created : :ok)
        end

        # POST /api/v1/employee/delivery_consents/withdraw
        # Accepted one-tap withdrawal without step-up (§8a): withdrawal can only
        # move the employee back to paper delivery. Permitted on both active links
        # and eligible former links (while former_access_until has not expired).
        # Repeating withdraw when no active consent exists is an idempotent 200.
        def withdraw
          kind = params[:kind].to_s
          unless DeliveryDisclosure::KINDS.include?(kind)
            return render json: { error: "Unsupported delivery consent type.", code: "invalid_kind" },
              status: :unprocessable_entity
          end

          consent_record = nil
          change_entry = nil

          Employee.transaction(requires_new: true) do
            lock_consent_context!
            unless withdrawable_link?
              head :not_found
              next
            end

            active_consent = DeliveryConsent.active
              .where(company_id: current_company_id, employee_id: @employee.id, kind: kind)
              .order(given_at: :desc, id: :desc)
              .first

            next unless active_consent

            now = Time.current
            active_consent.update!(
              withdrawn_at: now,
              withdrawn_by_user: @current_user,
              withdrawn_ip_address: request_ip,
              withdrawn_user_agent: request_user_agent
            )
            change_entry = EmployeeContactChangeToConfirm.record_delivery_consent_withdrawal!(
              consent: active_consent,
              actor: @current_user
            )
            consent_record = active_consent
          end

          return if performed?

          if consent_record
            audit!("withdraw", record: consent_record, metadata: {
              kind: consent_record.kind,
              disclosure_version: consent_record.disclosure_version,
              disclosure_digest: consent_record.disclosure_digest,
              change_to_confirm_id: change_entry.id
            })
          else
            skip_default_audit_log!
          end
          render json: status_payload, status: :ok
        end

        private

        def no_store
          response.headers["Cache-Control"] = "no-store"
        end

        def current_company
          employee_access_context.company
        end

        def require_delivery_consent!
          head :not_found unless CompanyFeatures.for(current_company).employee_portal_feature?(:delivery_consent)
        end

        def load_employee
          @employee = Employee.where(company_id: current_company_id).find(employee_access_context.employee_id)
        end

        def require_active_link!
          head :not_found unless @employee_link.active?
        end

        def lock_consent_context!
          Company.lock("FOR KEY SHARE").find(current_company_id)
          @employee.lock!
          @current_user.lock!("FOR NO KEY UPDATE")
          @employee_link.lock!
        end

        def writable_link?
          @current_user.payroll_access_allowed? && @employee_link.active? && !@employee_link.activation_locked? &&
            @employee_link.user_id == @current_user.id &&
            @employee_link.employee_id == @employee.id &&
            @employee_link.company_id == @employee.company_id
        end

        def withdrawable_link?
          link_eligible = (@employee_link.active? ||
            (@employee_link.former? && @employee_link.former_access_until.present? && @employee_link.former_access_until > Time.current)) &&
            !@employee_link.activation_locked?
          @current_user.payroll_access_allowed? && link_eligible &&
            @employee_link.user_id == @current_user.id &&
            @employee_link.employee_id == @employee.id &&
            @employee_link.company_id == @employee.company_id
        end

        def status_payload
          DeliveryConsents::StatusPresenter.new(
            employee: @employee,
            company: current_company,
            user: @current_user
          ).as_json
        end

        def request_ip
          request.remote_ip.to_s.first(64).presence
        end

        def request_user_agent
          request.user_agent.to_s.first(512).presence
        end

        def audit!(event, record:, metadata: {})
          AuditLog.record!(
            actor: Current.actor,
            user: @current_user,
            organization_id: current_company.organization_id,
            company_id: current_company_id,
            action: "#{AUDIT_ACTION}##{event}",
            record_type: record.class.table_name,
            record_id: record.id,
            subject_name: @employee.display_name,
            event_category: "employee_portal",
            metadata: metadata.merge(
              employee_account_link_id: employee_access_context.id,
              employee_id: @employee.id
            ).compact
          )
          skip_default_audit_log!
        end
      end
    end
  end
end
