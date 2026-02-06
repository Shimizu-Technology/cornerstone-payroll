# frozen_string_literal: true

module Api
  module V1
    module Admin
      class BaseController < ApplicationController
        before_action :require_admin_or_manager!
      end
    end
  end
end
