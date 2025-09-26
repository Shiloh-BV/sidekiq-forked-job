# frozen_string_literal: true

module Sidekiq
  module Forked
    module Worker
      class ZombieReaper
        class << self
          def kill_all!
            current_host = Manager.host_id

            Manager.redis do |redis|
              all_pids = redis.zrange(Worker::FORK_ZSET_KEY, 0, -1)&.map(&:to_i) || []
              metas = if all_pids.empty?
                        []
                      else
                        Array(redis.hmget(Worker::FORK_HASH_KEY, *all_pids)).map { |json| json && JSON.parse(json) }
                      end
              my_pids = metas.compact.select { |meta| meta["host"] == current_host }.map { |meta| meta["pid"].to_i }

              my_pids.each { |pid| Manager.hard_kill(pid) }

              my_pids.each do |pid|
                redis.multi do |multi|
                  multi.zrem(Worker::FORK_ZSET_KEY, pid)
                  multi.hdel(Worker::FORK_HASH_KEY, pid)
                end
              end
            end
          end
        end

        def run(stop_condition: nil, sleep_interval: nil, max_retries: nil)
          retries = 0

          loop do
            begin
              reap_once
              break if stop_condition&.call

              sleep(sleep_interval || reap_interval)
              retries = 0
            rescue StandardError => e
              Sidekiq.logger.error("ForkedWorker::ZombieReaper crashed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
              retries += 1
              raise e if max_retries && retries > max_retries
              retry
            end
          end
        end

        private

        def reap_interval
          (Thread.current[:fork_reap_interval] || Manager.config.default_reap_interval || Worker::DEFAULT_REAP_EVERY).to_f
        end

        def reap_once
          now = Manager.now_f
          ttl = Thread.current[:fork_redis_ttl] || Manager.config.default_ttl || Worker::DEFAULT_TTL

          Manager.redis do |redis|
            cutoff = now - ttl

            stale_pids = redis.call("ZRANGE", Worker::FORK_ZSET_KEY, 0, cutoff, "BYSCORE")&.map(&:to_i) || []
            all_pids = redis.zrange(Worker::FORK_ZSET_KEY, 0, -1)&.map(&:to_i) || []
            metas = if all_pids.empty?
                      []
                    else
                      Array(redis.hmget(Worker::FORK_HASH_KEY, *all_pids)).map { |json| json && JSON.parse(json) }
                    end

            to_kill = stale_pids.dup
            current_host = Manager.host_id

            metas.compact.each do |meta|
              next unless meta["host"] == current_host

              pid        = meta["pid"].to_i
              ppid       = meta["ppid"].to_i
              timeout    = meta["timeout"]
              deadline   = meta["started"].to_f + timeout.to_f if timeout
              parent_dead = !Manager.alive?(ppid)
              over_time   = timeout.nil? ? false : (now > deadline)

              next unless Manager.alive?(pid)

              to_kill << pid if parent_dead || over_time
            end

            to_kill.uniq.each do |pid|
              Manager.hard_kill(pid)
              redis.multi do |multi|
                multi.zrem(Worker::FORK_ZSET_KEY, pid)
                multi.hdel(Worker::FORK_HASH_KEY, pid)
              end
            end
          end
        end
      end
    end
  end
end
