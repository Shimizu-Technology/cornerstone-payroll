# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class AddressRequestsController < ProfileBaseController
        rescue_from ActiveRecord::RecordNotUnique do |error|
          raise error unless error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == "idx_employee_change_requests_one_pending"

          render_pending_request
        end

        def create
          return render_pending_request if profile.requests.pending.exists?

          submit_address!(proposed_address!)
          render_profile(status: :created)
        end

        def update
          change_request = profile.own_requests.pending.find(resource_id)
          unless normalize_address(change_request.original_values) == normalize_address(@employee)
            return render json: {
              error: "Your address on file changed. Refresh the page and confirm the address before submitting a new request.",
              code: "address_on_file_changed"
            }, status: :conflict
          end

          address = proposed_address!
          change_request.cancelled!
          submit_address!(address)
          render_profile
        end

        def destroy
          @audit_record = profile.own_requests.pending.find(resource_id)
          @audit_record.cancelled!
          render_profile
        end

        private

        def submit_address!(address)
          @audit_record = profile.requests.create!(
            requested_by: current_user, requested_by_link: @employee_link, request_kind: "update",
            status: :pending, proposed_changes: address, original_values: @employee.slice(*address.keys)
          )
          PortalNotifications.employee_change_submitted!(@audit_record)
        end

        def lock_profile_company!
          # The client submission and both review paths take this same lock
          # before touching a request or its employee.
          Company.lock.find(current_company_id)
        end

        def proposed_address!
          input = params[:address]
          invalid!(:address, "is required") unless input.is_a?(ActionController::Parameters)

          EmployeeChangeRequest::ADDRESS_FIELDS.each do |field|
            value = input[field]
            invalid!(:address, "contains an invalid field") unless value.nil? || (value.is_a?(String) && value.size <= 255 && !value.include?("\0"))
          end

          address = normalize_address(input)
          required = EmployeeContactValidator::ADDRESS_REQUIRED_FIELDS.map(&:to_s)
          if address.values_at(*required).any?(&:blank?) || !address["state"].match?(/\A[A-Z]{2}\z/) ||
              !address["zip"].match?(/\A[0-9]{5}(?:-[0-9]{4})?\z/)
            invalid!(:address, "requires a street, city, two-letter state or territory, and valid ZIP code")
          end
          if address == normalize_address(@employee)
            invalid!(:address, "must be different from the address on file")
          end

          address
        end

        def normalize_address(values)
          address = EmployeeChangeRequest::ADDRESS_FIELDS.index_with { |field| values[field]&.strip&.presence }
          address["state"] = address["state"]&.upcase
          address
        end

        def render_pending_request
          render json: { error: EmployeeChangeRequest::PENDING_PROFILE_REQUEST_MESSAGE }, status: :conflict
        end
      end
    end
  end
end
