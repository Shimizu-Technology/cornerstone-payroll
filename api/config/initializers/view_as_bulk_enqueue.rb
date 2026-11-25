# frozen_string_literal: true

# Active Job's bulk API bypasses individual enqueue callbacks, including
# when it defers a batch until after commit.
module ViewAsBulkEnqueueGuard
  def perform_all_later(...)
    Current.prevent_view_as_side_effects!
    super
  end
end

ActiveSupport.on_load(:active_job) do
  ActiveSupport.on_load(:active_record) do
    ActiveJob.singleton_class.prepend(ViewAsBulkEnqueueGuard)
  end
end
