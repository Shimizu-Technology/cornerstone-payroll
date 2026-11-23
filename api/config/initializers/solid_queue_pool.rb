# frozen_string_literal: true

# Solid Queue already checks its own pool against worker threads plus two.
# Job code also uses the application database, often through a separate pool.
SolidQueue::Configuration.validate do
  primary_pool = ActiveRecord::Base.connection_pool
  required_size = estimated_number_of_threads

  if primary_pool.size && primary_pool.size < required_size
    errors.add(:base, "Solid Queue requires a primary database pool of at least #{required_size} " \
      "(worker threads + 2), but it is #{primary_pool.size}. Increase DB_POOL_MAX.")
  end
end
