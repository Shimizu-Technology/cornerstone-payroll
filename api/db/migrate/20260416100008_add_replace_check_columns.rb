# frozen_string_literal: true

# Schema for the "Replace check (uncashed)" flow.
#
# `replaced_check_number` mirrors the existing `reprint_of_check_number` but
# is reserved for the case where the financials of the payroll item also
# changed (i.e. the operator edited hours/bonus/etc. while reissuing the
# check, typically because the original was uncashed and handed back).
# Keeping it on a separate column lets reports and audit screens cleanly
# distinguish "physical reprint of an unchanged amount" from "amount-changed
# reissue" without inspecting check_events row-by-row.
class AddReplaceCheckColumns < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :replaced_check_number, :string
    add_index  :payroll_items, :replaced_check_number,
               where: "replaced_check_number IS NOT NULL",
               name:  "index_payroll_items_on_replaced_check_number"
  end
end
