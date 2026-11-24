class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # The database's clock right now (clock_timestamp(), not the transaction's
  # start), for times that must order against other writers and against
  # outside systems, such as when a login was closed.
  def self.database_now
    value = with_connection { |connection| connection.select_value("SELECT clock_timestamp()") }
    value.is_a?(String) ? Time.zone.parse(value) : value.in_time_zone
  end
end
