# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class ContextController < BaseController
        def show
          head :no_content
        end
      end
    end
  end
end
