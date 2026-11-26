# frozen_string_literal: true

# Migration and schema specs run DDL inside the example transaction, so a
# table's column order differs until that transaction rolls back. Statements
# prepared during teardown keep the changed shape, and the next example's
# identical query then fails with "cached plan must not change result type".
# Clear the connection's statement cache before the example that follows one.
module DdlStatementCache
  SPEC_PATHS = %r{\A\./spec/(migrations|db)/}

  class << self
    attr_accessor :dirty
  end
end

RSpec.configure do |config|
  config.after do |example|
    DdlStatementCache.dirty = true if example.metadata[:ddl] || example.metadata[:file_path].to_s.match?(DdlStatementCache::SPEC_PATHS)
  end

  config.before do
    next unless DdlStatementCache.dirty

    DdlStatementCache.dirty = false
    ActiveRecord::Base.connection.clear_cache!
  end
end
