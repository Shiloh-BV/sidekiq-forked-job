# Sidekiq Forked Worker

Run Sidekiq jobs in forked child processes so heavy work can release memory back to the operating system as soon as it finishes. The gem layers bookkeeping around every fork so you can reap stranded children, observe them in Redis, and customise lifecycle hooks without writing the plumbing yourself.

## Why fork?

- **Return memory to the OS.** RSS allocated by the job is reclaimed when the child exits, instead of lingering inside Sidekiq’s long-lived worker processes.
- **Bypass Ruby’s GIL.** Each child process can run CPU-bound workloads independently of the parent threads.
- **Isolate side effects.** Global state mutated inside the child disappears with the process.

Those benefits come with serious trade-offs—see [Operational Warnings](#operational-warnings) before rolling this into production.

## Installation

Add the gem to your bundle (Ruby 3.0+):

```ruby
# Gemfile
gem "sidekiq-forked-worker"
```

Install dependencies:

```bash
bundle install
```

## Quick start

```ruby
# config/initializers/sidekiq_forked_worker.rb
require "sidekiq/forked/worker"

Sidekiq::Forked::Worker.configure do |config|
  config.parent_pre_fork = ->(worker, args) { ActiveRecord::Base.clear_active_connections! }
  config.child_post_fork = ->(_worker, _args) { Sidekiq.logger.info("child #{Process.pid} ready") }
  config.default_timeout = nil # let the zombie reaper handle overdue jobs
  config.default_ttl = 900      # seconds before Redis metadata is purged
end

class HeavyReportJob
  include Sidekiq::Worker
  prepend Sidekiq::Forked::Worker

  self.fork_timeout = nil            # no parent-enforced timeout
  self.fork_redis_ttl = 900          # metadata lifetime in Redis (seconds)
  self.fork_reap_interval = 30       # how often the reaper thread wakes up

  def perform(account_id)
    report = HeavyReport.generate(account_id)
    ReportMailer.deliver_later(report)
  end
end
```

Enqueue jobs normally:

```ruby
HeavyReportJob.perform_async(123)
```

## Configuration reference

`Sidekiq::Forked::Worker.configure` exposes three global hooks and default timings:

| Setting | Purpose |
| --- | --- |
| `parent_pre_fork` | Block invoked in the Sidekiq thread immediately before `fork`. Use it to release shared resources (DB connections, cache clients, etc.). |
| `parent_post_fork` | Called after the child PID is known. Arguments: `worker`, `args`, `child_pid`. |
| `child_post_fork` | Executed inside the child right after the fork and before your `perform`. Attach signal handlers or reconnect dependencies here. |
| `default_timeout` | Seconds the parent will wait for the child before killing it. Set to `nil` to rely entirely on the zombie reaper (recommended while gathering data). |
| `default_ttl` | How long Redis metadata is considered valid. Also acts as the upper bound for TTL-based reaping. |
| `default_reap_interval` | How frequently the background reaper thread wakes up. |

Each worker class can override:

```ruby
self.fork_timeout = nil          # or an integer for per-job timeout
self.fork_redis_ttl = 600         # seconds metadata should live in Redis
self.fork_reap_interval = 15      # seconds between reaper sweeps for children of this worker
```

### Redis bookkeeping

- Active child PIDs are stored in `sidekiq:forked:active` (sorted set).
- Metadata per PID is stored in `sidekiq:forked:meta`.
- `SIDEKIQ_FORKED_WORKER_HOST` overrides host identity if the default `Socket.gethostname` is not stable (e.g. ephemeral containers).

### Zombie reaper

A single thread is registered with the Sidekiq server on startup. Every cycle it:

1. Removes stale PIDs whose sorted-set score is below `now - ttl` (TTL expiry).
2. Parses metadata for live children on the current host.
3. Kills children whose parents are dead or whose per-job timeout deadline has passed.
4. Deletes cleaned-up entries from Redis.

Calling `Sidekiq::Forked::Worker::ZombieReaper.kill_all!` kills every tracked child for the current host and removes their metadata—used on quiet/shutdown.

## Operational warnings

⚠️ **TTL IS DANGEROUS IN THIS RELEASE.** The “timeout” stored with each child is used only by the reaper. If the reaper determines that `started + timeout` has elapsed, it will **kill the child immediately**, even if the parent is still alive and the job is legitimately running. Until we gather data and stabilise this behaviour, treat the timeout feature as experimental.

Recommended posture for now:

- Set `self.fork_timeout = nil` (or configure `default_timeout = nil`). This disables parent-side timeouts and lets the reaper focus on parent death and TTL expiry.
- Tune `fork_redis_ttl` high enough to avoid premature kills if your jobs can legitimately run longer than the default 900 s.
- Monitor Redis keys and Sidekiq logs to ensure the reaper isn’t surprising you.

Additional considerations:

- Forking is slower to start than threads. Reserve it for heavy memory/CPU jobs.
- While a child runs, the parent thread is blocked waiting on the pipe—there’s no streaming of intermediate progress.
- Redis must be reachable from both parent and reaper threads; otherwise metadata clean-up stalls.

## Development & testing

```bash
bundle install
bundle exec standardrb   # style
bundle exec rspec        # tests + SimpleCov (HTML report in coverage/index.html)
```

CI pipelines (GitLab/GitHub Actions) run the same commands, ensure a version bump before merging to `master`, and build the gem artifact on successful master builds.

To examine behaviour locally with Redis:

```bash
REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec
```

## Release checklist

1. Bump `lib/sidekiq/forked/worker/version.rb` and update CHANGELOG/README.
2. `bundle exec standardrb && bundle exec rspec`.
3. `gem build sidekiq-forked-worker.gemspec` (CI does this on master).
4. Push tag and publish to RubyGems.

## License

MIT. See `LICENSE` for details.
