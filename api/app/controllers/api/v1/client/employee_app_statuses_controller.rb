# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeAppStatusesController < BaseController
        include EmployeeAppStatusActions
      end
    end
  end
end
