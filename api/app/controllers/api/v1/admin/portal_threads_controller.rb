# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PortalThreadsController < BaseController
        include ClientPortalThreadActions
      end
    end
  end
end
