# frozen_string_literal: true

# A Cornerstone Tax client can now be linked straight to an invoice customer
# that has no Payroll client (disposition "recipient"), so its hours and the
# fees on that customer's invoices land on one profitability row.
class AddInvoiceRecipientToWorkHourClientLinks < ActiveRecord::Migration[8.1]
  CONSTRAINT = "work_hour_client_link_disposition_valid"

  def up
    # No cascade: deleting a customer must not silently drop saved links
    # (InvoiceRecipient archives instead while links reference it).
    add_reference :work_hour_client_links, :invoice_recipient, foreign_key: true
    remove_check_constraint :work_hour_client_links, name: CONSTRAINT
    add_check_constraint :work_hour_client_links, <<~SQL.squish, name: CONSTRAINT
      (disposition = 'company' AND company_id IS NOT NULL AND invoice_recipient_id IS NULL) OR
      (disposition = 'recipient' AND invoice_recipient_id IS NOT NULL AND company_id IS NULL) OR
      (disposition = 'internal' AND company_id IS NULL AND invoice_recipient_id IS NULL)
    SQL
  end

  def down
    execute("UPDATE work_hour_client_links SET active = false, disposition = 'internal', invoice_recipient_id = NULL WHERE disposition = 'recipient'")
    remove_check_constraint :work_hour_client_links, name: CONSTRAINT
    add_check_constraint :work_hour_client_links,
                         "(disposition = 'company' AND company_id IS NOT NULL) OR (disposition = 'internal' AND company_id IS NULL)",
                         name: CONSTRAINT
    remove_reference :work_hour_client_links, :invoice_recipient, foreign_key: true
  end
end
