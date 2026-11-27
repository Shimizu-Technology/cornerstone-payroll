# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :real_user, :view_as_grant
  attribute :user, :actor, :organization_id, :company_id, :request_id, :ip_address, :user_agent, :domain_audit_recorded, :company_features_cache, default: nil

  def self.prevent_view_as_side_effects!
    raise ActiveRecord::ReadOnlyError, "Side effects are unavailable during a view-only support session" if view_as_grant
  end

  # Inline jobs and invoked tasks can share a thread with their caller. Restore
  # that caller's context on exit, including when work raises.
  def self.with_isolated_actor(actor, &block)
    set(attributes.transform_values { nil }.merge(actor: actor), &block)
  end
end
