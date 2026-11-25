# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeAppRolloutsController < BaseController
        include EmployeeAppRolloutActions
      end
    end
  end
end
