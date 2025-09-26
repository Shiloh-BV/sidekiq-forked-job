# frozen_string_literal: true

require "json"
require "socket"

module Sidekiq
  module Forked
    module Worker
      FORK_ZSET_KEY      = "sidekiq:forked:active"
      FORK_HASH_KEY      = "sidekiq:forked:meta"
      DEFAULT_TIMEOUT    = 600
      DEFAULT_TTL        = 900
      DEFAULT_REAP_EVERY = 30
    end
  end
end

require_relative "worker/version"
require_relative "worker/configuration"
require_relative "worker/manager"
require_relative "worker/zombie_reaper"
require_relative "worker/mixin"

module Sidekiq
  module Forked
    module Worker
      class << self
        def prepended(base)
          Mixin.prepended(base)
        end

        def configure(&block)
          Manager.configure(&block)
        end

        def config
          Manager.config
        end

        def install_reaper!
          Manager.install_reaper!
        end

        def redis(&block)
          Manager.redis(&block)
        end

        def now_f
          Manager.now_f
        end

        def record_child(**kwargs)
          Manager.record_child(**kwargs)
        end

        def clear_child(pid)
          Manager.clear_child(pid)
        end

        def host_id
          Manager.host_id
        end

        def alive?(pid)
          Manager.alive?(pid)
        end

        def hard_kill(pid)
          Manager.hard_kill(pid)
        end
      end

      include Mixin
    end
  end
end
