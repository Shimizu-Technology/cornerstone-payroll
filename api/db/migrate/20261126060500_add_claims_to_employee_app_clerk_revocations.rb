# frozen_string_literal: true

# M4-9d: one job at a time per demo kill switch Clerk revocation. job_id is
# the Active Job that owns the row (set by an atomic claim when it is
# queued, so a repeat stop and the sweep can't both queue it, and a job the
# sweep replaced does nothing); leased_until marks an attempt in progress,
# so two runs of that job can't call Clerk or record an outcome at once.
class AddClaimsToEmployeeAppClerkRevocations < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_app_clerk_revocations, :job_id, :string, limit: 64
    add_column :employee_app_clerk_revocations, :leased_until, :datetime
  end
end
