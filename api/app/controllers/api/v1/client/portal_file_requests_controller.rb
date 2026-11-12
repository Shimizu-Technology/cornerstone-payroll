# frozen_string_literal: true

module Api
  module V1
    module Client
      # The client answers a file request by attaching the file.
      class PortalFileRequestsController < BaseController
        include PortalFileRequestActions
        before_action :set_file_request

        def respond
          render_step(file_request_actions.respond!(@file_request, step_params))
        end
      end
    end
  end
end
