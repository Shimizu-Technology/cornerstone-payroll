# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class ProfileController < ProfileBaseController
        include EmployeeContactLoginRejectionGuard

        rescue_from EmployeeContactValidator::ValidationError do |error|
          render_contact_validation_error!(error, employee: @employee)
        end

        def show
          render_profile
        end

        def update_phone
          phone, error = EmployeeContactValidator.normalize_phone(params.permit(:phone)[:phone])
          invalid!(:phone, error || "is required") unless phone

          before = { phone: @employee.phone }
          @employee.phone_confirmed_by_employee_at_will_change!
          @employee.update!(phone: phone, phone_confirmed_by_employee_at: Time.current, contact_source: "employee")
          record_contact_change!(before, phone: phone)
          render_profile
        end

        def start_email
          return render_login_email_cooldown! if login_email_cooldown_active?

          retry_after = email_challenge.retry_after
          if retry_after.positive?
            response.set_header("Retry-After", retry_after.to_s)
            return render json: { error: "Wait before requesting another code." }, status: :too_many_requests
          end

          email = validated_email!(email_params[:email])
          render json: { verification_id: email_challenge.issue!(email) }, status: :accepted
        rescue EmployeeProfiles::EmailChallenge::DeliveryUnavailable
          email_challenge.consume!
          render json: { error: "The verification code could not be sent." }, status: :service_unavailable
        end

        def confirm_email
          return render_login_email_cooldown! if login_email_cooldown_active?

          credentials = email_params
          email = email_challenge.verify!(credentials[:verification_id].to_s, credentials[:code].to_s.strip)
          unless email
            return render json: { error: "The verification code is invalid or expired." }, status: :unprocessable_entity
          end

          email = validated_email!(email)
          before = { email: @employee.email }
          @employee.email_verified_at_will_change!
          @employee.update!(email: email, email_verified_at: Time.current, contact_source: "employee")
          email_challenge.consume!
          record_contact_change!(before, email: email)
          render_profile
        end

        private

        def email_params
          ActionController::Parameters.new(request.request_parameters).permit(:email, :verification_id, :code)
        end

        def validated_email!(raw)
          invalid!(:email, "is required") if raw.blank?

          result = EmployeeContactValidator.call(employee: @employee, company: current_company, email: raw,
            actor: current_user, source: "employee")
          return result.normalized_email if result.valid?

          result.apply_errors_to(@employee)
          raise EmployeeContactValidator::ValidationError.new(result: result, record: @employee)
        end

        def email_challenge
          @email_challenge ||= EmployeeProfiles::EmailChallenge.new(@employee_link, @employee)
        end
      end
    end
  end
end
