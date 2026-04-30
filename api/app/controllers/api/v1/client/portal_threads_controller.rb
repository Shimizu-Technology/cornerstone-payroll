# frozen_string_literal: true

module Api
  module V1
    module Client
      class PortalThreadsController < BaseController
        include ClientPortalThreadActions
      end
    end
  end
end
