# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ClerkAuthenticatable

  private

  def auth_disabled?
    ENV["AUTH_ENABLED"] != "true"
  end

  # Fallback user for development when auth is disabled
  def current_user
    return super if ENV["AUTH_ENABLED"] == "true"

    @current_user ||= User.find_by(role: "admin") || User.first
  end

  def current_company
    @current_company ||= current_user&.company
  end

  def current_company_id
    current_user&.company_id
  end

  def require_admin!
    unless current_user&.admin?
      render json: { error: "Admin access required" }, status: :forbidden
    end
  end

  def require_manager_or_admin!
    unless current_user&.admin? || current_user&.manager?
      render json: { error: "Manager or admin access required" }, status: :forbidden
    end
  end
end
