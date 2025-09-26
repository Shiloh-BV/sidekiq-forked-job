# frozen_string_literal: true

module Sidekiq
  module Forked
    module Worker
      module Manager
        class << self
          def configure
            cfg = config
            yield cfg if block_given?
            cfg
          end

          def config
            @config ||= Configuration.new
          end

          def host_id
            env = normalize_env_host(ENV["SIDEKIQ_FORKED_WORKER_HOST"])
            env || Socket.gethostname
          end

          def install_reaper!
            return if @reaper_installed
            @reaper_installed = true

            Sidekiq.configure_server do |cfg|
              attach_reaper_hooks(cfg)
            end
          end

          def reaper_factory
            @reaper_factory ||= -> { ZombieReaper.new }
          end

          attr_writer :reaper_factory

          def redis(&block)
            Sidekiq.redis(&block)
          end

          def now_f
            Process.clock_gettime(Process::CLOCK_REALTIME)
          end

          def record_child(pid:, jid:, klass:, timeout:, ttl:)
            now = now_f
            meta = {
              "pid" => pid,
              "ppid" => Process.pid,
              "jid" => jid,
              "klass" => klass,
              "host" => host_id,
              "started" => now,
              "timeout" => timeout,
              "expires" => now + ttl
            }

            redis do |r|
              r.multi do |multi|
                multi.zadd(Worker::FORK_ZSET_KEY, now, pid)
                multi.hset(Worker::FORK_HASH_KEY, pid, JSON.generate(meta))
              end
            end
          end

          def clear_child(pid)
            redis do |r|
              r.multi do |multi|
                multi.zrem(Worker::FORK_ZSET_KEY, pid)
                multi.hdel(Worker::FORK_HASH_KEY, pid)
              end
            end
          end

          def alive?(pid)
            Process.kill(0, pid)
            true
          rescue Errno::ESRCH
            false
          rescue Errno::EPERM
            true
          end

          def hard_kill(pid)
            Process.kill("KILL", pid)
          rescue
            nil
          end

          private

          def attach_reaper_hooks(cfg)
            thread = nil

            cfg.on(:startup) { thread = spawn_reaper_thread }
            cfg.on(:quiet) { ZombieReaper.kill_all! }
            cfg.on(:shutdown) do
              ZombieReaper.kill_all!
              thread&.kill
            end
          end

          def spawn_reaper_thread
            Thread.new do
              reaper_factory.call.run
            end.tap { |thread| thread.name = "forked-worker-reaper" }
          end

          def normalize_env_host(value)
            return if value.nil?

            stripped = value.to_s.strip
            stripped unless stripped.empty?
          end
        end
      end
    end
  end
end
