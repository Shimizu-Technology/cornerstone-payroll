# frozen_string_literal: true

# NOTE: retained as an explicit no-op placeholder so schema version history
# remains contiguous for environments that already migrated to 20260311000009.
# The effective index definition is provided by 20260311000007 and 00008.
class AdjustCorrectionSourceUniqueIndexForRevoids < ActiveRecord::Migration[8.1]
  def change
    # no-op
  end
end
