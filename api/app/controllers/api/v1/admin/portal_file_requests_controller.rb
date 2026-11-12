# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Staff ask a client for a specific file, then accept the answer, ask
      # again, or withdraw a request that is no longer needed.
      class PortalFileRequestsController < BaseController
        include PortalFileRequestActions
        before_action :set_file_request, except: [ :create ]

        def create
          request, replayed = file_request_actions.create!(params.permit(:title, :category, :employee_id, :payroll_submission_period_ref,
            :due_on, :body, :thread_id, :idempotency_key))
          skip_default_audit_log!
          thread = ClientPortalThread.find(request.client_portal_thread_id)
          render json: { data: serializer.file_request(request), thread: serializer.thread(thread, include_messages: true) },
            status: replayed ? :ok : :created
        end

        def accept
          render_step(file_request_actions.accept!(@file_request, step_params))
        end

        def ask_again
          render_step(file_request_actions.ask_again!(@file_request, step_params))
        end

        def withdraw
          render_step(file_request_actions.withdraw!(@file_request, step_params))
        end
      end
    end
  end
end
