# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeIntakeSettingsController < BaseController
        def show
          render json: { data: EmployeeIntakePolicy.settings(current_company, current_user).merge(can_manage: false) }
        end
      end
    end
  end
end
