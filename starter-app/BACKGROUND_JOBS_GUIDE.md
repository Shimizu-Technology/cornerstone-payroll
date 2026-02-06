# Background Jobs Guide (GoodJob + Sidekiq)

A comprehensive guide for asynchronous processing in Rails + React apps. Covers GoodJob (preferred), Sidekiq (alternative), job patterns, scheduling, error handling, and production deployment.

---

## Table of Contents
1. [Overview](#1-overview)
2. [GoodJob Setup (Preferred)](#2-goodjob-setup-preferred)
3. [Sidekiq Setup (Alternative)](#3-sidekiq-setup-alternative)
4. [Job Creation Patterns](#4-job-creation-patterns)
5. [Scheduling Recurring Jobs](#5-scheduling-recurring-jobs)
6. [Error Handling and Retries](#6-error-handling-and-retries)
7. [Dashboard and Monitoring](#7-dashboard-and-monitoring)
8. [Testing Jobs in RSpec](#8-testing-jobs-in-rspec)
9. [Frontend: Job Progress](#9-frontend-job-progress)
10. [Production Configuration](#10-production-configuration)
11. [Choosing GoodJob vs Sidekiq](#11-choosing-goodjob-vs-sidekiq)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Overview

### Why Background Jobs?

Background jobs move slow or non-critical work out of the request/response cycle. Users get fast responses while heavy work happens asynchronously.

```
┌──────────┐    POST /orders     ┌──────────┐
│  React   │ ──────────────────▶ │  Rails   │
│  Client  │ ◀────────────────── │  API     │
└──────────┘    201 Created      └─────┬────┘
                (instant!)             │
                                       │ enqueue
                                       ▼
                                ┌──────────────┐
                                │  Job Queue   │
                                │  (GoodJob /  │
                                │   Sidekiq)   │
                                └──────┬───────┘
                                       │ async
                          ┌────────────┼────────────┐
                          ▼            ▼            ▼
                   Send Email    Generate PDF    Notify Admin
```

### When to Use Background Jobs

| Task | Background Job? | Why |
|------|----------------|-----|
| Sending emails | ✅ Always | SMTP is slow (1-5 seconds) |
| PDF generation | ✅ Always | CPU-intensive |
| Image processing | ✅ Always | Can take 10+ seconds |
| Data imports (CSV) | ✅ Always | Can take minutes |
| Webhook delivery | ✅ Always | External service may be slow |
| Database cleanup | ✅ Always | Don't slow down requests |
| Simple DB query | ❌ No | Fast enough inline |
| Cache warming | ✅ Yes | Don't delay response |
| Third-party API calls | ✅ Usually | Unpredictable latency |

### The Shimizu Way

> **Use GoodJob unless you have a reason not to.** It uses PostgreSQL — which you already have — so there's zero additional infrastructure. Sidekiq requires Redis, which adds cost and complexity. Only reach for Sidekiq when you need Redis for other things (ActionCable, caching) or need extreme throughput.

---

## 2. GoodJob Setup (Preferred)

### 2.1 Install GoodJob

```ruby
# Gemfile
gem 'good_job', '~> 4.0'
```

```bash
bundle install
```

### 2.2 Run the Installer

```bash
rails generate good_job:install
rails db:migrate
```

This creates a migration for the `good_jobs` table in PostgreSQL.

### 2.3 Configure Active Job

```ruby
# config/application.rb
class Application < Rails::Application
  config.active_job.queue_adapter = :good_job
end
```

### 2.4 Configure GoodJob

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job = {
    # Execution mode:
    # :async — runs jobs in the web process (good for small apps)
    # :external — runs jobs in a separate process (production)
    # :async_server — like :async but only when Rails server is running
    execution_mode: Rails.env.production? ? :external : :async_server,

    # Maximum threads for job execution
    max_threads: ENV.fetch('GOOD_JOB_MAX_THREADS', 5).to_i,

    # Poll interval for checking new jobs (seconds)
    poll_interval: ENV.fetch('GOOD_JOB_POLL_INTERVAL', 5).to_i,

    # Queue priority (higher priority queues are processed first)
    queues: 'critical:5;default:3;low:1',

    # Cleanup old finished jobs
    cleanup_preserved_jobs_before_seconds_ago: 7.days.to_i,

    # Enable cron (scheduled jobs)
    enable_cron: true,

    # Dashboard
    smaller_number_is_higher_priority: true,
  }
end
```

### 2.5 Mount the Dashboard

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # GoodJob dashboard (admin only!)
  authenticate :user, ->(user) { user.admin? } do
    mount GoodJob::Engine => '/good_job'
  end

  # If not using Devise, use basic auth:
  mount GoodJob::Engine => '/good_job'
  # And add authentication in the initializer (see Section 7)
end
```

---

## 3. Sidekiq Setup (Alternative)

### 3.1 When to Use Sidekiq

Use Sidekiq instead of GoodJob when:
- You already have Redis (for ActionCable, caching)
- You need to process thousands of jobs per second
- You want the mature Sidekiq Pro/Enterprise features
- You need real-time job processing (Sidekiq uses push, GoodJob polls)

### 3.2 Install Sidekiq

```ruby
# Gemfile
gem 'sidekiq', '~> 7.0'
```

```bash
bundle install
```

### 3.3 Configure Active Job

```ruby
# config/application.rb
class Application < Rails::Application
  config.active_job.queue_adapter = :sidekiq
end
```

### 3.4 Configure Sidekiq

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
end
```

### 3.5 Queue Configuration

```yaml
# config/sidekiq.yml
:concurrency: 5
:queues:
  - [critical, 5]
  - [default, 3]
  - [low, 1]
  - [mailers, 2]
```

### 3.6 Start Sidekiq

```bash
# Development
bundle exec sidekiq

# Or use Procfile
# Procfile.dev
web: bin/rails server -p 3000
worker: bundle exec sidekiq -C config/sidekiq.yml
```

### 3.7 Mount Sidekiq Dashboard

```ruby
# config/routes.rb
require 'sidekiq/web'

Rails.application.routes.draw do
  authenticate :user, ->(user) { user.admin? } do
    mount Sidekiq::Web => '/sidekiq'
  end
end
```

---

## 4. Job Creation Patterns

### 4.1 Basic Job Structure

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  # Retry failed jobs (default behavior)
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # Discard jobs that can't be fixed by retrying
  discard_on ActiveJob::DeserializationError
  discard_on ActiveRecord::RecordNotFound

  # Log job execution
  around_perform do |_job, block|
    Rails.logger.info("Starting job: #{self.class.name}")
    start_time = Time.current
    block.call
    elapsed = Time.current - start_time
    Rails.logger.info("Finished job: #{self.class.name} in #{elapsed.round(2)}s")
  end
end
```

### 4.2 Email Jobs

```ruby
# Use Rails built-in deliver_later — no custom job needed!

# app/controllers/api/v1/orders_controller.rb
class Api::V1::OrdersController < ApplicationController
  def create
    @order = Order.create!(order_params.merge(user: current_user))

    # This automatically enqueues a job
    OrderConfirmationMailer.confirmation(@order).deliver_later

    # For priority emails, use a specific queue
    OrderConfirmationMailer.confirmation(@order).deliver_later(queue: :critical)

    render json: @order, status: :created
  end
end
```

### 4.3 Report Generation Job

```ruby
# app/jobs/generate_report_job.rb
class GenerateReportJob < ApplicationJob
  queue_as :default

  def perform(user_id, report_type, params = {})
    user = User.find(user_id)

    report = case report_type
             when 'sales'
               SalesReport.generate(
                 start_date: params['start_date'],
                 end_date: params['end_date'],
                 restaurant_id: params['restaurant_id']
               )
             when 'inventory'
               InventoryReport.generate(restaurant_id: params['restaurant_id'])
             else
               raise ArgumentError, "Unknown report type: #{report_type}"
             end

    # Attach the report as a file
    report_file = report.to_pdf
    user.reports.attach(
      io: StringIO.new(report_file),
      filename: "#{report_type}_report_#{Date.current}.pdf",
      content_type: 'application/pdf'
    )

    # Notify the user
    ReportMailer.ready(user, report_type).deliver_later
    NotificationChannel.broadcast_to(user, {
      type: 'report_ready',
      data: { report_type: report_type, download_url: report.download_url }
    })
  end
end
```

### 4.4 Data Import Job

```ruby
# app/jobs/csv_import_job.rb
class CsvImportJob < ApplicationJob
  queue_as :default

  # Don't retry imports — they could create duplicates
  retry_on StandardError, attempts: 0

  def perform(import_id)
    import = Import.find(import_id)
    import.update!(status: 'processing')

    file = import.file.download
    rows = CSV.parse(file, headers: true)
    total = rows.count
    processed = 0
    errors = []

    rows.each_with_index do |row, index|
      begin
        process_row(row, import)
        processed += 1
      rescue StandardError => e
        errors << { row: index + 2, error: e.message }  # +2 for header + 0-index
      end

      # Update progress every 100 rows
      if (processed % 100).zero?
        import.update!(
          progress: ((processed.to_f / total) * 100).round,
          processed_count: processed
        )
      end
    end

    import.update!(
      status: errors.empty? ? 'completed' : 'completed_with_errors',
      progress: 100,
      processed_count: processed,
      error_count: errors.count,
      error_details: errors
    )

    NotificationChannel.broadcast_to(import.user, {
      type: 'import_complete',
      data: { import_id: import.id, status: import.status }
    })
  end

  private

  def process_row(row, import)
    MenuItem.create!(
      restaurant_id: import.restaurant_id,
      name: row['name'],
      price: row['price'].to_f,
      category: row['category'],
      description: row['description']
    )
  end
end
```

### 4.5 Cleanup Job

```ruby
# app/jobs/cleanup_job.rb
class CleanupJob < ApplicationJob
  queue_as :low

  def perform(task = 'all')
    case task
    when 'all'
      clean_expired_sessions
      clean_old_notifications
      clean_abandoned_carts
    when 'sessions'
      clean_expired_sessions
    when 'notifications'
      clean_old_notifications
    when 'carts'
      clean_abandoned_carts
    end
  end

  private

  def clean_expired_sessions
    count = Session.where('expires_at < ?', Time.current).delete_all
    Rails.logger.info("Cleaned #{count} expired sessions")
  end

  def clean_old_notifications
    count = Notification.where('created_at < ?', 30.days.ago).delete_all
    Rails.logger.info("Cleaned #{count} old notifications")
  end

  def clean_abandoned_carts
    count = Cart.where('updated_at < ?', 7.days.ago)
                .where(status: 'active')
                .update_all(status: 'abandoned')
    Rails.logger.info("Marked #{count} carts as abandoned")
  end
end
```

### 4.6 Webhook Delivery Job

```ruby
# app/jobs/webhook_delivery_job.rb
class WebhookDeliveryJob < ApplicationJob
  queue_as :critical

  # Retry with exponential backoff
  retry_on Net::ReadTimeout, wait: :polynomially_longer, attempts: 5
  retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 5
  retry_on Faraday::ConnectionFailed, wait: :polynomially_longer, attempts: 5

  def perform(webhook_id, event_type, payload)
    webhook = Webhook.find(webhook_id)

    response = Faraday.post(webhook.url) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['X-Webhook-Signature'] = sign_payload(payload, webhook.secret)
      req.body = payload.to_json
      req.options.timeout = 10
    end

    WebhookDelivery.create!(
      webhook: webhook,
      event_type: event_type,
      payload: payload,
      response_code: response.status,
      response_body: response.body.truncate(1000),
      delivered_at: Time.current
    )
  end

  private

  def sign_payload(payload, secret)
    OpenSSL::HMAC.hexdigest('sha256', secret, payload.to_json)
  end
end
```

---

## 5. Scheduling Recurring Jobs

### 5.1 GoodJob Cron

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.cron = {
    # Run cleanup every night at 2 AM
    cleanup: {
      cron: '0 2 * * *',
      class: 'CleanupJob',
      description: 'Clean up expired sessions, old notifications, abandoned carts'
    },

    # Generate daily sales report at 6 AM
    daily_report: {
      cron: '0 6 * * *',
      class: 'DailySalesReportJob',
      description: 'Generate and email daily sales summary'
    },

    # Check for stale orders every 15 minutes
    stale_orders: {
      cron: '*/15 * * * *',
      class: 'StaleOrderCheckJob',
      description: 'Alert on orders stuck in processing'
    },

    # Weekly analytics rollup on Mondays at 3 AM
    weekly_analytics: {
      cron: '0 3 * * 1',
      class: 'WeeklyAnalyticsJob',
      description: 'Aggregate weekly analytics data'
    }
  }
end
```

### 5.2 Sidekiq Cron (with sidekiq-cron gem)

```ruby
# Gemfile
gem 'sidekiq-cron', '~> 2.0'
```

```ruby
# config/initializers/sidekiq_cron.rb
if Sidekiq.server?
  Sidekiq::Cron::Job.load_from_hash(
    'cleanup' => {
      'cron' => '0 2 * * *',
      'class' => 'CleanupJob',
      'queue' => 'low',
      'description' => 'Nightly cleanup'
    },
    'daily_report' => {
      'cron' => '0 6 * * *',
      'class' => 'DailySalesReportJob',
      'queue' => 'default'
    }
  )
end
```

### 5.3 Recurring Job Patterns

```ruby
# app/jobs/stale_order_check_job.rb
class StaleOrderCheckJob < ApplicationJob
  queue_as :critical

  def perform
    stale_orders = Order
      .where(status: 'processing')
      .where('updated_at < ?', 30.minutes.ago)

    return if stale_orders.empty?

    stale_orders.each do |order|
      # Alert admin
      AdminAlertMailer.stale_order(order).deliver_later

      # Broadcast to admin dashboard
      ActionCable.server.broadcast('admin_dashboard', {
        type: 'stale_order_alert',
        data: { order_id: order.id, minutes_stale: ((Time.current - order.updated_at) / 60).round }
      })
    end

    Rails.logger.warn("Found #{stale_orders.count} stale orders")
  end
end
```

---

## 6. Error Handling and Retries

### 6.1 Retry Strategies

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  # Default: retry with polynomial backoff (3s, 18s, 83s, 258s, 625s)
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # For transient errors, retry quickly
  retry_on Net::ReadTimeout, wait: 5.seconds, attempts: 3

  # For rate limiting, wait longer
  retry_on RateLimitError, wait: 1.minute, attempts: 10

  # Some errors should never be retried
  discard_on ActiveRecord::RecordNotFound
  discard_on ArgumentError
  discard_on ActiveJob::DeserializationError
end
```

### 6.2 Custom Error Handling

```ruby
# app/jobs/payment_processing_job.rb
class PaymentProcessingJob < ApplicationJob
  queue_as :critical

  # Custom retry logic
  retry_on Stripe::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on Stripe::APIConnectionError, wait: 10.seconds, attempts: 3

  # Don't retry card errors — they won't succeed on retry
  discard_on Stripe::CardError do |job, error|
    order = Order.find(job.arguments.first)
    order.update!(status: 'payment_failed', failure_reason: error.message)

    NotificationChannel.broadcast_to(order.user, {
      type: 'payment_failed',
      data: { order_id: order.id, reason: error.message }
    })
  end

  def perform(order_id)
    order = Order.find(order_id)
    payment = StripeService.charge(order)

    order.update!(
      status: 'paid',
      payment_intent_id: payment.id
    )
  end
end
```

### 6.3 Dead Letter Queue / Failure Callbacks

```ruby
# app/jobs/important_job.rb
class ImportantJob < ApplicationJob
  queue_as :default

  # After all retries exhausted
  retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
    # This block runs after ALL retries have failed
    ErrorReporter.report(error, context: {
      job_class: job.class.name,
      arguments: job.arguments,
      executions: job.executions
    })

    # Notify someone
    AdminAlertMailer.job_permanently_failed(
      job_class: job.class.name,
      error: error.message,
      arguments: job.arguments
    ).deliver_later(queue: :critical)
  end

  def perform(data)
    # ... job logic
  end
end
```

### 6.4 Idempotency

> **Critical:** Jobs may run more than once. Design every job to be **idempotent** — running it twice should produce the same result as running it once.

```ruby
# ❌ BAD — not idempotent (charges customer twice on retry)
class ChargeJob < ApplicationJob
  def perform(order_id)
    order = Order.find(order_id)
    Stripe::Charge.create(amount: order.total_cents, customer: order.stripe_customer_id)
    order.update!(paid: true)
  end
end

# ✅ GOOD — idempotent (checks before charging)
class ChargeJob < ApplicationJob
  def perform(order_id)
    order = Order.find(order_id)
    return if order.paid?  # Already processed

    # Use idempotency key to prevent duplicate charges
    Stripe::Charge.create(
      amount: order.total_cents,
      customer: order.stripe_customer_id,
      idempotency_key: "order_#{order.id}"
    )
    order.update!(paid: true)
  end
end
```

---

## 7. Dashboard and Monitoring

### 7.1 GoodJob Dashboard

GoodJob includes a built-in web dashboard:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # Simple authentication for the dashboard
  mount GoodJob::Engine => '/good_job'
end

# config/initializers/good_job.rb
# Require authentication for the dashboard
GoodJob::Engine.middleware.use(Rack::Auth::Basic) do |username, password|
  ActiveSupport::SecurityUtils.secure_compare(username, ENV.fetch('GOOD_JOB_USERNAME', 'admin')) &&
    ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch('GOOD_JOB_PASSWORD', 'password'))
end
```

The dashboard shows:
- Job queue status
- Running/scheduled/retried/discarded/finished jobs
- Cron job schedules
- Error details with full backtraces
- Performance metrics

### 7.2 Sidekiq Dashboard

Sidekiq's Web UI is legendary:

```ruby
# config/routes.rb
require 'sidekiq/web'

# Basic auth for production
if Rails.env.production?
  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(username, ENV['SIDEKIQ_USERNAME']) &&
      ActiveSupport::SecurityUtils.secure_compare(password, ENV['SIDEKIQ_PASSWORD'])
  end
end

mount Sidekiq::Web => '/sidekiq'
```

### 7.3 Custom Monitoring

```ruby
# app/services/job_monitor.rb
class JobMonitor
  def self.stats
    if defined?(GoodJob)
      {
        queued: GoodJob::Job.where(finished_at: nil, error: nil).count,
        running: GoodJob::Job.running.count,
        errored: GoodJob::Job.where.not(error: nil).where(finished_at: nil).count,
        finished_today: GoodJob::Job.where('finished_at > ?', Time.current.beginning_of_day).count
      }
    elsif defined?(Sidekiq)
      stats = Sidekiq::Stats.new
      {
        queued: stats.enqueued,
        running: stats.workers_size,
        errored: stats.failed,
        finished_today: stats.processed
      }
    end
  end
end
```

---

## 8. Testing Jobs in RSpec

### 8.1 Test Setup

```ruby
# spec/rails_helper.rb
RSpec.configure do |config|
  # Use test adapter for all tests by default
  config.before do
    ActiveJob::Base.queue_adapter = :test
  end
end
```

### 8.2 Test That Jobs Are Enqueued

```ruby
# spec/controllers/api/v1/orders_controller_spec.rb
RSpec.describe Api::V1::OrdersController, type: :request do
  describe 'POST /api/v1/orders' do
    let(:user) { create(:user) }
    let(:valid_params) { { items: [{ menu_item_id: 1, quantity: 2 }] } }

    it 'enqueues a confirmation email' do
      expect {
        post '/api/v1/orders', params: valid_params, headers: auth_headers(user)
      }.to have_enqueued_job(ActionMailer::MailDeliveryJob)
    end

    it 'enqueues the job on the correct queue' do
      expect {
        post '/api/v1/orders', params: valid_params, headers: auth_headers(user)
      }.to have_enqueued_job.on_queue('default')
    end

    it 'enqueues with correct arguments' do
      expect {
        post '/api/v1/orders', params: valid_params, headers: auth_headers(user)
      }.to have_enqueued_job(ActionMailer::MailDeliveryJob)
        .with('OrderConfirmationMailer', 'confirmation', 'deliver_now', anything)
    end
  end
end
```

### 8.3 Test Job Logic (perform)

```ruby
# spec/jobs/cleanup_job_spec.rb
RSpec.describe CleanupJob, type: :job do
  describe '#perform' do
    it 'deletes expired sessions' do
      expired = create(:session, expires_at: 1.hour.ago)
      active = create(:session, expires_at: 1.hour.from_now)

      described_class.perform_now('sessions')

      expect(Session.exists?(expired.id)).to be false
      expect(Session.exists?(active.id)).to be true
    end

    it 'marks old carts as abandoned' do
      old_cart = create(:cart, updated_at: 8.days.ago, status: 'active')
      recent_cart = create(:cart, updated_at: 1.day.ago, status: 'active')

      described_class.perform_now('carts')

      expect(old_cart.reload.status).to eq('abandoned')
      expect(recent_cart.reload.status).to eq('active')
    end
  end
end
```

### 8.4 Test Retry Behavior

```ruby
# spec/jobs/payment_processing_job_spec.rb
RSpec.describe PaymentProcessingJob, type: :job do
  let(:order) { create(:order, status: 'pending') }

  describe 'error handling' do
    it 'retries on API connection errors' do
      allow(StripeService).to receive(:charge).and_raise(Stripe::APIConnectionError)

      expect {
        described_class.perform_later(order.id)
      }.to have_enqueued_job(described_class).at_least(:once)
    end

    it 'discards on card errors and updates order' do
      allow(StripeService).to receive(:charge)
        .and_raise(Stripe::CardError.new('Card declined', nil, nil))

      perform_enqueued_jobs do
        described_class.perform_later(order.id)
      end

      expect(order.reload.status).to eq('payment_failed')
    end
  end
end
```

### 8.5 Test Scheduled Jobs

```ruby
# spec/jobs/generate_report_job_spec.rb
RSpec.describe GenerateReportJob, type: :job do
  it 'can be scheduled' do
    expect {
      described_class.set(wait: 1.hour).perform_later(1, 'sales')
    }.to have_enqueued_job.at(1.hour.from_now)
  end
end
```

### 8.6 Integration Test: Run Jobs Inline

```ruby
# When you want to test the full flow including job execution
RSpec.describe 'Order placement flow', type: :request do
  around do |example|
    # Run jobs inline for this test
    perform_enqueued_jobs do
      example.run
    end
  end

  it 'sends confirmation email after order creation' do
    post '/api/v1/orders', params: valid_params, headers: auth_headers(user)

    expect(ActionMailer::Base.deliveries.count).to eq(1)
    expect(ActionMailer::Base.deliveries.last.to).to include(user.email)
  end
end
```

---

## 9. Frontend: Job Progress

### 9.1 Polling Pattern

For simple progress tracking:

```typescript
// src/shared/hooks/useJobProgress.ts
import { useState, useEffect, useCallback } from 'react';
import api from '@/shared/services/api';

interface JobProgress {
  status: 'queued' | 'processing' | 'completed' | 'failed';
  progress: number;  // 0-100
  result?: unknown;
  error?: string;
}

export function useJobProgress(jobId: string | null) {
  const [progress, setProgress] = useState<JobProgress | null>(null);
  const [polling, setPolling] = useState(false);

  const checkProgress = useCallback(async () => {
    if (!jobId) return;

    try {
      const { data } = await api.get<JobProgress>(`/jobs/${jobId}/progress`);
      setProgress(data);

      if (data.status === 'completed' || data.status === 'failed') {
        setPolling(false);
      }
    } catch (error) {
      console.error('Failed to check job progress:', error);
    }
  }, [jobId]);

  useEffect(() => {
    if (!jobId) return;

    setPolling(true);
    checkProgress();

    const interval = setInterval(checkProgress, 2000);  // Poll every 2 seconds

    return () => clearInterval(interval);
  }, [jobId, checkProgress]);

  return { progress, polling };
}
```

### 9.2 WebSocket Pattern (Better)

```typescript
// src/shared/hooks/useJobProgressWS.ts
import { useState, useCallback } from 'react';
import { useChannel } from '@/shared/hooks/useChannel';

interface JobProgress {
  job_id: string;
  status: string;
  progress: number;
  message?: string;
}

export function useJobProgressWS(jobId: string | null) {
  const [progress, setProgress] = useState<JobProgress | null>(null);

  const handleReceived = useCallback((data: unknown) => {
    const message = data as { type: string; data: JobProgress };

    if (message.type === 'job_progress' && message.data.job_id === jobId) {
      setProgress(message.data);
    }
  }, [jobId]);

  useChannel({
    channel: 'NotificationChannel',
    onReceived: handleReceived,
  });

  return progress;
}
```

### 9.3 Progress Component

```tsx
// src/shared/components/JobProgress.tsx
import { useJobProgress } from '@/shared/hooks/useJobProgress';

interface JobProgressProps {
  jobId: string;
  label?: string;
  onComplete?: (result: unknown) => void;
}

export function JobProgress({ jobId, label = 'Processing', onComplete }: JobProgressProps) {
  const { progress } = useJobProgress(jobId);

  if (!progress) return null;

  if (progress.status === 'completed') {
    onComplete?.(progress.result);
    return (
      <div className="bg-green-50 border border-green-200 rounded-lg p-4">
        <p className="text-green-800 font-medium">✅ {label} complete!</p>
      </div>
    );
  }

  if (progress.status === 'failed') {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4">
        <p className="text-red-800 font-medium">❌ {label} failed</p>
        {progress.error && <p className="text-red-600 text-sm mt-1">{progress.error}</p>}
      </div>
    );
  }

  return (
    <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
      <div className="flex items-center justify-between mb-2">
        <span className="text-blue-800 font-medium">{label}...</span>
        <span className="text-blue-600 text-sm">{progress.progress}%</span>
      </div>
      <div className="w-full bg-blue-200 rounded-full h-2">
        <div
          className="bg-blue-600 rounded-full h-2 transition-all duration-300"
          style={{ width: `${progress.progress}%` }}
        />
      </div>
    </div>
  );
}
```

### 9.4 Rails Progress Endpoint

```ruby
# config/routes.rb
namespace :api do
  namespace :v1 do
    resources :jobs, only: [] do
      member do
        get :progress
      end
    end
  end
end

# app/controllers/api/v1/jobs_controller.rb
class Api::V1::JobsController < ApplicationController
  def progress
    import = Import.find_by!(job_id: params[:id], user: current_user)

    render json: {
      status: import.status,
      progress: import.progress,
      result: import.status == 'completed' ? import.result_summary : nil,
      error: import.error_details
    }
  end
end
```

---

## 10. Production Configuration

### 10.1 GoodJob on Render

**Option A: Async mode (small apps)**

No extra process needed. Jobs run in the web process:

```ruby
# config/initializers/good_job.rb
config.good_job.execution_mode = :async_server
config.good_job.max_threads = 3  # Reserve threads for jobs
```

**Option B: External worker (recommended for production)**

Add a background worker service on Render:

```yaml
# render.yaml
services:
  - type: web
    name: myapp-api
    runtime: ruby
    startCommand: bundle exec puma -C config/puma.rb

  - type: worker
    name: myapp-worker
    runtime: ruby
    startCommand: bundle exec good_job
    envVars:
      - key: GOOD_JOB_MAX_THREADS
        value: 5
      - key: DATABASE_URL
        fromDatabase:
          name: myapp-db
          property: connectionString
```

### 10.2 Sidekiq on Render

```yaml
# render.yaml
services:
  - type: web
    name: myapp-api
    runtime: ruby
    startCommand: bundle exec puma -C config/puma.rb

  - type: worker
    name: myapp-worker
    runtime: ruby
    startCommand: bundle exec sidekiq -C config/sidekiq.yml
    envVars:
      - key: REDIS_URL
        fromService:
          name: myapp-redis
          type: redis
          property: connectionString

  - type: redis
    name: myapp-redis
    plan: starter  # $10/mo
```

### 10.3 Procfile (Alternative)

```
# Procfile
web: bundle exec puma -C config/puma.rb
worker: bundle exec good_job
# or
# worker: bundle exec sidekiq -C config/sidekiq.yml
```

### 10.4 Database Pool Size

Background workers need their own database connections:

```yaml
# config/database.yml
production:
  <<: *default
  url: <%= ENV['DATABASE_URL'] %>
  pool: <%= ENV.fetch('RAILS_MAX_THREADS') { 5 }.to_i + ENV.fetch('GOOD_JOB_MAX_THREADS') { 5 }.to_i %>
```

---

## 11. Choosing GoodJob vs Sidekiq

| Feature | GoodJob | Sidekiq |
|---------|---------|---------|
| **Requires Redis** | ❌ No | ✅ Yes |
| **Setup complexity** | ⭐ Simple | ⭐⭐ Medium |
| **Cost** | Free (uses existing DB) | Free (needs Redis ~$10/mo) |
| **Job execution** | Polling (configurable) | Push (instant) |
| **Throughput** | Hundreds/second | Thousands/second |
| **ACID guarantees** | ✅ Yes (PostgreSQL) | ❌ No (Redis) |
| **Dashboard** | ✅ Built-in | ✅ Built-in (better) |
| **Cron/scheduling** | ✅ Built-in | Needs gem (sidekiq-cron) |
| **Concurrency model** | Threads | Threads |
| **Job durability** | ✅ Survives restarts | ⚠️ Can lose jobs* |
| **Community** | Growing | Very large |

> **\*Note:** Sidekiq with `super_fetch` (Pro) or Redis persistence configured properly won't lose jobs. But out of the box, it's possible.

### Decision Tree

```
Do you already have Redis?
├── Yes → Do you need >500 jobs/second?
│         ├── Yes → Sidekiq
│         └── No  → Either works (GoodJob is simpler)
└── No  → GoodJob (don't add Redis just for jobs)
```

---

## 12. Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Jobs not running | Queue adapter not set | Check `config.active_job.queue_adapter` |
| Jobs stuck in queue | Worker not running | Start worker process (`good_job` or `sidekiq`) |
| `PG::ConnectionBad` | DB pool exhausted | Increase pool size in `database.yml` |
| Jobs running twice | Not idempotent | Add idempotency checks |
| Memory growing | Job objects not GC'd | Avoid storing large objects; use IDs |
| Slow jobs blocking queue | Single queue | Use multiple queues with priorities |

### Debugging Tips

```ruby
# Check GoodJob queue status in Rails console
GoodJob::Job.where(finished_at: nil).group(:job_class).count
# => {"CleanupJob"=>0, "OrderNotificationJob"=>3}

# Find failed jobs
GoodJob::Job.where.not(error: nil).last(5).each do |job|
  puts "#{job.job_class}: #{job.error}"
end

# Retry a specific failed job
GoodJob::Job.find(job_id).retry_job
```

```ruby
# Check Sidekiq queue status
Sidekiq::Queue.all.each do |queue|
  puts "#{queue.name}: #{queue.size} jobs"
end

# Find dead (permanently failed) jobs
Sidekiq::DeadSet.new.each do |job|
  puts "#{job.klass}: #{job['error_message']}"
end
```

### Performance Tips

1. **Keep jobs small.** Pass IDs, not entire objects. Let the job fetch what it needs.
2. **Use queues.** Separate critical work (payments) from low-priority work (cleanup).
3. **Monitor queue depth.** If the queue grows faster than workers can process, add more workers.
4. **Set timeouts.** Jobs that run forever block threads:

```ruby
class ImportJob < ApplicationJob
  # Kill the job if it takes more than 10 minutes
  def perform(import_id)
    Timeout.timeout(10.minutes) do
      # ... import logic
    end
  end
end
```

5. **Batch related work.** Instead of enqueuing 1000 individual jobs, process in batches:

```ruby
# ❌ Bad — 1000 jobs in queue
users.each { |user| SendNewsletterJob.perform_later(user.id) }

# ✅ Better — batch into groups
users.each_slice(100) do |batch|
  SendNewsletterBatchJob.perform_later(batch.map(&:id))
end
```
