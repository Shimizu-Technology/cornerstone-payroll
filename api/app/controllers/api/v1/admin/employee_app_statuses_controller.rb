# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeAppStatusesController < BaseController
        include EmployeeAppStatusActions
      end
    end
  end
end
