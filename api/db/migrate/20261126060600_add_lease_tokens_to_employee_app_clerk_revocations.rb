# frozen_string_literal: true

# M4-9d follow-up. lease_token fences each attempt: it is written when the
# attempt takes the lease, and recording an outcome or releasing the lease
# matches it, so a worker that outlived its lease (and lost it to a newer
# one) writes nothing. submitted_at confirms that the claimed job was
# actually handed to the queue, so the sweep can re-queue a row whose claim
# committed but whose enqueue never happened (a crash in between).
class AddLeaseTokensToEmployeeAppClerkRevocations < ActiveRecord::Migration[8.1]
  def up
    add_column :employee_app_clerk_revocations, :lease_token, :string, limit: 64
    add_column :employee_app_clerk_revocations, :submitted_at, :datetime
    # Rows queued before this column existed were handed to the queue the
    # way they always were; treat them as submitted.
    execute <<~SQL.squish
      UPDATE employee_app_clerk_revocations SET submitted_at = enqueued_at WHERE enqueued_at IS NOT NULL
    SQL
  end

  def down
    remove_column :employee_app_clerk_revocations, :submitted_at
    remove_column :employee_app_clerk_revocations, :lease_token
  end
end
