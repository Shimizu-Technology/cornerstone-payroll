# frozen_string_literal: true

# Former-employee access now defaults to 2 years, not 6 (M4-2, plan §8a).
# Resets the seeded value on current and future operating profiles wherever
# it is still exactly the old default; any other value was set on purpose.
# Resetting every untouched 6 to 2 is intended: the owner chose 2 years for
# all companies (November 24, 2026). Ended versions keep the history they had.
# No link has ever been made former, so nothing in use changes.
#
# "Ended" is judged on today's date in Guam (PayrollBusinessClock), the
# business date profiles use, not the database server's CURRENT_DATE (UTC).
class ResetFormerAccessYearsDefault < ActiveRecord::Migration[8.1]
  PATH = "{employee_portal,former_access_years}"

  def up
    today = PayrollBusinessClock.today
    execute <<~SQL.squish
      UPDATE client_operating_profiles
      SET options = jsonb_set(options, '#{PATH}', '2'::jsonb),
          lock_version = lock_version + 1, updated_at = CURRENT_TIMESTAMP
      WHERE options #> '#{PATH}' = '6'::jsonb
        AND (ends_on IS NULL OR ends_on >= #{connection.quote(today.iso8601)}::date)
    SQL
  end

  def down
    # Irreversible by design: after deploy a 2 may be a deliberate choice.
  end
end
