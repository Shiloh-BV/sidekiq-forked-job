# sidekiq-forked-worker

Fork Sidekiq worker perform into a child process with:

- Redis bookkeeping of child PIDs and metadata
- TTL-based zombie reaping and parent/timeout detection
- Configurable hooks: `parent_pre_fork`, `parent_post_fork`, `child_post_fork`
- Per-worker timeouts and TTLs; global defaults via configuration
 - Nil timeout supported (no parent-enforced timeout)
 - Distributed-safe: reaper only manages children on its own host

Installation:

```ruby
gem "sidekiq-forked-worker"
```

Usage:

```ruby
require "sidekiq/forked/worker"

Sidekiq::Forked::Worker.configure do |c|
  c.parent_pre_fork = ->(worker, args){ ActiveRecord::Base.clear_active_connections! }
  c.parent_post_fork = ->(worker, args, pid){ Sidekiq.logger.info("forked #{pid}") }
  c.child_post_fork = ->(worker, args){ }
end

class HeavyJob
  include Sidekiq::Worker
  prepend Sidekiq::Forked::Worker

  self.fork_timeout = 60
end

Host identity override

- By default, host identity is `Socket.gethostname`.
- Override via env var `SIDEKIQ_FORKED_WORKER_HOST` to a stable host ID when needed (e.g. containers):

```bash
SIDEKIQ_FORKED_WORKER_HOST=$(hostname -f) bundle exec sidekiq
```
```

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/sidekiq/forked/worker`. To experiment with that code, run `bin/console` for an interactive prompt.

## Installation

TODO: Replace `UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG` with your gem name right after releasing it to RubyGems.org. Please do not do it earlier due to security reasons. Alternatively, replace this section with instructions to install your gem from git if you don't plan to release to RubyGems.org.

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG
```

## Usage

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/sidekiq-forked-worker.
