# frozen_string_literal: true

module ViewAsJobEnqueueGuard
  extend ActiveSupport::Concern

  included do
    before_enqueue { Current.prevent_view_as_side_effects! }
  end

  def enqueue(...)
    # For deferred jobs, Rails runs enqueue callbacks after commit, when the
    # request's Current attributes may already be gone.
    Current.prevent_view_as_side_effects! if self.class.enqueue_after_transaction_commit
    super
  end
end
