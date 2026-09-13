# frozen_string_literal: true

class PayrollBusinessClock
  TIME_ZONE = "Pacific/Guam"

  def self.today
    date_for(Time.current)
  end

  def self.date_for(time)
    time.in_time_zone(TIME_ZONE).to_date
  end
end
