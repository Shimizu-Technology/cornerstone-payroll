# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PortalMessagesController < BaseController
        include ClientPortalMessageActions
      end
    end
  end
end
