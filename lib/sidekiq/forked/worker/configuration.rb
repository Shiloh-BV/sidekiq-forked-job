# frozen_string_literal: true

module Sidekiq
  module Forked
    module Worker
      class Configuration
        attr_accessor :parent_pre_fork,
          :parent_post_fork,
          :child_post_fork,
          :default_timeout,
          :default_ttl,
          :default_reap_interval

        def initialize
          @parent_pre_fork = nil
          @parent_post_fork = nil
          @child_post_fork = nil
          @default_timeout = Worker::DEFAULT_TIMEOUT
          @default_ttl = Worker::DEFAULT_TTL
          @default_reap_interval = Worker::DEFAULT_REAP_EVERY
        end
      end
    end
  end
end
