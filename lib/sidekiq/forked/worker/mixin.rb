# frozen_string_literal: true

module Sidekiq
  module Forked
    module Worker
      module Mixin
        def self.prepended(base)
          base.singleton_class.class_eval do
            attr_accessor :fork_timeout, :fork_redis_ttl, :fork_reap_interval
          end

          base.fork_timeout       = Worker::DEFAULT_TIMEOUT
          base.fork_redis_ttl     = Worker::DEFAULT_TTL
          base.fork_reap_interval = Worker::DEFAULT_REAP_EVERY

          Manager.install_reaper!
        end

        def perform(*args)
          raw_timeout = self.class.fork_timeout.nil? ? Manager.config.default_timeout : self.class.fork_timeout
          timeout     = raw_timeout.nil? ? nil : raw_timeout.to_i
          ttl         = (self.class.fork_redis_ttl || Manager.config.default_ttl).to_i
          reap_int    = (self.class.fork_reap_interval || Manager.config.default_reap_interval)

          reader, writer = IO.pipe
          child_pid = nil

          begin
            Manager.config.parent_pre_fork&.call(self, args)

            child_pid = Process.fork do
              run_child_process(reader, writer, args, reap_int, ttl) { super(*args) }
            end

            Manager.config.parent_post_fork&.call(self, args, child_pid)

            writer.close
            Manager.record_child(pid: child_pid, jid: jid, klass: self.class.name, timeout: timeout, ttl: ttl)

            if timeout.nil?
              IO.select([reader])
              message = Marshal.load(reader)
              raise build_error(message) unless message[:ok]
              message[:result]
            elsif IO.select([reader], nil, nil, timeout)
              message = Marshal.load(reader)
              raise build_error(message) unless message[:ok]
              message[:result]
            else
              Manager.hard_kill(child_pid)
              raise "Forked child #{child_pid} timed out after #{timeout}s"
            end
          rescue ::Sidekiq::Shutdown
            Manager.hard_kill(child_pid) if child_pid
            raise
          ensure
            drain_pipe(reader)
            begin
              Process.wait(child_pid)
            rescue StandardError
            end
            Manager.clear_child(child_pid) if child_pid
          end
        end

        private

        def drain_pipe(reader)
          begin
            if IO.select([reader], nil, nil, 0.05)
              Marshal.load(reader)
            end
          rescue StandardError
          ensure
            begin
              reader.close
            rescue StandardError
            end
          end
        end

        def build_error(message)
          error = Array(message[:error])
          klass, msg, backtrace = error
          formatted_backtrace = Array(backtrace).join("\n")
          "#{klass}: #{msg}\n#{formatted_backtrace}"
        end

        def disconnect_global_clients_safely
          begin
            Sidekiq.redis { |conn| conn.close }
          rescue StandardError
          end

          begin
            if defined?(ActiveRecord::Base)
              ActiveRecord::Base.connection_pool.disconnect!
            end
          rescue StandardError
          end
        end

        def run_child_process(reader, writer, args, reap_int, ttl, ensure_exit: true, &block)
          begin
            reader.close

            Thread.current[:fork_reap_interval] = reap_int
            Thread.current[:fork_redis_ttl]     = ttl

            disconnect_global_clients_safely
            Manager.config.child_post_fork&.call(self, args)

            writer.sync = true
            result = block.call
            Marshal.dump({ ok: true, result: result }, writer)
          rescue StandardError => e
            writer.sync = true
            Marshal.dump({ ok: false, error: [e.class.name, e.message, e.backtrace] }, writer)
          ensure
            begin
              writer.close
            rescue StandardError
            end
            exit! if ensure_exit
          end
        end
      end
    end
  end
end
