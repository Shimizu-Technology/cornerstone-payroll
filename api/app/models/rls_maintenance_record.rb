# frozen_string_literal: true

# Isolates lead-run policy installation from the application's runtime pool.
class RlsMaintenanceRecord < ActiveRecord::Base
  self.abstract_class = true
end
