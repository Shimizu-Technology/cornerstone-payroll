# frozen_string_literal: true

class PayrollBusinessClock
  TIME_ZONE = "Pacific/Guam"

  def self.today
    Time.current.in_time_zone(TIME_ZONE).to_date
  end
end
