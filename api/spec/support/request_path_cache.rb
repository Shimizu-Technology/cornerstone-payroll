# frozen_string_literal: true

RSpec.configure do |config|
  # Local caches are outside transactional fixtures. Reset between examples.
  config.after do
    RequestPathCache::STORE.clear
    RackAttackStore::MEMORY.clear
  end
end
