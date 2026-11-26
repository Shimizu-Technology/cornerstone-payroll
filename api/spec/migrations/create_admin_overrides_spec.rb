# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127130000_create_admin_overrides")

RSpec.describe CreateAdminOverrides do
  [ true, false ].each do |enforced|
    it "preserves #{enforced ? 'enforced' : 'shadow'} RLS on the new override table" do
      connection = ApplicationRecord.connection
      connection.transaction(requires_new: true) do
        connection.execute("DROP TABLE admin_overrides")
        connection.execute("ALTER TABLE pay_periods DROP COLUMN rollback_review_required")
        connection.execute("ALTER TABLE employee_account_links #{enforced ? 'ENABLE' : 'DISABLE'} ROW LEVEL SECURITY")

        described_class.new.migrate(:up)

        expect(connection.select_rows(<<~SQL)).to eq([ [ enforced, enforced ] ])
          SELECT relrowsecurity, relforcerowsecurity
          FROM pg_class WHERE oid = 'admin_overrides'::regclass
        SQL
        expect(RlsDatabase.policy_mismatches(connection, [ "admin_overrides" ])).to be_empty
        raise ActiveRecord::Rollback
      end
    end
  end
end
