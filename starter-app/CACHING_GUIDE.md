# Caching Guide (Redis + Rails + React)

A comprehensive guide for caching strategies in Rails + React apps. Covers Rails cache stores, fragment caching, low-level caching, HTTP headers, client-side caching with Zustand, cache invalidation, and Redis production setup.

---

## Table of Contents
1. [Overview](#1-overview)
2. [Rails Cache Stores](#2-rails-cache-stores)
3. [Low-Level Caching (Rails.cache.fetch)](#3-low-level-caching-railscachefetch)
4. [Fragment Caching in API Responses](#4-fragment-caching-in-api-responses)
5. [Russian Doll Caching](#5-russian-doll-caching)
6. [HTTP Caching Headers](#6-http-caching-headers)
7. [React: Client-Side Caching](#7-react-client-side-caching)
8. [Cache Invalidation Strategies](#8-cache-invalidation-strategies)
9. [Redis Setup for Production](#9-redis-setup-for-production)
10. [Performance Benchmarking](#10-performance-benchmarking)
11. [Common Patterns](#11-common-patterns)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Overview

### Why Cache?

Caching reduces database queries, speeds up API responses, and lowers server costs. A well-cached app can handle 10x the traffic with the same hardware.

```
Without Caching:
  Request → Controller → Database Query (50ms) → Serialize (10ms) → Response (60ms)

With Caching:
  Request → Controller → Cache Hit (1ms) → Response (1ms)
  
  60x faster! 🚀
```

### Caching Layers

```
┌─────────────────────────────────────────────────────┐
│                    Browser Cache                      │
│  (HTTP headers: Cache-Control, ETag)                 │
└───────────────────────┬─────────────────────────────┘
                        │ Cache miss
┌───────────────────────▼─────────────────────────────┐
│                    CDN Cache                          │
│  (Netlify CDN for static assets)                     │
└───────────────────────┬─────────────────────────────┘
                        │ Cache miss
┌───────────────────────▼─────────────────────────────┐
│                 React State Cache                     │
│  (Zustand store, SWR pattern)                        │
└───────────────────────┬─────────────────────────────┘
                        │ Stale/missing
┌───────────────────────▼─────────────────────────────┐
│                 Rails API Cache                       │
│  (Rails.cache.fetch, fragment caching)               │
└───────────────────────┬─────────────────────────────┘
                        │ Cache miss
┌───────────────────────▼─────────────────────────────┐
│                    Database                           │
│  (PostgreSQL)                                        │
└─────────────────────────────────────────────────────┘
```

### The Shimizu Way

> **Don't cache prematurely.** Start with no caching. When you identify slow endpoints (>200ms), add caching there. Most CRUD apps don't need caching until they reach hundreds of concurrent users. When you do cache, start with low-level caching (`Rails.cache.fetch`) — it's the most predictable and easiest to debug.

---

## 2. Rails Cache Stores

### 2.1 Available Cache Stores

| Store | Backend | Use Case | Persistence | Speed |
|-------|---------|----------|-------------|-------|
| **Memory** | In-process RAM | Development | ❌ Per-process | ⚡ Fastest |
| **File** | Filesystem | Simple apps | ✅ Disk | 🐌 Slowest |
| **Redis** | Redis server | Production (recommended) | ✅ Redis | ⚡ Fast |
| **SolidCache** | PostgreSQL | When Redis isn't available | ✅ Database | 🟡 Medium |
| **Memcached** | Memcached server | Legacy apps | ❌ Memory only | ⚡ Fast |

### 2.2 Development: Memory Store

```ruby
# config/environments/development.rb
Rails.application.configure do
  # Enable caching in development (toggle with rails dev:cache)
  if Rails.root.join('tmp/caching-dev.txt').exist?
    config.cache_store = :memory_store, { size: 64.megabytes }
    config.action_controller.perform_caching = true
  else
    config.cache_store = :null_store
    config.action_controller.perform_caching = false
  end
end
```

Toggle caching in development:

```bash
# Enable
rails dev:cache
# => Development mode is now being cached.

# Disable
rails dev:cache
# => Development mode is no longer being cached.
```

### 2.3 Production: Redis Store

```ruby
# config/environments/production.rb
Rails.application.configure do
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),

    # Connection pool (reuse connections)
    pool_size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i,
    pool_timeout: 5,

    # Namespace to avoid key collisions
    namespace: 'myapp_cache',

    # Expiration default: 1 hour
    expires_in: 1.hour,

    # Error handling: fall back to direct DB query on Redis failure
    error_handler: lambda { |method:, returning:, exception:|
      Rails.logger.error("Redis cache error: #{exception.message}")
      Sentry.capture_exception(exception) if defined?(Sentry)
    },

    # Compression for values > 1KB
    compress: true,
    compress_threshold: 1.kilobyte,
  }
end
```

### 2.4 SolidCache (No Redis Needed)

Rails 8 introduced SolidCache — uses your existing PostgreSQL:

```ruby
# Gemfile
gem 'solid_cache'
```

```bash
rails solid_cache:install:migrations
rails db:migrate
```

```ruby
# config/environments/production.rb
config.cache_store = :solid_cache_store
```

```yaml
# config/solid_cache.yml
production:
  database: cache  # Uses a separate database (recommended)
  store_options:
    max_age: 1.week.to_i
    max_size: 256.megabytes
    namespace: myapp
```

> **When to use SolidCache vs Redis:**
> - **SolidCache:** You don't want to manage Redis, your cache is < 1 GB, and latency of 5-10ms is acceptable.
> - **Redis:** You need sub-millisecond latency, you already have Redis (for ActionCable/Sidekiq), or you cache > 1 GB of data.

### 2.5 Test: Null Store

```ruby
# config/environments/test.rb
Rails.application.configure do
  config.cache_store = :null_store  # Don't cache in tests
end
```

---

## 3. Low-Level Caching (Rails.cache.fetch)

### 3.1 Basic Pattern

```ruby
# The most common and useful caching pattern
result = Rails.cache.fetch("menu_items/restaurant_#{restaurant_id}", expires_in: 15.minutes) do
  # This block only runs on cache MISS
  MenuItem.where(restaurant_id: restaurant_id)
          .includes(:category, :modifier_groups)
          .order(:position)
          .to_a
end
```

### 3.2 Cache Keys

Good cache keys are specific, unique, and contain version information:

```ruby
# ❌ Bad — too generic, no versioning
Rails.cache.fetch("menu") { ... }

# ❌ Bad — no expiration, stale forever
Rails.cache.fetch("menu/#{restaurant.id}") { ... }

# ✅ Good — scoped, versioned, expires
Rails.cache.fetch("menu/#{restaurant.id}/#{restaurant.updated_at.to_i}", expires_in: 1.hour) { ... }

# ✅ Also good — model cache_key includes updated_at
Rails.cache.fetch(restaurant.cache_key_with_version) { ... }

# ✅ Best for collections — include count and max updated_at
Rails.cache.fetch("menu_items/r#{restaurant.id}/#{MenuItem.where(restaurant_id: restaurant.id).cache_key_with_version}") { ... }
```

### 3.3 Common Caching Patterns

#### Cache Expensive Queries

```ruby
# app/models/restaurant.rb
class Restaurant < ApplicationRecord
  def menu_data
    Rails.cache.fetch("#{cache_key_with_version}/menu_data", expires_in: 15.minutes) do
      {
        categories: categories.includes(menu_items: :modifier_groups).order(:position).map do |cat|
          {
            id: cat.id,
            name: cat.name,
            items: cat.menu_items.available.map { |item| item_data(item) }
          }
        end
      }
    end
  end

  private

  def item_data(item)
    {
      id: item.id,
      name: item.name,
      price: item.price.to_f,
      description: item.description,
      image_url: item.image_url,
      modifier_groups: item.modifier_groups.map { |mg| modifier_group_data(mg) }
    }
  end
end
```

#### Cache API Responses

```ruby
# app/controllers/api/v1/menus_controller.rb
class Api::V1::MenusController < ApplicationController
  skip_before_action :authenticate_user!  # Public endpoint

  def show
    restaurant = Restaurant.find(params[:restaurant_id])

    # Cache the entire JSON response
    cache_key = "api/menu/#{restaurant.id}/#{restaurant.updated_at.to_i}"
    json = Rails.cache.fetch(cache_key, expires_in: 15.minutes) do
      restaurant.menu_data.to_json
    end

    render json: json
  end
end
```

#### Cache Calculations

```ruby
# app/models/restaurant.rb
class Restaurant < ApplicationRecord
  def daily_stats(date = Date.current)
    Rails.cache.fetch("stats/#{id}/#{date}", expires_in: 5.minutes) do
      orders = self.orders.where(created_at: date.all_day)
      {
        total_orders: orders.count,
        total_revenue: orders.sum(:total).to_f,
        average_order: orders.average(:total)&.to_f&.round(2) || 0,
        top_items: top_items_for_date(date)
      }
    end
  end
end
```

#### Cache External API Calls

```ruby
# app/services/geocoding_service.rb
class GeocodingService
  def self.geocode(address)
    Rails.cache.fetch("geocode/#{Digest::MD5.hexdigest(address)}", expires_in: 1.week) do
      # External API call — expensive and rate-limited
      response = HTTParty.get("https://api.mapbox.com/geocoding/v5/mapbox.places/#{URI.encode_www_form_component(address)}.json", query: {
        access_token: ENV['MAPBOX_TOKEN']
      })
      data = response.parsed_response
      {
        lat: data.dig('features', 0, 'center', 1),
        lng: data.dig('features', 0, 'center', 0)
      }
    end
  end
end
```

### 3.4 Cache Options

```ruby
Rails.cache.fetch("key",
  expires_in: 15.minutes,     # TTL — auto-expire after 15 minutes
  race_condition_ttl: 10,     # Prevent thundering herd (see Section 8)
  force: params[:refresh],    # Force cache miss (bypass cache)
  compress: true,             # Compress large values
  compress_threshold: 1.kilobyte,
) do
  expensive_operation
end
```

---

## 4. Fragment Caching in API Responses

### 4.1 Jbuilder Caching

If you use Jbuilder for JSON responses:

```ruby
# app/views/api/v1/restaurants/show.json.jbuilder
json.cache! @restaurant do
  json.extract! @restaurant, :id, :name, :description, :address

  json.categories @restaurant.categories.includes(:menu_items) do |category|
    json.cache! category do
      json.extract! category, :id, :name, :position

      json.items category.menu_items.available do |item|
        json.cache! item do
          json.extract! item, :id, :name, :price, :description, :image_url
        end
      end
    end
  end
end
```

### 4.2 Serializer Caching

If you use a serializer (e.g., Alba, Blueprinter):

```ruby
# app/serializers/menu_item_serializer.rb
class MenuItemSerializer
  include Alba::Resource

  attributes :id, :name, :description, :image_url

  attribute :price do |item|
    item.price.to_f
  end

  # Cache the serialized output
  def self.cached_render(item)
    Rails.cache.fetch("serialized/menu_item/#{item.cache_key_with_version}") do
      new(item).serialize
    end
  end

  def self.cached_render_collection(items)
    items.map { |item| cached_render(item) }
  end
end
```

### 4.3 Manual JSON Caching

For maximum control:

```ruby
# app/controllers/api/v1/menus_controller.rb
class Api::V1::MenusController < ApplicationController
  def show
    restaurant = Restaurant.find(params[:restaurant_id])

    # Check if we have a cached response
    cache_key = menu_cache_key(restaurant)
    cached = Rails.cache.read(cache_key)

    if cached
      # Serve cached JSON directly — fastest possible response
      render json: cached
      return
    end

    # Generate fresh response
    data = build_menu_response(restaurant)
    json = data.to_json

    # Cache it
    Rails.cache.write(cache_key, json, expires_in: 15.minutes)

    render json: json
  end

  private

  def menu_cache_key(restaurant)
    max_updated = MenuItem.where(restaurant_id: restaurant.id).maximum(:updated_at)
    "api/v1/menu/#{restaurant.id}/#{max_updated&.to_i}"
  end

  def build_menu_response(restaurant)
    # ... build the response hash
  end
end
```

---

## 5. Russian Doll Caching

### 5.1 What is Russian Doll Caching?

Nested caches where outer caches contain inner caches. When an inner item changes, only that item's cache is busted — the outer cache rebuilds efficiently.

```
┌─ Restaurant Cache ─────────────────────────┐
│                                             │
│  ┌─ Category Cache ──────────────────────┐  │
│  │                                       │  │
│  │  ┌─ MenuItem Cache ─┐ ┌─ MenuItem ─┐ │  │
│  │  │  Pizza Margherita │ │  Calzone   │ │  │
│  │  └──────────────────┘ └────────────┘ │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ┌─ Category Cache ──────────────────────┐  │
│  │  ... more items ...                   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### 5.2 Implementation with `touch`

The key is `touch: true` on associations — when a child updates, it "touches" the parent, updating its `updated_at`:

```ruby
# app/models/menu_item.rb
class MenuItem < ApplicationRecord
  belongs_to :category, touch: true  # ← touch parent when item changes
end

# app/models/category.rb
class Category < ApplicationRecord
  belongs_to :restaurant, touch: true  # ← touch parent when category changes
  has_many :menu_items, dependent: :destroy
end

# app/models/restaurant.rb
class Restaurant < ApplicationRecord
  has_many :categories, dependent: :destroy
  has_many :menu_items, through: :categories
end
```

Now the cache chain:

```ruby
# When a MenuItem is updated:
# 1. MenuItem.updated_at changes → MenuItem cache busted
# 2. Category.updated_at changes (touch) → Category cache busted
# 3. Restaurant.updated_at changes (touch) → Restaurant cache busted

# The cache_key_with_version includes updated_at, so:
Rails.cache.fetch(restaurant.cache_key_with_version) do
  # This rebuilds, but inner caches for UNCHANGED items still hit
  restaurant.categories.map do |category|
    Rails.cache.fetch(category.cache_key_with_version) do
      category.menu_items.map do |item|
        Rails.cache.fetch(item.cache_key_with_version) do
          serialize_item(item)
        end
      end
    end
  end
end
```

### 5.3 When to Use Russian Doll Caching

| Scenario | Use Russian Doll? | Why |
|----------|-------------------|-----|
| Menu with categories + items | ✅ Yes | Nested, items change independently |
| User profile | ❌ No | Flat structure, just cache the whole thing |
| Dashboard stats | ❌ No | Recalculate entirely |
| Product catalog | ✅ Yes | Similar nesting to menus |

---

## 6. HTTP Caching Headers

### 6.1 Cache-Control Headers

Set HTTP headers so browsers and CDNs cache responses:

```ruby
# app/controllers/api/v1/menus_controller.rb
class Api::V1::MenusController < ApplicationController
  def show
    restaurant = Restaurant.find(params[:restaurant_id])

    # Public cache — can be cached by CDNs and browsers
    expires_in 15.minutes, public: true

    render json: restaurant.menu_data
  end
end
```

### 6.2 ETag/Conditional Requests

ETags allow clients to ask "has this changed?" without downloading the full response:

```ruby
# app/controllers/api/v1/menus_controller.rb
class Api::V1::MenusController < ApplicationController
  def show
    restaurant = Restaurant.find(params[:restaurant_id])

    # Generate ETag from restaurant's updated_at
    if stale?(restaurant)
      render json: restaurant.menu_data
    end
    # If not stale, Rails automatically returns 304 Not Modified
  end
end
```

### 6.3 Private vs Public Caching

```ruby
# Public — safe for CDNs (no user-specific data)
expires_in 1.hour, public: true
# Sets: Cache-Control: public, max-age=3600

# Private — only the user's browser should cache
expires_in 5.minutes, private: true
# Sets: Cache-Control: private, max-age=300

# No caching (user-specific, sensitive data)
response.headers['Cache-Control'] = 'no-store'
```

### 6.4 Which Endpoints to Cache

| Endpoint | Cache-Control | Why |
|----------|--------------|-----|
| `GET /menu` | `public, max-age=900` | Same for all users |
| `GET /restaurants` | `public, max-age=3600` | Rarely changes |
| `GET /orders` | `private, max-age=60` | User-specific |
| `GET /profile` | `private, no-cache` | User-specific, changes |
| `POST /orders` | `no-store` | Mutations never cached |
| `GET /admin/stats` | `private, max-age=300` | Admin only, can be stale |

---

## 7. React: Client-Side Caching

### 7.1 SWR Pattern with Zustand

The SWR (stale-while-revalidate) pattern: serve cached data immediately, then fetch fresh data in the background.

```typescript
// src/shared/stores/menuStore.ts
import { create } from 'zustand';
import api from '@/shared/services/api';

interface MenuState {
  // Data
  menu: MenuData | null;
  lastFetched: number | null;

  // Loading
  isLoading: boolean;
  error: string | null;

  // Actions
  fetchMenu: (restaurantId: number, options?: { force?: boolean }) => Promise<void>;
  invalidateMenu: () => void;
}

const CACHE_DURATION = 5 * 60 * 1000; // 5 minutes

export const useMenuStore = create<MenuState>((set, get) => ({
  menu: null,
  lastFetched: null,
  isLoading: false,
  error: null,

  fetchMenu: async (restaurantId, options = {}) => {
    const state = get();

    // Check if cache is still fresh
    if (
      !options.force &&
      state.menu &&
      state.lastFetched &&
      Date.now() - state.lastFetched < CACHE_DURATION
    ) {
      return; // Use cached data
    }

    // If we have stale data, don't show loading (SWR pattern)
    if (!state.menu) {
      set({ isLoading: true });
    }

    try {
      const { data } = await api.get(`/restaurants/${restaurantId}/menu`);
      set({
        menu: data,
        lastFetched: Date.now(),
        isLoading: false,
        error: null,
      });
    } catch (error) {
      set({
        error: 'Failed to load menu',
        isLoading: false,
      });
    }
  },

  invalidateMenu: () => {
    set({ lastFetched: null }); // Force refetch on next access
  },
}));
```

### 7.2 Using the Cache in Components

```tsx
// src/features/menu/components/MenuPage.tsx
import { useEffect } from 'react';
import { useMenuStore } from '@/shared/stores/menuStore';

export function MenuPage({ restaurantId }: { restaurantId: number }) {
  const { menu, isLoading, error, fetchMenu } = useMenuStore();

  useEffect(() => {
    fetchMenu(restaurantId);
  }, [restaurantId, fetchMenu]);

  if (isLoading && !menu) return <LoadingSpinner />;
  if (error && !menu) return <ErrorMessage message={error} />;
  if (!menu) return null;

  return (
    <div>
      {menu.categories.map((category) => (
        <MenuCategory key={category.id} category={category} />
      ))}
    </div>
  );
}
```

### 7.3 Multi-Resource Cache Store

```typescript
// src/shared/stores/cacheStore.ts
import { create } from 'zustand';

interface CacheEntry<T> {
  data: T;
  fetchedAt: number;
  expiresIn: number;
}

interface CacheState {
  entries: Record<string, CacheEntry<unknown>>;
  get: <T>(key: string) => T | null;
  set: <T>(key: string, data: T, expiresIn?: number) => void;
  invalidate: (key: string) => void;
  invalidatePattern: (pattern: string) => void;
  clear: () => void;
}

const DEFAULT_TTL = 5 * 60 * 1000; // 5 minutes

export const useCacheStore = create<CacheState>((set, get) => ({
  entries: {},

  get: <T>(key: string): T | null => {
    const entry = get().entries[key] as CacheEntry<T> | undefined;
    if (!entry) return null;

    const isExpired = Date.now() - entry.fetchedAt > entry.expiresIn;
    if (isExpired) {
      // Clean up expired entry
      set((state) => {
        const { [key]: _, ...rest } = state.entries;
        return { entries: rest };
      });
      return null;
    }

    return entry.data;
  },

  set: <T>(key: string, data: T, expiresIn = DEFAULT_TTL) => {
    set((state) => ({
      entries: {
        ...state.entries,
        [key]: { data, fetchedAt: Date.now(), expiresIn },
      },
    }));
  },

  invalidate: (key) => {
    set((state) => {
      const { [key]: _, ...rest } = state.entries;
      return { entries: rest };
    });
  },

  invalidatePattern: (pattern) => {
    set((state) => {
      const regex = new RegExp(pattern);
      const filtered = Object.fromEntries(
        Object.entries(state.entries).filter(([key]) => !regex.test(key))
      );
      return { entries: filtered };
    });
  },

  clear: () => set({ entries: {} }),
}));
```

Usage:

```typescript
// Fetch with caching
async function fetchRestaurant(id: number) {
  const cache = useCacheStore.getState();
  const cached = cache.get<Restaurant>(`restaurant:${id}`);

  if (cached) return cached;

  const { data } = await api.get(`/restaurants/${id}`);
  cache.set(`restaurant:${id}`, data, 10 * 60 * 1000); // 10 minutes
  return data;
}

// Invalidate after mutation
async function updateRestaurant(id: number, updates: Partial<Restaurant>) {
  await api.patch(`/restaurants/${id}`, updates);
  useCacheStore.getState().invalidate(`restaurant:${id}`);
  useCacheStore.getState().invalidatePattern(`^menu:${id}`);
}
```

### 7.4 React Query Alternative

If you want a more full-featured solution, consider React Query (TanStack Query):

```typescript
// src/shared/hooks/useMenu.ts
import { useQuery } from '@tanstack/react-query';
import api from '@/shared/services/api';

export function useMenu(restaurantId: number) {
  return useQuery({
    queryKey: ['menu', restaurantId],
    queryFn: () => api.get(`/restaurants/${restaurantId}/menu`).then((r) => r.data),
    staleTime: 5 * 60 * 1000,     // Data is fresh for 5 minutes
    cacheTime: 30 * 60 * 1000,    // Keep in cache for 30 minutes
    refetchOnWindowFocus: false,    // Don't refetch on tab focus
  });
}
```

> **Zustand vs React Query:** Zustand is simpler and we're already using it for state management. React Query is better if you have many different API calls to cache. For most Shimizu starter apps, the Zustand SWR pattern is sufficient.

---

## 8. Cache Invalidation Strategies

### 8.1 Time-Based Expiration (Simplest)

```ruby
# Cache expires after 15 minutes — no manual invalidation needed
Rails.cache.fetch("menu/#{restaurant.id}", expires_in: 15.minutes) do
  build_menu_data(restaurant)
end
```

**Pros:** Dead simple. No invalidation code.
**Cons:** Data can be stale for up to 15 minutes.

### 8.2 Key-Based Invalidation (Recommended)

Include version information in the cache key. When data changes, the key changes, and the old cache is ignored:

```ruby
# cache_key_with_version includes updated_at timestamp
# When restaurant updates, the key changes automatically
Rails.cache.fetch(restaurant.cache_key_with_version) do
  build_menu_data(restaurant)
end

# For collections:
max_updated = MenuItem.where(restaurant_id: restaurant.id).maximum(:updated_at)
count = MenuItem.where(restaurant_id: restaurant.id).count
cache_key = "menu/#{restaurant.id}/#{count}/#{max_updated.to_i}"

Rails.cache.fetch(cache_key, expires_in: 1.hour) do
  build_menu_data(restaurant)
end
```

**Pros:** Automatic invalidation. Data is never stale.
**Cons:** Orphaned cache entries (old keys) until they expire.

### 8.3 Explicit Invalidation (When Needed)

```ruby
# app/models/menu_item.rb
class MenuItem < ApplicationRecord
  after_commit :invalidate_cache

  private

  def invalidate_cache
    Rails.cache.delete("menu/#{restaurant_id}")
    Rails.cache.delete_matched("api/v1/menu/#{restaurant_id}/*")
  end
end
```

```ruby
# app/controllers/api/v1/admin/menu_items_controller.rb
class Api::V1::Admin::MenuItemsController < ApplicationController
  def update
    @menu_item = MenuItem.find(params[:id])
    @menu_item.update!(menu_item_params)

    # Explicitly bust the cache
    Rails.cache.delete("menu/#{@menu_item.restaurant_id}")

    render json: @menu_item
  end
end
```

### 8.4 Preventing the Thundering Herd

When a popular cache key expires, many requests simultaneously try to rebuild it:

```ruby
# race_condition_ttl extends the old cache while ONE request rebuilds
Rails.cache.fetch("popular_menu/#{restaurant.id}",
  expires_in: 15.minutes,
  race_condition_ttl: 30.seconds  # ← Prevents thundering herd
) do
  # Only one request runs this. Others get the slightly stale value.
  build_menu_data(restaurant)
end
```

### 8.5 Cache Warming

Pre-populate caches before users hit them:

```ruby
# app/jobs/cache_warmer_job.rb
class CacheWarmerJob < ApplicationJob
  queue_as :low

  def perform
    # Warm menu caches for active restaurants
    Restaurant.active.find_each do |restaurant|
      cache_key = "menu/#{restaurant.id}/#{restaurant.updated_at.to_i}"
      next if Rails.cache.exist?(cache_key)

      Rails.cache.fetch(cache_key, expires_in: 1.hour) do
        restaurant.menu_data
      end
    end
  end
end

# Schedule it
# config/initializers/good_job.rb
config.good_job.cron = {
  cache_warmer: {
    cron: '*/30 * * * *',  # Every 30 minutes
    class: 'CacheWarmerJob'
  }
}
```

---

## 9. Redis Setup for Production

### 9.1 Render Redis Add-On

1. Go to Render Dashboard → **New** → **Redis**
2. Choose a plan:

| Plan | Memory | Cost | Use Case |
|------|--------|------|----------|
| Free | 25 MB | $0/mo | ActionCable only |
| Starter | 100 MB | $10/mo | Caching + ActionCable |
| Standard | 256 MB | $30/mo | Heavy caching |
| Pro | 1 GB | $85/mo | Large datasets |

3. Copy the **Internal URL** (e.g., `redis://red-xxx:6379`)
4. Add `REDIS_URL` to your web service environment

### 9.2 Redis for Multiple Purposes

If using Redis for caching AND ActionCable AND Sidekiq, use different databases:

```ruby
# Caching: database 0
config.cache_store = :redis_cache_store, {
  url: "#{ENV['REDIS_URL']}/0",
  namespace: 'cache'
}

# ActionCable: database 1
# config/cable.yml
production:
  adapter: redis
  url: <%= "#{ENV['REDIS_URL']}/1" %>
  channel_prefix: cable

# Sidekiq: database 2
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.redis = { url: "#{ENV['REDIS_URL']}/2" }
end
```

### 9.3 Redis Memory Policy

Configure Redis to evict old cache entries when memory is full:

```
# On Render, set maxmemory-policy in Redis settings:
maxmemory-policy: allkeys-lru
```

| Policy | Behavior | Best For |
|--------|----------|----------|
| `allkeys-lru` | Evict least recently used keys | Caching (recommended) |
| `volatile-lru` | Evict LRU keys with TTL only | Mixed caching + persistent data |
| `noeviction` | Return errors when full | Sidekiq (don't lose jobs!) |

> **Warning:** If using Redis for both caching and Sidekiq, use separate Redis instances or databases with different eviction policies!

### 9.4 Connection Pooling

```ruby
# config/initializers/redis.rb
$redis = ConnectionPool::Wrapper.new(size: ENV.fetch('REDIS_POOL_SIZE', 5).to_i) do
  Redis.new(url: ENV['REDIS_URL'])
end

# Use it anywhere:
$redis.set("key", "value")
$redis.get("key")
```

---

## 10. Performance Benchmarking

### 10.1 Measure Before and After

```ruby
# app/controllers/concerns/response_timer.rb
module ResponseTimer
  extend ActiveSupport::Concern

  included do
    around_action :log_response_time
  end

  private

  def log_response_time
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    response.headers['X-Response-Time'] = "#{(elapsed * 1000).round}ms"

    if elapsed > 1.0
      Rails.logger.warn("Slow response: #{request.path} took #{(elapsed * 1000).round}ms")
    end
  end
end
```

### 10.2 Rails Console Benchmarking

```ruby
# In Rails console: compare cached vs uncached
require 'benchmark'

restaurant = Restaurant.first

# Clear cache first
Rails.cache.delete_matched("menu/#{restaurant.id}*")

# Benchmark uncached
uncached = Benchmark.measure { restaurant.menu_data }
puts "Uncached: #{(uncached.real * 1000).round}ms"

# Benchmark cached
restaurant.menu_data  # Warm the cache
cached = Benchmark.measure { restaurant.menu_data }
puts "Cached: #{(cached.real * 1000).round}ms"

puts "Speedup: #{(uncached.real / cached.real).round}x"
```

### 10.3 Cache Hit Rate Monitoring

```ruby
# config/initializers/cache_instrumentation.rb
ActiveSupport::Notifications.subscribe('cache_read.active_support') do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  hit = event.payload[:hit]

  # Track cache hit rate (send to your monitoring tool)
  StatsD.increment('cache.read', tags: ["hit:#{hit}"])
end

# Or simpler: log cache misses
ActiveSupport::Notifications.subscribe('cache_read.active_support') do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  unless event.payload[:hit]
    Rails.logger.info("Cache MISS: #{event.payload[:key]}")
  end
end
```

### 10.4 Quick Performance Check

```ruby
# Add to a controller for quick debugging
def show
  start = Time.current

  # ... your action logic

  elapsed = ((Time.current - start) * 1000).round
  Rails.logger.info("#{controller_name}##{action_name}: #{elapsed}ms")
end
```

---

## 11. Common Patterns

### 11.1 Cache Aside Pattern (Most Common)

```ruby
# Read: Check cache first, fall back to DB
def get_menu(restaurant_id)
  Rails.cache.fetch("menu:#{restaurant_id}", expires_in: 15.minutes) do
    Restaurant.find(restaurant_id).menu_data
  end
end

# Write: Update DB, then invalidate cache
def update_menu_item(item_id, params)
  item = MenuItem.find(item_id)
  item.update!(params)
  Rails.cache.delete("menu:#{item.restaurant_id}")
end
```

### 11.2 Counter Caching

```ruby
# Instead of counting with SQL every time:
# SELECT COUNT(*) FROM orders WHERE restaurant_id = 1 AND status = 'pending'

# Use Rails counter cache:
class Order < ApplicationRecord
  belongs_to :restaurant, counter_cache: true
  # Requires `orders_count` column on restaurants table
end

# Or cache the count yourself for filtered counts:
class Restaurant < ApplicationRecord
  def pending_orders_count
    Rails.cache.fetch("#{cache_key}/pending_orders_count", expires_in: 1.minute) do
      orders.where(status: 'pending').count
    end
  end
end
```

### 11.3 Memoization (Per-Request Cache)

```ruby
# Cache within a single request (no Redis, no external cache)
class Restaurant < ApplicationRecord
  def menu_data
    @menu_data ||= build_menu_data
  end

  # Reset memoization
  def reload
    @menu_data = nil
    super
  end
end
```

### 11.4 Cache Stampede Prevention

```ruby
# When a popular cache key expires, prevent all requests from hitting DB
Rails.cache.fetch("homepage_stats",
  expires_in: 5.minutes,
  race_condition_ttl: 30.seconds
) do
  {
    total_restaurants: Restaurant.count,
    total_orders_today: Order.where(created_at: Date.current.all_day).count,
    popular_items: MenuItem.most_ordered.limit(10)
  }
end
```

---

## 12. Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Cache always misses | Cache key changes every request | Check that key is stable (no random values) |
| Stale data after update | No invalidation | Add `touch: true` or explicit invalidation |
| Redis connection error | Wrong URL or Redis down | Check `REDIS_URL`, check Redis status |
| Memory growing in Redis | No expiration set | Add `expires_in` to all cache writes |
| Cache works in dev, not prod | Different cache stores | Check `config.cache_store` per environment |
| `delete_matched` slow | Redis KEYS command scans all keys | Use namespaced keys and `delete` instead |

### Debugging Cache

```ruby
# Check if a key exists
Rails.cache.exist?("menu:1")  # => true/false

# Read without the block (won't populate on miss)
Rails.cache.read("menu:1")  # => data or nil

# Check what's in Redis
redis = Redis.new(url: ENV['REDIS_URL'])
redis.keys("myapp_cache:*").count  # Number of cached entries
redis.info['used_memory_human']     # Memory usage

# Clear all caches (nuclear option)
Rails.cache.clear
```

### Performance Checklist

1. **Identify slow endpoints** — check logs for responses > 200ms
2. **Add `Rails.cache.fetch`** to the slowest queries
3. **Set appropriate TTL** — shorter for frequently changing data
4. **Add `touch: true`** to associations for automatic invalidation
5. **Monitor cache hit rate** — aim for > 80%
6. **Watch Redis memory** — set `maxmemory-policy` appropriately
7. **Don't over-cache** — caching adds complexity. Only cache what's slow.

### Cache Decision Tree

```
Is the endpoint slow (>200ms)?
├── No → Don't cache
└── Yes → Is the data user-specific?
          ├── Yes → Use private HTTP cache + Rails.cache
          │         (shorter TTL: 1-5 minutes)
          └── No  → Is it the same for all users?
                    ├── Yes → Use public HTTP cache + Rails.cache
                    │         (longer TTL: 15-60 minutes)
                    └── No  → Use Rails.cache with scoped keys
                              (TTL based on change frequency)
```

> **The Shimizu Way:** Cache the read path, not the write path. Most apps are read-heavy (90% reads, 10% writes). Focus caching on your busiest GET endpoints and leave mutations uncached.
