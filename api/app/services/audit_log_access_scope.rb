# frozen_string_literal: true

class AuditLogAccessScope
  class NotAuthorizedError < StandardError; end

  def initialize(user:, current_company_id:, requested_company_id:, company_header_present:)
    @user = user
    @current_company_id = current_company_id
    @requested_company_id = requested_company_id
    @company_header_present = company_header_present
  end

  def call
    validate_requested_company!

    return AuditLog.all if user.super_admin?
    return organization_scope if user.organization_admin?

    AuditLog.where(company_id: scoped_company_id)
  end

  private

  attr_reader :user, :current_company_id, :requested_company_id, :company_header_present

  def validate_requested_company!
    return if requested_company_id.blank?

    requested_id = requested_company_id.to_i
    return if user.organization_admin? && user.accessible_company_ids.include?(requested_id)
    return if !user.organization_admin? && requested_company_allowed?(requested_id)

    raise NotAuthorizedError, "Not authorized"
  end

  def requested_company_allowed?(requested_id)
    if company_header_present
      requested_id == current_company_id
    else
      user.accessible_company_ids.include?(requested_id)
    end
  end

  def scoped_company_id
    return current_company_id if requested_company_id.blank? || company_header_present

    requested_company_id.to_i
  end

  def organization_scope
    AuditLog.where(organization_id: user.organization_id)
            .or(AuditLog.where(organization_id: nil, company_id: user.accessible_company_ids))
  end
end
