# frozen_string_literal: true

module Api
  module V1
    module Client
      class PortalMessagesController < BaseController
        include ClientPortalMessageActions
      end
    end
  end
end
