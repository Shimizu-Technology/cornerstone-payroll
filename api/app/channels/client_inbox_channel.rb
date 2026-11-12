# frozen_string_literal: true

# Only an invalidation signal crosses this organization stream. Resource
# details and counts always come from the freshly authorized inbox endpoint.
class ClientInboxChannel < ApplicationCable::Channel
  def subscribed
    return reject unless allowed?(current_user)

    stream_for current_user.organization, coder: ActiveSupport::JSON do |_message|
      transmit_if_authorized
    end
  end

  private

  def transmit_if_authorized
    user = User.find_by(id: current_user.id)
    if allowed?(user) && user.organization_id == current_user.organization_id
      transmit({ event: "work_changed" })
    else
      stop_all_streams
      connection.close(reason: "Payroll access revoked", reconnect: false)
    end
  end

  def allowed?(user)
    user&.payroll_access_allowed? && StaffRolePolicy.allowed?(user, :staff_workspace) && user.organization&.active?
  end
end
