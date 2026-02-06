# WebSockets Guide (ActionCable + React)

A comprehensive guide for adding real-time features to Rails + React apps using ActionCable and WebSockets. Covers authentication, common patterns, and production deployment.

---

## Table of Contents
1. [Overview](#1-overview)
2. [ActionCable Setup in Rails 8](#2-actioncable-setup-in-rails-8)
3. [Connection Authentication with Clerk](#3-connection-authentication-with-clerk)
4. [Channel Creation Patterns](#4-channel-creation-patterns)
5. [Frontend: React + ActionCable](#5-frontend-react--actioncable)
6. [Common Real-Time Patterns](#6-common-real-time-patterns)
7. [Testing WebSocket Connections](#7-testing-websocket-connections)
8. [Redis Adapter for Production](#8-redis-adapter-for-production)
9. [Deployment (Render, Fly.io)](#9-deployment-render-flyio)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview

### What ActionCable Does

ActionCable integrates WebSockets with your Rails application. It allows you to push real-time updates from the server to connected clients — no polling required.

```
┌──────────────┐         WebSocket          ┌──────────────┐
│   React App  │ ◀══════════════════════▶   │  Rails API   │
│  (Frontend)  │    Full-duplex channel     │  (Backend)   │
└──────────────┘                            └──────────────┘
       │                                           │
  useActionCable()                          ActionCable::Channel
  @rails/actioncable                        broadcast()
```

### When to Use WebSockets

| Use Case | WebSocket? | Why |
|----------|-----------|-----|
| Order status updates | ✅ Yes | Users need instant feedback |
| Chat/messaging | ✅ Yes | Real-time by definition |
| Live notifications | ✅ Yes | Push > poll |
| Dashboard live data | ✅ Yes | Frequent small updates |
| File upload progress | ❌ No | Use HTTP progress events |
| Form submission | ❌ No | Standard REST is fine |
| Initial page load | ❌ No | Fetch data via API |

### The Shimizu Way

> **Start simple.** Don't add WebSockets until you actually need real-time. Polling every 5 seconds is perfectly fine for many use cases and dramatically simpler. When you DO need WebSockets, follow this guide.

---

## 2. ActionCable Setup in Rails 8

### 2.1 Verify ActionCable is Enabled

Rails 8 includes ActionCable by default. Check that it's mounted:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # ActionCable WebSocket endpoint
  mount ActionCable.server => '/cable'

  # ... your other routes
end
```

### 2.2 Configure the Cable

```yaml
# config/cable.yml
development:
  adapter: async

test:
  adapter: test

production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL", "redis://localhost:6379/1") %>
  channel_prefix: myapp_production
```

> **Why async for development?** The `async` adapter runs in-process — no Redis needed locally. It works fine for a single server process. In production, you need Redis so multiple web processes share the same pub/sub.

### 2.3 CORS Configuration for WebSockets

If your frontend and backend are on different domains (they usually are in the Shimizu stack):

```ruby
# config/environments/production.rb
Rails.application.configure do
  # Allow WebSocket connections from your frontend domain
  config.action_cable.allowed_request_origins = [
    ENV.fetch("FRONTEND_URL", "https://yourapp.com"),
    /https:\/\/.*\.netlify\.app/  # Netlify deploy previews
  ]

  # Mount path
  config.action_cable.mount_path = '/cable'
end
```

```ruby
# config/environments/development.rb
Rails.application.configure do
  config.action_cable.allowed_request_origins = [
    'http://localhost:3000',
    'http://localhost:5173',  # Vite dev server
    'http://127.0.0.1:5173'
  ]
end
```

### 2.4 ApplicationCable Connection

The connection class handles authentication for every WebSocket connection:

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      # We'll implement this in Section 3
      reject_unauthorized_connection
    end
  end
end
```

### 2.5 ApplicationCable Channel

```ruby
# app/channels/application_cable/channel.rb
module ApplicationCable
  class Channel < ActionCable::Channel::Base
    # Shared behavior for all channels
  end
end
```

---

## 3. Connection Authentication with Clerk

### 3.1 The Authentication Flow

```
1. React app gets JWT from Clerk
2. React connects to /cable with JWT as query param
3. Rails Connection verifies JWT
4. Connection is established (or rejected)
```

### 3.2 Rails: Verify Clerk JWT in Connection

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      token = request.params[:token]

      if token.present?
        user = authenticate_with_clerk_token(token)
        return user if user
      end

      reject_unauthorized_connection
    end

    def authenticate_with_clerk_token(token)
      # Decode and verify the Clerk JWT
      # This mirrors your existing Clerk authentication logic
      payload = decode_clerk_jwt(token)
      return nil unless payload

      clerk_user_id = payload['sub']
      return nil unless clerk_user_id

      # Find the user in your database
      User.find_by(clerk_user_id: clerk_user_id)
    rescue StandardError => e
      Rails.logger.error("ActionCable auth error: #{e.message}")
      nil
    end

    def decode_clerk_jwt(token)
      # Use your existing JWT verification logic
      # This should match what you use in your API authentication
      ClerkAuth.verify_token(token)
    end
  end
end
```

### 3.3 JWT Verification Service

If you don't already have a Clerk JWT verifier, create one:

```ruby
# app/services/clerk_auth.rb
class ClerkAuth
  CLERK_JWKS_URL = "https://#{ENV['CLERK_DOMAIN']}/.well-known/jwks.json"

  def self.verify_token(token)
    jwks_response = fetch_jwks
    jwk_keys = JWT::JWK::Set.new(jwks_response)

    payload, _header = JWT.decode(
      token,
      nil,
      true,
      {
        algorithms: ['RS256'],
        jwks: jwk_keys
      }
    )

    payload
  rescue JWT::DecodeError, JWT::ExpiredSignature => e
    Rails.logger.warn("Clerk JWT verification failed: #{e.message}")
    nil
  end

  def self.fetch_jwks
    # Cache JWKS for performance
    Rails.cache.fetch("clerk_jwks", expires_in: 1.hour) do
      response = Net::HTTP.get(URI(CLERK_JWKS_URL))
      JSON.parse(response)
    end
  end
end
```

Add the JWT gem if you haven't:

```ruby
# Gemfile
gem 'jwt'
```

### 3.4 Frontend: Connect with Token

```typescript
// src/shared/services/cable.ts
import { createConsumer } from '@rails/actioncable';

const API_BASE_URL = import.meta.env.VITE_API_URL || 'http://localhost:3000';

export function createCableConnection(token: string) {
  const wsUrl = API_BASE_URL.replace(/^http/, 'ws');
  return createConsumer(`${wsUrl}/cable?token=${token}`);
}
```

---

## 4. Channel Creation Patterns

### 4.1 Notification Channel

Push notifications to users in real-time:

```ruby
# app/channels/notification_channel.rb
class NotificationChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  def unsubscribed
    # Cleanup when client disconnects
  end
end
```

Broadcasting to a user:

```ruby
# Anywhere in your Rails app (controller, job, service)
NotificationChannel.broadcast_to(
  user,
  {
    type: 'notification',
    data: {
      id: notification.id,
      title: 'New Order',
      body: "Order ##{order.id} has been placed",
      created_at: notification.created_at.iso8601
    }
  }
)
```

### 4.2 Order Status Channel

Track order status in real-time (e.g., for a restaurant ordering app):

```ruby
# app/channels/order_status_channel.rb
class OrderStatusChannel < ApplicationCable::Channel
  def subscribed
    order = Order.find_by(id: params[:order_id])

    if order && authorized_to_view?(order)
      stream_for order
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup
  end

  private

  def authorized_to_view?(order)
    # User can view their own orders, admins can view all
    order.user_id == current_user.id || current_user.admin?
  end
end
```

Broadcasting order updates:

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  after_update_commit :broadcast_status_change, if: :saved_change_to_status?

  private

  def broadcast_status_change
    OrderStatusChannel.broadcast_to(
      self,
      {
        type: 'order_status_update',
        data: {
          id: id,
          status: status,
          updated_at: updated_at.iso8601,
          estimated_ready_at: estimated_ready_at&.iso8601
        }
      }
    )
  end
end
```

### 4.3 Chat Channel

Real-time chat with room support:

```ruby
# app/channels/chat_channel.rb
class ChatChannel < ApplicationCable::Channel
  def subscribed
    room = ChatRoom.find_by(id: params[:room_id])

    if room && room.member?(current_user)
      stream_for room
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup — e.g., broadcast that user left
  end

  def speak(data)
    message = ChatMessage.create!(
      chat_room_id: params[:room_id],
      user: current_user,
      body: data['body']
    )

    ChatChannel.broadcast_to(
      message.chat_room,
      {
        type: 'new_message',
        data: {
          id: message.id,
          body: message.body,
          user_id: message.user_id,
          user_name: message.user.name,
          created_at: message.created_at.iso8601
        }
      }
    )
  end
end
```

### 4.4 Admin Dashboard Channel

Broadcast updates to all connected admins:

```ruby
# app/channels/admin_dashboard_channel.rb
class AdminDashboardChannel < ApplicationCable::Channel
  def subscribed
    if current_user.admin? || current_user.staff?
      stream_from "admin_dashboard"
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup
  end
end
```

Broadcasting:

```ruby
# Broadcast new order to admin dashboard
ActionCable.server.broadcast(
  "admin_dashboard",
  {
    type: 'new_order',
    data: {
      id: order.id,
      total: order.total.to_f,
      items_count: order.order_items.count,
      customer_name: order.user.name,
      created_at: order.created_at.iso8601
    }
  }
)
```

### 4.5 Restaurant-Specific Channel (Multi-Tenant)

For apps that serve multiple restaurants/businesses:

```ruby
# app/channels/restaurant_channel.rb
class RestaurantChannel < ApplicationCable::Channel
  def subscribed
    restaurant = Restaurant.find_by(id: params[:restaurant_id])

    if restaurant && current_user.belongs_to_restaurant?(restaurant)
      stream_for restaurant
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup
  end
end
```

---

## 5. Frontend: React + ActionCable

### 5.1 Install the Package

```bash
npm install @rails/actioncable
```

If using TypeScript, you may also need types:

```bash
npm install --save-dev @types/rails__actioncable
```

### 5.2 ActionCable Provider (Context)

Create a React context to manage the cable connection:

```typescript
// src/shared/providers/ActionCableProvider.tsx
import React, { createContext, useContext, useEffect, useRef, useState } from 'react';
import { createConsumer, Consumer } from '@rails/actioncable';
import { useAuth } from '@clerk/clerk-react';

interface ActionCableContextType {
  cable: Consumer | null;
  connected: boolean;
}

const ActionCableContext = createContext<ActionCableContextType>({
  cable: null,
  connected: false,
});

export function useActionCable() {
  return useContext(ActionCableContext);
}

interface ActionCableProviderProps {
  children: React.ReactNode;
}

export function ActionCableProvider({ children }: ActionCableProviderProps) {
  const { getToken, isSignedIn } = useAuth();
  const [cable, setCable] = useState<Consumer | null>(null);
  const [connected, setConnected] = useState(false);
  const cableRef = useRef<Consumer | null>(null);

  useEffect(() => {
    if (!isSignedIn) {
      // Disconnect if user signs out
      if (cableRef.current) {
        cableRef.current.disconnect();
        cableRef.current = null;
        setCable(null);
        setConnected(false);
      }
      return;
    }

    async function connect() {
      try {
        const token = await getToken();
        if (!token) return;

        const apiUrl = import.meta.env.VITE_API_URL || 'http://localhost:3000';
        const wsUrl = apiUrl.replace(/^http/, 'ws');
        const consumer = createConsumer(`${wsUrl}/cable?token=${token}`);

        cableRef.current = consumer;
        setCable(consumer);
        setConnected(true);
      } catch (error) {
        console.error('ActionCable connection failed:', error);
        setConnected(false);
      }
    }

    connect();

    return () => {
      if (cableRef.current) {
        cableRef.current.disconnect();
        cableRef.current = null;
      }
    };
  }, [isSignedIn, getToken]);

  return (
    <ActionCableContext.Provider value={{ cable, connected }}>
      {children}
    </ActionCableContext.Provider>
  );
}
```

### 5.3 Wrap Your App

```tsx
// src/App.tsx
import { ClerkProvider } from '@clerk/clerk-react';
import { ActionCableProvider } from './shared/providers/ActionCableProvider';
import { AppRouter } from './router';

export default function App() {
  return (
    <ClerkProvider publishableKey={import.meta.env.VITE_CLERK_PUBLISHABLE_KEY}>
      <ActionCableProvider>
        <AppRouter />
      </ActionCableProvider>
    </ClerkProvider>
  );
}
```

### 5.4 useChannel Hook

A reusable hook for subscribing to ActionCable channels:

```typescript
// src/shared/hooks/useChannel.ts
import { useEffect, useRef, useCallback } from 'react';
import { Subscription } from '@rails/actioncable';
import { useActionCable } from '../providers/ActionCableProvider';

interface UseChannelOptions {
  channel: string;
  params?: Record<string, unknown>;
  onReceived?: (data: unknown) => void;
  onConnected?: () => void;
  onDisconnected?: () => void;
  onRejected?: () => void;
}

export function useChannel({
  channel,
  params = {},
  onReceived,
  onConnected,
  onDisconnected,
  onRejected,
}: UseChannelOptions) {
  const { cable, connected } = useActionCable();
  const subscriptionRef = useRef<Subscription | null>(null);

  // Store callbacks in refs to avoid re-subscribing on every render
  const onReceivedRef = useRef(onReceived);
  const onConnectedRef = useRef(onConnected);
  const onDisconnectedRef = useRef(onDisconnected);
  const onRejectedRef = useRef(onRejected);

  useEffect(() => {
    onReceivedRef.current = onReceived;
    onConnectedRef.current = onConnected;
    onDisconnectedRef.current = onDisconnected;
    onRejectedRef.current = onRejected;
  }, [onReceived, onConnected, onDisconnected, onRejected]);

  useEffect(() => {
    if (!cable || !connected) return;

    const subscription = cable.subscriptions.create(
      { channel, ...params },
      {
        received(data: unknown) {
          onReceivedRef.current?.(data);
        },
        connected() {
          onConnectedRef.current?.();
        },
        disconnected() {
          onDisconnectedRef.current?.();
        },
        rejected() {
          onRejectedRef.current?.();
        },
      }
    );

    subscriptionRef.current = subscription;

    return () => {
      subscription.unsubscribe();
      subscriptionRef.current = null;
    };
    // Serialize params to avoid infinite re-subscriptions
  }, [cable, connected, channel, JSON.stringify(params)]);

  const send = useCallback(
    (action: string, data: Record<string, unknown> = {}) => {
      if (subscriptionRef.current) {
        subscriptionRef.current.perform(action, data);
      }
    },
    []
  );

  return { send, connected };
}
```

### 5.5 Using the Hook in Components

#### Order Status Updates

```tsx
// src/features/orders/components/OrderTracker.tsx
import { useState, useCallback } from 'react';
import { useChannel } from '@/shared/hooks/useChannel';

interface OrderStatus {
  id: number;
  status: string;
  updated_at: string;
  estimated_ready_at: string | null;
}

interface OrderTrackerProps {
  orderId: number;
  initialStatus: string;
}

export function OrderTracker({ orderId, initialStatus }: OrderTrackerProps) {
  const [status, setStatus] = useState(initialStatus);
  const [estimatedReady, setEstimatedReady] = useState<string | null>(null);

  const handleReceived = useCallback((data: unknown) => {
    const message = data as { type: string; data: OrderStatus };

    if (message.type === 'order_status_update') {
      setStatus(message.data.status);
      setEstimatedReady(message.data.estimated_ready_at);
    }
  }, []);

  useChannel({
    channel: 'OrderStatusChannel',
    params: { order_id: orderId },
    onReceived: handleReceived,
    onConnected: () => console.log(`Tracking order #${orderId}`),
    onRejected: () => console.error('Not authorized to track this order'),
  });

  return (
    <div className="order-tracker">
      <h3>Order #{orderId}</h3>
      <StatusBadge status={status} />
      {estimatedReady && (
        <p>Estimated ready: {new Date(estimatedReady).toLocaleTimeString()}</p>
      )}
    </div>
  );
}
```

#### Live Notifications

```tsx
// src/features/notifications/components/NotificationListener.tsx
import { useCallback } from 'react';
import { useChannel } from '@/shared/hooks/useChannel';
import { useNotificationStore } from '@/shared/stores/notificationStore';
import { toast } from 'sonner';

interface NotificationData {
  type: string;
  data: {
    id: number;
    title: string;
    body: string;
    created_at: string;
  };
}

export function NotificationListener() {
  const addNotification = useNotificationStore((s) => s.addNotification);

  const handleReceived = useCallback(
    (data: unknown) => {
      const message = data as NotificationData;

      if (message.type === 'notification') {
        addNotification(message.data);
        toast(message.data.title, {
          description: message.data.body,
        });
      }
    },
    [addNotification]
  );

  useChannel({
    channel: 'NotificationChannel',
    onReceived: handleReceived,
  });

  // This component renders nothing — it just listens
  return null;
}
```

#### Chat Component

```tsx
// src/features/chat/components/ChatRoom.tsx
import { useState, useCallback, useRef, useEffect } from 'react';
import { useChannel } from '@/shared/hooks/useChannel';

interface ChatMessage {
  id: number;
  body: string;
  user_id: number;
  user_name: string;
  created_at: string;
}

interface ChatRoomProps {
  roomId: number;
  currentUserId: number;
}

export function ChatRoom({ roomId, currentUserId }: ChatRoomProps) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const handleReceived = useCallback((data: unknown) => {
    const message = data as { type: string; data: ChatMessage };

    if (message.type === 'new_message') {
      setMessages((prev) => [...prev, message.data]);
    }
  }, []);

  const { send, connected } = useChannel({
    channel: 'ChatChannel',
    params: { room_id: roomId },
    onReceived: handleReceived,
  });

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  const handleSend = () => {
    if (!input.trim()) return;

    send('speak', { body: input });
    setInput('');
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  return (
    <div className="flex flex-col h-full">
      {/* Connection Status */}
      {!connected && (
        <div className="bg-yellow-100 text-yellow-800 px-4 py-2 text-sm">
          Connecting...
        </div>
      )}

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-3">
        {messages.map((msg) => (
          <div
            key={msg.id}
            className={`flex ${
              msg.user_id === currentUserId ? 'justify-end' : 'justify-start'
            }`}
          >
            <div
              className={`rounded-lg px-4 py-2 max-w-xs ${
                msg.user_id === currentUserId
                  ? 'bg-blue-500 text-white'
                  : 'bg-gray-200 text-gray-900'
              }`}
            >
              {msg.user_id !== currentUserId && (
                <div className="text-xs font-semibold mb-1">{msg.user_name}</div>
              )}
              <p>{msg.body}</p>
            </div>
          </div>
        ))}
        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <div className="border-t p-4">
        <div className="flex gap-2">
          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a message..."
            className="flex-1 border rounded-lg px-4 py-2"
            disabled={!connected}
          />
          <button
            onClick={handleSend}
            disabled={!connected || !input.trim()}
            className="bg-blue-500 text-white px-6 py-2 rounded-lg disabled:opacity-50"
          >
            Send
          </button>
        </div>
      </div>
    </div>
  );
}
```

---

## 6. Common Real-Time Patterns

### 6.1 Optimistic Updates + WebSocket Confirmation

```tsx
// Don't wait for WebSocket — update UI immediately, then confirm
function handlePlaceOrder(orderData: OrderInput) {
  // 1. Optimistically add order to local state
  const tempId = `temp-${Date.now()}`;
  addOrder({ ...orderData, id: tempId, status: 'pending' });

  // 2. Send via REST API (not WebSocket!)
  api.post('/orders', orderData)
    .then((response) => {
      // 3. Replace temp order with real one
      replaceOrder(tempId, response.data);
    })
    .catch((error) => {
      // 4. Remove optimistic update on failure
      removeOrder(tempId);
      toast.error('Failed to place order');
    });

  // 5. WebSocket will push status updates as the order progresses
  // No additional code needed — the OrderStatusChannel handles it
}
```

### 6.2 Reconnection Handling

```typescript
// src/shared/hooks/useChannel.ts (enhanced)
// Add reconnection with exponential backoff

export function useChannelWithReconnect(options: UseChannelOptions) {
  const [isReconnecting, setIsReconnecting] = useState(false);
  const reconnectAttempts = useRef(0);
  const maxAttempts = 5;

  const handleDisconnected = useCallback(() => {
    options.onDisconnected?.();
    setIsReconnecting(true);

    // ActionCable handles reconnection internally, but you can
    // track it for UI purposes
    const backoff = Math.min(1000 * 2 ** reconnectAttempts.current, 30000);
    reconnectAttempts.current += 1;

    if (reconnectAttempts.current <= maxAttempts) {
      console.log(`Reconnecting in ${backoff}ms (attempt ${reconnectAttempts.current})`);
    }
  }, [options.onDisconnected]);

  const handleConnected = useCallback(() => {
    options.onConnected?.();
    setIsReconnecting(false);
    reconnectAttempts.current = 0;
  }, [options.onConnected]);

  const result = useChannel({
    ...options,
    onConnected: handleConnected,
    onDisconnected: handleDisconnected,
  });

  return { ...result, isReconnecting };
}
```

### 6.3 Broadcast from Background Jobs

```ruby
# app/jobs/order_notification_job.rb
class OrderNotificationJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    order = Order.find(order_id)

    # Notify the customer
    NotificationChannel.broadcast_to(
      order.user,
      {
        type: 'notification',
        data: {
          title: 'Order Update',
          body: "Your order ##{order.id} is now #{order.status.humanize}",
          order_id: order.id
        }
      }
    )

    # Notify admins
    ActionCable.server.broadcast(
      "admin_dashboard",
      {
        type: 'order_update',
        data: order.as_json(only: [:id, :status, :total, :updated_at])
      }
    )
  end
end
```

### 6.4 Presence Tracking (Who's Online)

```ruby
# app/channels/presence_channel.rb
class PresenceChannel < ApplicationCable::Channel
  def subscribed
    stream_from "presence_#{params[:room_id]}"

    # Track presence in Redis
    redis = Redis.new(url: ENV['REDIS_URL'])
    redis.sadd("presence:#{params[:room_id]}", current_user.id)

    broadcast_presence
  end

  def unsubscribed
    redis = Redis.new(url: ENV['REDIS_URL'])
    redis.srem("presence:#{params[:room_id]}", current_user.id)

    broadcast_presence
  end

  private

  def broadcast_presence
    redis = Redis.new(url: ENV['REDIS_URL'])
    user_ids = redis.smembers("presence:#{params[:room_id]}")
    users = User.where(id: user_ids).select(:id, :name, :avatar_url)

    ActionCable.server.broadcast(
      "presence_#{params[:room_id]}",
      {
        type: 'presence_update',
        data: { users: users.as_json }
      }
    )
  end
end
```

---

## 7. Testing WebSocket Connections

### 7.1 RSpec: Channel Tests

```ruby
# spec/channels/order_status_channel_spec.rb
require 'rails_helper'

RSpec.describe OrderStatusChannel, type: :channel do
  let(:user) { create(:user) }
  let(:order) { create(:order, user: user) }
  let(:other_user_order) { create(:order) }

  before do
    stub_connection current_user: user
  end

  describe '#subscribed' do
    it 'subscribes to the order stream when authorized' do
      subscribe(order_id: order.id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(order)
    end

    it 'rejects subscription for other users orders' do
      subscribe(order_id: other_user_order.id)

      expect(subscription).to be_rejected
    end

    it 'rejects subscription for non-existent orders' do
      subscribe(order_id: 999999)

      expect(subscription).to be_rejected
    end
  end
end
```

### 7.2 RSpec: Connection Tests

```ruby
# spec/channels/application_cable/connection_spec.rb
require 'rails_helper'

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user, clerk_user_id: 'clerk_123') }

  describe '#connect' do
    context 'with valid token' do
      it 'connects and identifies the user' do
        valid_token = generate_test_clerk_token(user)

        connect "/cable?token=#{valid_token}"

        expect(connection.current_user).to eq(user)
      end
    end

    context 'with invalid token' do
      it 'rejects the connection' do
        expect {
          connect "/cable?token=invalid_token"
        }.to have_rejected_connection
      end
    end

    context 'without token' do
      it 'rejects the connection' do
        expect {
          connect '/cable'
        }.to have_rejected_connection
      end
    end
  end
end
```

### 7.3 Testing Broadcasts

```ruby
# spec/models/order_spec.rb
RSpec.describe Order, type: :model do
  describe 'broadcasting' do
    let(:order) { create(:order, status: 'pending') }

    it 'broadcasts status changes' do
      expect {
        order.update!(status: 'preparing')
      }.to have_broadcasted_to(order)
        .from_channel(OrderStatusChannel)
        .with(a_hash_including(
          type: 'order_status_update',
          data: a_hash_including(status: 'preparing')
        ))
    end

    it 'does not broadcast when status unchanged' do
      expect {
        order.update!(total: 25.00)
      }.not_to have_broadcasted_to(order)
    end
  end
end
```

### 7.4 Frontend: Testing with Mocks

```typescript
// src/shared/hooks/__tests__/useChannel.test.ts
import { renderHook } from '@testing-library/react';
import { useChannel } from '../useChannel';

// Mock ActionCable
jest.mock('@rails/actioncable', () => ({
  createConsumer: jest.fn(() => ({
    subscriptions: {
      create: jest.fn((params, callbacks) => {
        // Simulate connection
        setTimeout(() => callbacks.connected(), 0);
        return {
          unsubscribe: jest.fn(),
          perform: jest.fn(),
        };
      }),
    },
    disconnect: jest.fn(),
  })),
}));

describe('useChannel', () => {
  it('calls onConnected when subscription is established', async () => {
    const onConnected = jest.fn();

    renderHook(() =>
      useChannel({
        channel: 'TestChannel',
        onConnected,
      })
    );

    await waitFor(() => {
      expect(onConnected).toHaveBeenCalled();
    });
  });
});
```

---

## 8. Redis Adapter for Production

### 8.1 Add Redis Gem

```ruby
# Gemfile
gem 'redis', '~> 5.0'
```

### 8.2 Configure Production Cable

```yaml
# config/cable.yml
production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL", "redis://localhost:6379/1") %>
  channel_prefix: myapp_production
```

### 8.3 Redis Connection Pool

For better performance under load:

```ruby
# config/initializers/action_cable.rb
if Rails.env.production?
  ActionCable.server.config.cable = {
    "adapter" => "redis",
    "url" => ENV.fetch("REDIS_URL"),
    "channel_prefix" => "myapp_production"
  }
end
```

### 8.4 Render Redis Add-On

On Render:

1. Go to your Dashboard → **New** → **Redis**
2. Choose a plan (Free tier: 25 MB, good for ActionCable)
3. Copy the **Internal URL** (use this if your web service is on the same Render region)
4. Add `REDIS_URL` to your web service environment variables

```
REDIS_URL=redis://red-xxxxx:6379
```

> **Cost note:** Render's free Redis (25 MB) is plenty for ActionCable pub/sub. You're not storing data — just passing messages. A busy app with 1000 concurrent connections uses < 1 MB for pub/sub.

---

## 9. Deployment (Render, Fly.io)

### 9.1 Render Deployment

ActionCable works on Render with standard web services. No special configuration needed — Render supports WebSocket connections natively.

```yaml
# render.yaml (Blueprint)
services:
  - type: web
    name: myapp-api
    runtime: ruby
    plan: starter  # $7/mo minimum for production
    buildCommand: bundle install && bundle exec rails db:migrate
    startCommand: bundle exec puma -C config/puma.rb
    envVars:
      - key: REDIS_URL
        fromService:
          name: myapp-redis
          type: redis
          property: connectionString
      - key: RAILS_ENV
        value: production
      - key: FRONTEND_URL
        value: https://myapp.netlify.app

  - type: redis
    name: myapp-redis
    plan: free  # 25 MB — plenty for ActionCable
    maxmemoryPolicy: allkeys-lru
```

### 9.2 Puma Configuration for WebSockets

```ruby
# config/puma.rb
max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
threads min_threads_count, max_threads_count

port ENV.fetch("PORT") { 3000 }

environment ENV.fetch("RAILS_ENV") { "development" }

# Workers (processes) for production
workers ENV.fetch("WEB_CONCURRENCY") { 2 }

preload_app!

# ActionCable requires at least 1 thread per connection
# 5 threads * 2 workers = supports ~10 concurrent WebSocket connections
# For more connections, increase threads or add workers

plugin :tmp_restart
```

### 9.3 Fly.io Deployment

If using Fly.io instead of Render:

```toml
# fly.toml
app = "myapp-api"
primary_region = "sea"

[build]
  dockerfile = "Dockerfile"

[env]
  RAILS_ENV = "production"
  PORT = "3000"

[http_service]
  internal_port = 3000
  force_https = true
  auto_stop_machines = false  # Keep alive for WebSockets
  auto_start_machines = true

  [[http_service.checks]]
    interval = "30s"
    timeout = "5s"
    path = "/up"

[[services]]
  protocol = "tcp"
  internal_port = 3000

  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]

  # WebSocket support is automatic on Fly.io
```

### 9.4 Health Check Endpoint

Add a health check that includes ActionCable status:

```ruby
# config/routes.rb
get '/up', to: proc {
  [200, {}, ['OK']]
}

get '/health', to: 'health#show'
```

```ruby
# app/controllers/health_controller.rb
class HealthController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    checks = {
      database: database_connected?,
      redis: redis_connected?,
      action_cable: action_cable_running?
    }

    status = checks.values.all? ? :ok : :service_unavailable

    render json: { status: status, checks: checks }, status: status
  end

  private

  def database_connected?
    ActiveRecord::Base.connection.active?
  rescue StandardError
    false
  end

  def redis_connected?
    Redis.new(url: ENV['REDIS_URL']).ping == 'PONG'
  rescue StandardError
    false
  end

  def action_cable_running?
    ActionCable.server.pubsub.present?
  rescue StandardError
    false
  end
end
```

---

## 10. Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| `WebSocket connection to 'ws://...' failed` | CORS not configured | Add frontend URL to `allowed_request_origins` |
| `An unauthorized connection attempt was rejected` | Bad/expired token | Check Clerk JWT verification logic |
| Messages not received across processes | Using `async` adapter in production | Switch to Redis adapter |
| Connection drops frequently | Load balancer timeout | Configure keep-alive, increase timeout |
| `No subscription found` | Channel name mismatch | Ensure frontend channel name matches Ruby class name |
| Broadcasts work in dev, not in prod | Redis not configured | Check `REDIS_URL` env var and `cable.yml` |

### Debugging Tips

```ruby
# Enable ActionCable logging in development
# config/environments/development.rb
config.action_cable.log_tags = [:action_cable, :channel]

# Log all broadcasts
ActionCable.server.config.logger = Logger.new(STDOUT)
```

```typescript
// Frontend: Enable ActionCable debug logging
import { logger } from '@rails/actioncable';
logger.enabled = true; // Logs all WS messages to console
```

### Connection Debugging Checklist

1. **Is the WebSocket URL correct?** Check protocol (`ws://` vs `wss://`) and path (`/cable`)
2. **Is the token being sent?** Check browser Network tab → WS tab
3. **Is CORS configured?** Check Rails logs for origin errors
4. **Is Redis running?** (production only) — `redis-cli ping`
5. **Are you streaming from the right identifier?** `stream_for` uses the model, `stream_from` uses a string

### Performance Considerations

- **Connection limits:** Each WebSocket connection uses a thread. With Puma (5 threads × 2 workers), you support ~10 concurrent connections. For more, increase threads or workers.
- **Memory:** Each connection uses ~50-100 KB. 1000 connections ≈ 50-100 MB.
- **Redis pub/sub:** Very lightweight — handles thousands of messages/second on a single Redis instance.
- **Don't overbroadcast:** Only send data that changed. Don't broadcast the entire model — just the updated fields.

```ruby
# ❌ Bad — sends everything
OrderStatusChannel.broadcast_to(order, order.as_json)

# ✅ Good — sends only what changed
OrderStatusChannel.broadcast_to(order, {
  type: 'order_status_update',
  data: { id: order.id, status: order.status, updated_at: order.updated_at.iso8601 }
})
```
