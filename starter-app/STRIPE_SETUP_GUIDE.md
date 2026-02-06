# Stripe Integration Guide — Starter App

> **For:** AI coding agents (Claude, Cursor, etc.) building on the Shimizu Technology starter-app  
> **Stack:** Ruby on Rails (backend) + React/TypeScript (frontend)  
> **Last updated:** 2025-07-13

---

## Table of Contents

1. [Stripe Account & Dashboard Setup](#1-stripe-account--dashboard-setup)
2. [Backend Integration (Rails)](#2-backend-integration-rails)
3. [Frontend Integration (React/TypeScript)](#3-frontend-integration-reacttypescript)
4. [Testing](#4-testing)
5. [Going to Production Checklist](#5-going-to-production-checklist)
6. [Fee Handling (Passing Fees to Customer)](#6-fee-handling-passing-fees-to-customer)

---

## 1. Stripe Account & Dashboard Setup

### Creating an Account

1. Go to [https://dashboard.stripe.com/register](https://dashboard.stripe.com/register)
2. Create an account with the business email
3. You start in **test mode** by default — no real money moves until you activate your account

### Test Mode vs Live Mode

Stripe has two completely separate environments. Every object (customers, payments, subscriptions) exists only in the mode it was created in.

| Aspect | Test Mode | Live Mode |
|--------|-----------|-----------|
| Dashboard toggle | Top-right: "Test mode" switch ON | Switch OFF |
| API key prefix | `pk_test_`, `sk_test_` | `pk_live_`, `sk_live_` |
| Real charges | ❌ No | ✅ Yes |
| Test cards work | ✅ Yes | ❌ No |
| Webhooks | Separate endpoints | Separate endpoints |
| Customer data | Isolated | Isolated |

**⚠️ Key rule:** Test and live environments share NOTHING. A customer created in test mode does not exist in live mode.

### API Keys

Find them at: **Dashboard → Developers → API keys**

You need two keys per environment:

- **Publishable key** (`pk_test_...` / `pk_live_...`) — Safe for frontend. Loaded in the browser. Can only create tokens and confirm payments.
- **Secret key** (`sk_test_...` / `sk_live_...`) — Backend only. **NEVER expose in frontend code, git, or logs.** Can do everything: charge cards, issue refunds, manage customers.

### Environment Variables

**Backend `.env` (Rails root):**

```bash
# Stripe — Test Mode (default for development)
STRIPE_PUBLISHABLE_KEY=pk_test_xxxxxxxxxxxxxxxxxxxxxxxx
STRIPE_SECRET_KEY=sk_test_xxxxxxxxxxxxxxxxxxxxxxxx
STRIPE_WEBHOOK_SECRET=whsec_xxxxxxxxxxxxxxxxxxxxxxxx

# For production, swap to live keys:
# STRIPE_PUBLISHABLE_KEY=pk_live_xxxxxxxxxxxxxxxxxxxxxxxx
# STRIPE_SECRET_KEY=sk_live_xxxxxxxxxxxxxxxxxxxxxxxx
# STRIPE_WEBHOOK_SECRET=whsec_xxxxxxxxxxxxxxxxxxxxxxxx (live webhook signing secret)
```

**Frontend `.env` (React app root):**

```bash
# Only the publishable key goes here — this is safe for the browser
VITE_STRIPE_PUBLISHABLE_KEY=pk_test_xxxxxxxxxxxxxxxxxxxxxxxx
```

> **Note:** If using Create React App instead of Vite, prefix with `REACT_APP_` instead of `VITE_`.

**⚠️ Never commit `.env` files.** Add them to `.gitignore`. Use `.env.example` with placeholder values for documentation.

---

## 2. Backend Integration (Rails)

### Gem Setup

Add to `Gemfile`:

```ruby
gem 'stripe', '~> 12.0'   # Use latest major version
```

```bash
bundle install
```

### Initializer

Create `config/initializers/stripe.rb`:

```ruby
Stripe.api_key = ENV.fetch('STRIPE_SECRET_KEY')
Stripe.api_version = '2024-12-18.acacia'  # Pin API version for stability

# Optional but recommended: set up logging in development
if Rails.env.development?
  Stripe.log_level = Stripe::LEVEL_INFO
end
```

> **Why pin the API version?** Stripe releases API changes behind version headers. Pinning prevents your code from breaking when Stripe makes backward-incompatible changes. Update deliberately, not accidentally.

### Creating a Stripe Customer

Always create a Stripe customer and store the ID. This enables: saved payment methods, subscription management, payment history, and dispute handling.

```ruby
# app/models/user.rb (or a service object)
class User < ApplicationRecord
  # Assumes a `stripe_customer_id` column on users table
  
  def find_or_create_stripe_customer
    return stripe_customer_id if stripe_customer_id.present?

    customer = Stripe::Customer.create(
      email: email,
      name: full_name,
      metadata: {
        user_id: id,
        app: 'starter-app'
      }
    )

    update!(stripe_customer_id: customer.id)
    customer.id
  end
end
```

**Migration:**

```ruby
class AddStripeCustomerIdToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :stripe_customer_id, :string
    add_index :users, :stripe_customer_id, unique: true
  end
end
```

### Pattern 1: One-Time Payment (PaymentIntent)

This is the most common pattern. Use PaymentIntent for single charges.

**Controller:**

```ruby
# app/controllers/api/v1/payments_controller.rb
module Api
  module V1
    class PaymentsController < ApplicationController
      before_action :authenticate_user!

      # POST /api/v1/payments/create_intent
      def create_intent
        amount_cents = calculate_amount(params[:amount])

        # Ensure Stripe customer exists
        stripe_customer_id = current_user.find_or_create_stripe_customer

        payment_intent = Stripe::PaymentIntent.create(
          amount: amount_cents,             # Amount in CENTS (e.g., 1000 = $10.00)
          currency: 'usd',
          customer: stripe_customer_id,
          metadata: {
            user_id: current_user.id,
            order_id: params[:order_id]     # Link to your domain objects
          },
          automatic_payment_methods: {
            enabled: true                   # Enables Apple Pay, Google Pay, etc.
          }
        )

        render json: {
          client_secret: payment_intent.client_secret,
          payment_intent_id: payment_intent.id
        }
      rescue Stripe::StripeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def calculate_amount(amount_dollars)
        # Convert dollars to cents — Stripe works in smallest currency unit
        (amount_dollars.to_f * 100).round
      end
    end
  end
end
```

**⚠️ CRITICAL:** Stripe amounts are in **cents** (smallest currency unit). `$10.00` = `1000`. Always convert and round to avoid floating point issues.

### Pattern 2: Checkout Session (Stripe-Hosted Payment Page)

Use when you want Stripe to handle the entire payment UI. Less work, less control.

```ruby
# POST /api/v1/checkout/create_session
def create_session
  session = Stripe::Checkout::Session.create(
    customer: current_user.find_or_create_stripe_customer,
    payment_method_types: ['card'],
    line_items: [{
      price_data: {
        currency: 'usd',
        product_data: {
          name: params[:product_name],
          description: params[:description]
        },
        unit_amount: (params[:amount].to_f * 100).round
      },
      quantity: 1
    }],
    mode: 'payment',  # or 'subscription' for recurring
    success_url: "#{ENV['FRONTEND_URL']}/payment/success?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: "#{ENV['FRONTEND_URL']}/payment/cancel",
    metadata: {
      user_id: current_user.id,
      order_id: params[:order_id]
    }
  )

  render json: { url: session.url, session_id: session.id }
end
```

### Pattern 3: Subscriptions

```ruby
# Create a subscription
def create_subscription
  stripe_customer_id = current_user.find_or_create_stripe_customer

  subscription = Stripe::Subscription.create(
    customer: stripe_customer_id,
    items: [{ price: params[:price_id] }],  # Price ID from Stripe Dashboard
    payment_behavior: 'default_incomplete',
    payment_settings: {
      save_default_payment_method: 'on_subscription'
    },
    expand: ['latest_invoice.payment_intent']
  )

  render json: {
    subscription_id: subscription.id,
    client_secret: subscription.latest_invoice.payment_intent.client_secret,
    status: subscription.status
  }
end

# Cancel a subscription
def cancel_subscription
  subscription = Stripe::Subscription.update(
    params[:subscription_id],
    cancel_at_period_end: true  # Cancels at end of billing period (graceful)
  )

  render json: { status: subscription.status, cancel_at: subscription.cancel_at }
end
```

> **Tip:** Create Price objects in the Stripe Dashboard under Products. Use the `price_xxxxx` ID in your code. Don't hardcode amounts for subscriptions.

### Pattern 4: Refunds

```ruby
def create_refund
  refund = Stripe::Refund.create(
    payment_intent: params[:payment_intent_id],
    amount: params[:amount_cents],  # Partial refund; omit for full refund
    reason: 'requested_by_customer' # or 'duplicate', 'fraudulent'
  )

  render json: { refund_id: refund.id, status: refund.status }
rescue Stripe::StripeError => e
  render json: { error: e.message }, status: :unprocessable_entity
end
```

### Webhook Handling

Webhooks are **essential**. They're how Stripe tells you what happened (payment succeeded, failed, subscription changed, etc.). Never rely solely on frontend confirmation.

**Controller:**

```ruby
# app/controllers/api/v1/webhooks/stripe_controller.rb
module Api
  module V1
    module Webhooks
      class StripeController < ApplicationController
        # Skip CSRF and auth — Stripe calls this endpoint directly
        skip_before_action :verify_authenticity_token
        skip_before_action :authenticate_user!, if: -> { defined?(authenticate_user!) }

        # POST /api/v1/webhooks/stripe
        def create
          payload = request.body.read
          sig_header = request.env['HTTP_STRIPE_SIGNATURE']

          begin
            event = Stripe::Webhook.construct_event(
              payload,
              sig_header,
              ENV.fetch('STRIPE_WEBHOOK_SECRET')
            )
          rescue JSON::ParserError
            render json: { error: 'Invalid payload' }, status: :bad_request
            return
          rescue Stripe::SignatureVerificationError
            render json: { error: 'Invalid signature' }, status: :bad_request
            return
          end

          # Handle the event
          case event.type
          when 'payment_intent.succeeded'
            handle_payment_success(event.data.object)
          when 'payment_intent.payment_failed'
            handle_payment_failure(event.data.object)
          when 'customer.subscription.created'
            handle_subscription_created(event.data.object)
          when 'customer.subscription.updated'
            handle_subscription_updated(event.data.object)
          when 'customer.subscription.deleted'
            handle_subscription_deleted(event.data.object)
          when 'invoice.payment_succeeded'
            handle_invoice_paid(event.data.object)
          when 'invoice.payment_failed'
            handle_invoice_payment_failed(event.data.object)
          when 'charge.refunded'
            handle_refund(event.data.object)
          else
            Rails.logger.info("Unhandled Stripe event: #{event.type}")
          end

          # Always return 200 — otherwise Stripe retries (up to ~3 days)
          render json: { received: true }, status: :ok
        end

        private

        def handle_payment_success(payment_intent)
          # Find your order/payment record using metadata
          order = Order.find_by(id: payment_intent.metadata['order_id'])
          return unless order

          order.update!(
            status: 'paid',
            stripe_payment_intent_id: payment_intent.id,
            paid_at: Time.current
          )

          # Send confirmation email, update inventory, etc.
          OrderMailer.payment_confirmation(order).deliver_later
        end

        def handle_payment_failure(payment_intent)
          order = Order.find_by(id: payment_intent.metadata['order_id'])
          return unless order

          order.update!(status: 'payment_failed')
          # Notify user, retry logic, etc.
        end

        def handle_subscription_created(subscription)
          user = User.find_by(stripe_customer_id: subscription.customer)
          return unless user

          user.update!(
            subscription_status: subscription.status,
            stripe_subscription_id: subscription.id,
            subscription_plan: subscription.items.data.first.price.id
          )
        end

        def handle_subscription_updated(subscription)
          user = User.find_by(stripe_customer_id: subscription.customer)
          return unless user

          user.update!(
            subscription_status: subscription.status,
            subscription_plan: subscription.items.data.first.price.id
          )
        end

        def handle_subscription_deleted(subscription)
          user = User.find_by(stripe_customer_id: subscription.customer)
          return unless user

          user.update!(
            subscription_status: 'canceled',
            stripe_subscription_id: nil
          )
        end

        def handle_invoice_paid(invoice)
          # Record successful recurring payment
          Rails.logger.info("Invoice #{invoice.id} paid for customer #{invoice.customer}")
        end

        def handle_invoice_payment_failed(invoice)
          # Alert user, dunning logic
          user = User.find_by(stripe_customer_id: invoice.customer)
          return unless user

          # Send "update your payment method" email
          SubscriptionMailer.payment_failed(user).deliver_later
        end

        def handle_refund(charge)
          Rails.logger.info("Charge #{charge.id} refunded: #{charge.amount_refunded} cents")
          # Update your records
        end
      end
    end
  end
end
```

**Route:**

```ruby
# config/routes.rb
namespace :api do
  namespace :v1 do
    namespace :webhooks do
      post 'stripe', to: 'stripe#create'
    end
  end
end
```

### Local Webhook Testing with Stripe CLI

```bash
# Install Stripe CLI
# macOS:
brew install stripe/stripe-cli/stripe

# Login (one-time)
stripe login

# Forward webhooks to your local Rails server
stripe listen --forward-to localhost:3000/api/v1/webhooks/stripe

# This prints a webhook signing secret (whsec_...) — use it as STRIPE_WEBHOOK_SECRET
# ⚠️ This secret changes every time you run `stripe listen`
```

> **Tip:** In a second terminal, you can trigger test events:
> ```bash
> stripe trigger payment_intent.succeeded
> stripe trigger customer.subscription.created
> ```

---

## 3. Frontend Integration (React/TypeScript)

### Package Installation

```bash
npm install @stripe/stripe-js @stripe/react-stripe-js
```

### Loading Stripe.js

Create a shared Stripe instance. **Load it once, at the top level.**

```typescript
// src/lib/stripe.ts
import { loadStripe } from '@stripe/stripe-js';

// loadStripe is async but caches — safe to call at module level
export const stripePromise = loadStripe(
  import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY
);
```

> **⚠️ `loadStripe` must be called outside of a component render** to avoid recreating the Stripe object on every render.

### PaymentElement vs CardElement

| Feature | PaymentElement ✅ | CardElement |
|---------|-------------------|-------------|
| Payment methods | Cards, Apple Pay, Google Pay, bank transfers, etc. | Cards only |
| Maintenance | Stripe auto-adds new methods | You maintain each one |
| PCI compliance | Simplest | Slightly more work |
| Customization | Theme-based | More granular |
| **Recommendation** | **Use this** | Legacy / special cases only |

**Always use PaymentElement** unless you have a specific reason not to.

### Payment Flow Component

```tsx
// src/components/payments/CheckoutForm.tsx
import { useState } from 'react';
import {
  PaymentElement,
  useStripe,
  useElements,
} from '@stripe/react-stripe-js';

interface CheckoutFormProps {
  onSuccess?: (paymentIntentId: string) => void;
  onError?: (error: string) => void;
}

export function CheckoutForm({ onSuccess, onError }: CheckoutFormProps) {
  const stripe = useStripe();
  const elements = useElements();
  const [isProcessing, setIsProcessing] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!stripe || !elements) {
      // Stripe.js hasn't loaded yet — don't allow submission
      return;
    }

    setIsProcessing(true);
    setErrorMessage(null);

    const { error, paymentIntent } = await stripe.confirmPayment({
      elements,
      confirmParams: {
        return_url: `${window.location.origin}/payment/success`,
      },
      // Use redirect: 'if_required' to handle payment inline when possible
      // (avoids redirect for simple card payments)
      redirect: 'if_required',
    });

    if (error) {
      // Show error to customer (e.g., insufficient funds, card declined)
      setErrorMessage(error.message ?? 'An unexpected error occurred.');
      onError?.(error.message ?? 'Payment failed');
      setIsProcessing(false);
    } else if (paymentIntent && paymentIntent.status === 'succeeded') {
      // Payment succeeded without redirect
      onSuccess?.(paymentIntent.id);
      setIsProcessing(false);
    }
    // If redirect happened, user lands on return_url — handle there
  };

  return (
    <form onSubmit={handleSubmit}>
      <PaymentElement
        options={{
          layout: 'tabs', // or 'accordion'
        }}
      />

      {errorMessage && (
        <div className="mt-3 rounded-md bg-red-50 p-3 text-sm text-red-700">
          {errorMessage}
        </div>
      )}

      <button
        type="submit"
        disabled={!stripe || isProcessing}
        className="mt-4 w-full rounded-md bg-blue-600 px-4 py-2 text-white font-medium
                   hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
      >
        {isProcessing ? 'Processing...' : 'Pay Now'}
      </button>
    </form>
  );
}
```

### Payment Page (Parent Component)

```tsx
// src/pages/PaymentPage.tsx
import { useState, useEffect } from 'react';
import { Elements } from '@stripe/react-stripe-js';
import { stripePromise } from '../lib/stripe';
import { CheckoutForm } from '../components/payments/CheckoutForm';
import { api } from '../lib/api'; // Your API client

export function PaymentPage() {
  const [clientSecret, setClientSecret] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // Create PaymentIntent on mount
    const createPaymentIntent = async () => {
      try {
        const response = await api.post('/api/v1/payments/create_intent', {
          amount: 29.99,  // dollars — backend converts to cents
          order_id: 'order_123',
        });
        setClientSecret(response.data.client_secret);
      } catch (err: any) {
        setError(err.response?.data?.error || 'Failed to initialize payment');
      } finally {
        setLoading(false);
      }
    };

    createPaymentIntent();
  }, []);

  if (loading) return <div>Loading payment form...</div>;
  if (error) return <div className="text-red-600">Error: {error}</div>;
  if (!clientSecret) return <div>Unable to load payment</div>;

  return (
    <div className="mx-auto max-w-md p-6">
      <h2 className="mb-4 text-xl font-bold">Complete Payment</h2>

      <Elements
        stripe={stripePromise}
        options={{
          clientSecret,
          appearance: {
            theme: 'stripe',   // or 'night', 'flat', or custom
            variables: {
              colorPrimary: '#2563eb',
              borderRadius: '8px',
            },
          },
        }}
      >
        <CheckoutForm
          onSuccess={(id) => {
            // Navigate to success page or show confirmation
            console.log('Payment succeeded:', id);
          }}
          onError={(msg) => {
            console.error('Payment failed:', msg);
          }}
        />
      </Elements>
    </div>
  );
}
```

### Handling the Return URL (After Redirect)

Some payment methods (3D Secure, bank redirects) redirect the user. Handle the return:

```tsx
// src/pages/PaymentSuccessPage.tsx
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { stripePromise } from '../lib/stripe';

export function PaymentSuccessPage() {
  const [searchParams] = useSearchParams();
  const [status, setStatus] = useState<'loading' | 'success' | 'failed'>('loading');

  useEffect(() => {
    const checkPayment = async () => {
      const clientSecret = searchParams.get('payment_intent_client_secret');
      if (!clientSecret) {
        setStatus('failed');
        return;
      }

      const stripe = await stripePromise;
      if (!stripe) {
        setStatus('failed');
        return;
      }

      const { paymentIntent } = await stripe.retrievePaymentIntent(clientSecret);
      
      if (paymentIntent?.status === 'succeeded') {
        setStatus('success');
      } else {
        setStatus('failed');
      }
    };

    checkPayment();
  }, [searchParams]);

  if (status === 'loading') return <div>Verifying payment...</div>;
  if (status === 'failed') return <div>Payment could not be verified.</div>;

  return (
    <div className="text-center">
      <h1 className="text-2xl font-bold text-green-600">Payment Successful! ✅</h1>
      <p>Thank you for your payment.</p>
    </div>
  );
}
```

### Error Handling UX Best Practices

```typescript
// Common Stripe error codes and user-friendly messages
const STRIPE_ERROR_MESSAGES: Record<string, string> = {
  'card_declined':            'Your card was declined. Please try a different card.',
  'expired_card':             'Your card has expired. Please use a different card.',
  'incorrect_cvc':            'The CVC number is incorrect. Please check and try again.',
  'insufficient_funds':       'Insufficient funds. Please try a different card.',
  'processing_error':         'A processing error occurred. Please try again.',
  'incorrect_number':         'The card number is incorrect. Please check and try again.',
  'authentication_required':  'Authentication is required. Please complete verification.',
};

function getErrorMessage(error: any): string {
  if (error.decline_code && STRIPE_ERROR_MESSAGES[error.decline_code]) {
    return STRIPE_ERROR_MESSAGES[error.decline_code];
  }
  if (error.code && STRIPE_ERROR_MESSAGES[error.code]) {
    return STRIPE_ERROR_MESSAGES[error.code];
  }
  return error.message || 'An unexpected error occurred. Please try again.';
}
```

---

## 4. Testing

### Test Card Numbers

| Card Number | Scenario |
|------------|----------|
| `4242 4242 4242 4242` | ✅ Succeeds |
| `4000 0000 0000 3220` | Requires 3D Secure authentication |
| `4000 0000 0000 9995` | ❌ Declined: insufficient funds |
| `4000 0000 0000 0002` | ❌ Declined: generic decline |
| `4000 0000 0000 0069` | ❌ Declined: expired card |
| `4000 0000 0000 0127` | ❌ Declined: incorrect CVC |
| `4000 0025 0000 3155` | Requires authentication (SCA) |

**For all test cards:**
- Expiry: Any future date (e.g., `12/34`)
- CVC: Any 3 digits (e.g., `123`)
- ZIP: Any 5 digits (e.g., `12345`)

Full list: [https://docs.stripe.com/testing#cards](https://docs.stripe.com/testing#cards)

### Stripe CLI Commands for Testing

```bash
# Forward webhooks to local server
stripe listen --forward-to localhost:3000/api/v1/webhooks/stripe

# Trigger specific events
stripe trigger payment_intent.succeeded
stripe trigger payment_intent.payment_failed
stripe trigger customer.subscription.created
stripe trigger invoice.payment_succeeded
stripe trigger charge.refunded

# View recent events
stripe events list --limit 10

# View logs
stripe logs tail
```

### Test Mode Dashboard

- **Payments:** [https://dashboard.stripe.com/test/payments](https://dashboard.stripe.com/test/payments)
- **Customers:** [https://dashboard.stripe.com/test/customers](https://dashboard.stripe.com/test/customers)
- **Webhooks:** [https://dashboard.stripe.com/test/webhooks](https://dashboard.stripe.com/test/webhooks)
- **Events:** [https://dashboard.stripe.com/test/events](https://dashboard.stripe.com/test/events)
- **Logs:** [https://dashboard.stripe.com/test/logs](https://dashboard.stripe.com/test/logs)

Use the dashboard to inspect every payment, see webhook deliveries, and debug issues.

### RSpec Tests (Rails)

```ruby
# spec/requests/api/v1/payments_controller_spec.rb
require 'rails_helper'

RSpec.describe 'Api::V1::PaymentsController', type: :request do
  let(:user) { create(:user) }
  let(:headers) { auth_headers_for(user) }

  describe 'POST /api/v1/payments/create_intent' do
    it 'creates a payment intent' do
      # Stripe test mode handles this — no mocking needed for integration tests
      post '/api/v1/payments/create_intent',
           params: { amount: 29.99, order_id: 'test_order_1' },
           headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['client_secret']).to start_with('pi_')
      expect(json['payment_intent_id']).to start_with('pi_')
    end
  end

  describe 'POST /api/v1/webhooks/stripe' do
    it 'handles payment_intent.succeeded' do
      # For webhook tests, use Stripe's test helpers or construct events manually
      payload = {
        type: 'payment_intent.succeeded',
        data: {
          object: {
            id: 'pi_test_123',
            metadata: { order_id: order.id.to_s, user_id: user.id.to_s }
          }
        }
      }.to_json

      # In test, you may need to skip signature verification or use
      # Stripe::Webhook.construct_event with a test signing secret
      post '/api/v1/webhooks/stripe',
           params: payload,
           headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
    end
  end
end
```

---

## 5. Going to Production Checklist

### Before Launch

- [ ] **Activate Stripe account** — Complete business verification in Dashboard
- [ ] **Switch API keys** — Replace `pk_test_`/`sk_test_` with `pk_live_`/`sk_live_` in production environment
- [ ] **Set production webhook endpoint** — Dashboard → Webhooks → Add endpoint → Your production URL (e.g., `https://api.yourapp.com/api/v1/webhooks/stripe`)
- [ ] **Select webhook events** — Only subscribe to events you handle (don't select all)
- [ ] **Update `STRIPE_WEBHOOK_SECRET`** — Use the signing secret from the production webhook endpoint (different from test/CLI)
- [ ] **Verify SSL** — Your webhook endpoint MUST use HTTPS. Stripe rejects HTTP in live mode
- [ ] **Remove test data references** — No `test_` anything in production config
- [ ] **Enable fraud protection** — Stripe Radar is on by default, but review settings

### After Launch

- [ ] **Make a real test payment** — Use a real card, charge a small amount ($0.50), then refund it
- [ ] **Verify webhook delivery** — Check Dashboard → Webhooks → the endpoint → Recent deliveries. All should show 200
- [ ] **Set up monitoring** — Alert on webhook failures, high decline rates
- [ ] **Review Stripe Radar rules** — Adjust fraud rules for your use case

### Common Gotchas

1. **Webhook secret mismatch** — The `whsec_` secret from `stripe listen` (CLI) is NOT the same as the dashboard webhook endpoint secret. Production uses the dashboard one.

2. **Forgotten webhook events** — If you add a new event handler in code, you must also add that event type in the Stripe Dashboard webhook settings. Otherwise Stripe never sends it.

3. **Double-processing webhooks** — Stripe may retry webhooks. Make your handlers **idempotent**. Check if you've already processed a payment before acting on it.

4. **Amount in cents** — A bug that ships to production: displaying `$2999` instead of `$29.99` because you forgot to divide by 100.

5. **Test cards in production** — `4242...` doesn't work in live mode. If your tests pass but production fails, check your keys.

6. **CORS issues** — The frontend calls Stripe.js directly (it's loaded from `js.stripe.com`). Your backend creates the PaymentIntent but the frontend confirms it. Make sure CORS allows your frontend origin on the Rails API.

7. **3D Secure / SCA** — European cards often require authentication. If you only test with `4242...`, you'll miss this. Test with `4000 0025 0000 3155` to simulate required authentication.

---

## 6. Fee Handling (Passing Stripe Fees to Customer)

### Stripe's Standard Pricing

Stripe charges: **2.9% + $0.30 per transaction** (US cards; international cards are higher).

If you want the customer to cover the Stripe fees so you receive the exact intended amount, you need to calculate the total charge that, after Stripe takes its cut, leaves you with the original amount.

### The Formula

To receive exactly `$X` after fees:

```
charge_amount = (X + 0.30) / (1 - 0.029)
```

**Example:** You want to receive $100.00:

```
charge_amount = (100.00 + 0.30) / (1 - 0.029)
              = 100.30 / 0.971
              = $103.30 (rounded to nearest cent)
```

Stripe takes 2.9% + $0.30: `103.30 × 0.029 + 0.30 = $2.996 + $0.30 = $3.30`  
You receive: `$103.30 - $3.30 = $100.00` ✅

### Implementation

**Backend helper:**

```ruby
# app/services/stripe_fee_calculator.rb
class StripeFeeCalculator
  # Standard US card pricing
  PERCENTAGE_FEE = 0.029   # 2.9%
  FIXED_FEE = 0.30         # $0.30

  # International cards (uncomment if needed)
  # PERCENTAGE_FEE = 0.039  # 3.9%

  def self.calculate_total_with_fee(desired_amount)
    # desired_amount is in dollars (what you want to receive)
    total = (desired_amount + FIXED_FEE) / (1 - PERCENTAGE_FEE)
    total.round(2)
  end

  def self.calculate_fee(desired_amount)
    total = calculate_total_with_fee(desired_amount)
    fee = total - desired_amount
    fee.round(2)
  end

  def self.breakdown(desired_amount)
    total = calculate_total_with_fee(desired_amount)
    fee = (total - desired_amount).round(2)
    stripe_cut = (total * PERCENTAGE_FEE + FIXED_FEE).round(2)

    {
      subtotal: desired_amount,
      processing_fee: fee,
      total_charge: total,
      stripe_takes: stripe_cut,
      you_receive: (total - stripe_cut).round(2)
    }
  end
end
```

**Usage in controller:**

```ruby
def create_intent
  subtotal = params[:amount].to_f  # e.g., 100.00

  if params[:pass_fees_to_customer]
    total = StripeFeeCalculator.calculate_total_with_fee(subtotal)
    fee = StripeFeeCalculator.calculate_fee(subtotal)
  else
    total = subtotal
    fee = 0
  end

  payment_intent = Stripe::PaymentIntent.create(
    amount: (total * 100).round,  # Convert to cents
    currency: 'usd',
    customer: current_user.find_or_create_stripe_customer,
    metadata: {
      subtotal_cents: (subtotal * 100).round,
      fee_cents: (fee * 100).round,
      fees_passed_to_customer: params[:pass_fees_to_customer].to_s
    }
  )

  render json: {
    client_secret: payment_intent.client_secret,
    subtotal: subtotal,
    processing_fee: fee,
    total: total
  }
end
```

**Frontend display:**

```tsx
// Show the fee breakdown to the customer before they pay
interface FeeBreakdown {
  subtotal: number;
  processing_fee: number;
  total: number;
}

function OrderSummary({ breakdown }: { breakdown: FeeBreakdown }) {
  return (
    <div className="space-y-2 border-t pt-4">
      <div className="flex justify-between">
        <span>Subtotal</span>
        <span>${breakdown.subtotal.toFixed(2)}</span>
      </div>
      {breakdown.processing_fee > 0 && (
        <div className="flex justify-between text-sm text-gray-500">
          <span>Processing fee</span>
          <span>${breakdown.processing_fee.toFixed(2)}</span>
        </div>
      )}
      <div className="flex justify-between font-bold border-t pt-2">
        <span>Total</span>
        <span>${breakdown.total.toFixed(2)}</span>
      </div>
    </div>
  );
}
```

### Important Notes on Fee Passing

1. **Transparency** — Always show the fee as a separate line item. Don't hide it in the total. Customers should see exactly what they're paying and why.

2. **Legal considerations** — Some jurisdictions restrict or prohibit surcharging card payments. Check local regulations. In the US, most states allow it with proper disclosure.

3. **Labeling** — Call it "processing fee" or "payment processing fee" — not "Stripe fee" or "credit card fee." Stripe's terms discourage naming them directly.

4. **Rounding** — Always round to 2 decimal places at the final step. Don't accumulate rounding errors across intermediate calculations.

5. **International cards** — If you serve international customers, Stripe charges 3.9% + $0.30 (not 2.9%). You may want to detect this or use an average rate.

---

## Quick Reference: Common Stripe API Calls

```ruby
# Create customer
Stripe::Customer.create(email: 'user@example.com', name: 'John Doe')

# Create PaymentIntent
Stripe::PaymentIntent.create(amount: 1000, currency: 'usd', customer: 'cus_xxx')

# Retrieve PaymentIntent
Stripe::PaymentIntent.retrieve('pi_xxx')

# Create Checkout Session
Stripe::Checkout::Session.create(mode: 'payment', ...)

# Create Subscription
Stripe::Subscription.create(customer: 'cus_xxx', items: [{ price: 'price_xxx' }])

# Cancel Subscription
Stripe::Subscription.update('sub_xxx', cancel_at_period_end: true)

# Full Refund
Stripe::Refund.create(payment_intent: 'pi_xxx')

# Partial Refund
Stripe::Refund.create(payment_intent: 'pi_xxx', amount: 500)

# List customer's payment methods
Stripe::PaymentMethod.list(customer: 'cus_xxx', type: 'card')

# Create webhook endpoint (programmatically)
Stripe::WebhookEndpoint.create(
  url: 'https://api.yourapp.com/api/v1/webhooks/stripe',
  enabled_events: ['payment_intent.succeeded', 'payment_intent.payment_failed']
)
```

---

## File Structure Reference

After integration, your project should have these Stripe-related files:

```
backend/
├── Gemfile                                    # + gem 'stripe'
├── config/
│   └── initializers/
│       └── stripe.rb                          # Stripe configuration
├── app/
│   ├── controllers/
│   │   └── api/v1/
│   │       ├── payments_controller.rb         # PaymentIntent creation
│   │       └── webhooks/
│   │           └── stripe_controller.rb       # Webhook handler
│   ├── models/
│   │   └── user.rb                            # + stripe_customer_id methods
│   └── services/
│       └── stripe_fee_calculator.rb           # Fee calculation logic
├── db/migrate/
│   └── xxx_add_stripe_customer_id_to_users.rb # Migration
└── .env                                       # STRIPE_SECRET_KEY, etc.

frontend/
├── src/
│   ├── lib/
│   │   └── stripe.ts                          # loadStripe singleton
│   ├── components/
│   │   └── payments/
│   │       └── CheckoutForm.tsx               # PaymentElement form
│   └── pages/
│       ├── PaymentPage.tsx                     # Elements provider + form
│       └── PaymentSuccessPage.tsx              # Return URL handler
└── .env                                       # VITE_STRIPE_PUBLISHABLE_KEY
```

---

## Resources

- [Stripe Docs](https://docs.stripe.com/)
- [Stripe API Reference](https://docs.stripe.com/api)
- [Stripe Testing Guide](https://docs.stripe.com/testing)
- [Stripe CLI](https://docs.stripe.com/stripe-cli)
- [PaymentElement Guide](https://docs.stripe.com/payments/payment-element)
- [Stripe Ruby Gem](https://github.com/stripe/stripe-ruby)
- [Stripe React Components](https://github.com/stripe/react-stripe-js)
