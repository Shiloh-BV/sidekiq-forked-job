# frozen_string_literal: true

require "json"
require "logger"
require "stringio"
require "sidekiq"
require "sidekiq/forked/worker"

class FakeSidekiqConfig
  attr_reader :events

  def initialize
    @events = Hash.new { |h, k| h[k] = [] }
  end

  def on(event, &block)
    @events[event] << block
  end
end

HOST_ENV_KEY = "SIDEKIQ_FORKED_WORKER_HOST"

RSpec.describe Sidekiq::Forked::Worker do
  before(:all) do
    redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/15")
    Sidekiq.configure_client { |config| config.redis = {url: redis_url} }
    Sidekiq.configure_server { |config| config.redis = {url: redis_url} }
  end

  around do |example|
    original = ENV[HOST_ENV_KEY]
    flush_redis

    example.run
  ensure
    flush_redis
    ENV[HOST_ENV_KEY] = original
    Sidekiq::Forked::Worker::Manager.instance_variable_set(:@config, nil)
  end

  def flush_redis
    Sidekiq.redis { |redis| redis.del(described_class::FORK_ZSET_KEY, described_class::FORK_HASH_KEY) }
  end

  def define_worker(const_name, timeout: 2, ttl: described_class::DEFAULT_TTL, reap_every: described_class::DEFAULT_REAP_EVERY, &block)
    klass = Class.new do
      include Sidekiq::Worker
      prepend Sidekiq::Forked::Worker

      self.fork_timeout = timeout
      self.fork_redis_ttl = ttl
      self.fork_reap_interval = reap_every

      class_eval(&block)
    end

    stub_const(const_name, klass)
    klass
  end

  def wait_for_exit(pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return true
      end

      begin
        waited = Process.wait(pid, Process::WNOHANG)
        return true if waited == pid
      rescue Errno::ECHILD
        # Not our child; rely on kill checks
      end

      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
  end

  it "exposes a version" do
    expect(described_class::VERSION).not_to be_nil
  end

  it "can be configured and returns the configuration" do
    config = described_class.configure do |cfg|
      cfg.default_timeout = 5
    end

    expect(config.default_timeout).to eq(5)
    expect(described_class.config.default_timeout).to eq(5)
  end

  describe "forked execution" do
    it "executes perform in a fork and returns the value" do
      worker = define_worker("ForkReturnWorker") do
        def perform(value)
          value * 2
        end
      end

      expect(worker.new.perform(3)).to eq(6)
    end

    it "tracks and clears child metadata in redis" do
      worker = define_worker("RedisBookkeepingWorker") do
        def perform(value)
          value
        end
      end

      worker.new.perform("x")

      zset_count = Sidekiq.redis { |redis| redis.zcard(described_class::FORK_ZSET_KEY) }
      hash_count = Sidekiq.redis { |redis| redis.hlen(described_class::FORK_HASH_KEY) }

      expect(zset_count).to eq(0)
      expect(hash_count).to eq(0)
    end

    it "honors finite timeouts and kills the child" do
      worker = define_worker("TimeoutWorker", timeout: 1) do
        def perform(_value)
          sleep 2
        end
      end

      expect { worker.new.perform(:anything) }.to raise_error(/timed out/)
    end

    it "supports nil timeouts (wait forever)" do
      original_default = described_class.config.default_timeout
      described_class.configure { |cfg| cfg.default_timeout = nil }

      worker = define_worker("NilTimeoutWorker", timeout: nil) do
        def perform(value)
          sleep 0.2
          value + 1
        end
      end

      expect(worker.new.perform(1)).to eq(2)
    ensure
      described_class.configure { |cfg| cfg.default_timeout = original_default }
    end

    it "invokes configuration hooks around fork" do
      parent_events = []
      rd, wr = IO.pipe

      described_class.configure do |cfg|
        cfg.parent_pre_fork = ->(worker, args) { parent_events << [:pre, worker.class.name, args.dup] }
        cfg.parent_post_fork = ->(_worker, _args, pid) { parent_events << [:post, pid] }
        cfg.child_post_fork = ->(_worker, _args) {
          wr.puts("child_post_fork")
          wr.flush
        }
      end

      worker = define_worker("HookWorker") do
        def perform(value)
          value
        end
      end

      result = worker.new.perform(:ok)

      wr.close
      child_marker = rd.gets&.strip
      rd.close

      event_names = parent_events.map(&:first)

      expect(result).to eq(:ok)
      expect(event_names).to include(:pre, :post)
      expect(child_marker).to eq("child_post_fork")
    ensure
      wr.close unless wr.closed?
      rd.close unless rd.closed?
    end

    it "propagates child exceptions to the parent" do
      worker = define_worker("ErrorWorker") do
        def perform(_)
          raise ArgumentError, "boom"
        end
      end

      expect { worker.new.perform(nil) }.to raise_error(/ArgumentError: boom/)
    end

    it "handles Sidekiq::Shutdown by cleaning up child" do
      worker = define_worker("ShutdownWorker") do
        def perform(_)
          raise Sidekiq::Shutdown
        end
      end

      expect { worker.new.perform(nil) }.to raise_error do |error|
        expect([Sidekiq::Shutdown, EOFError]).to include(error.class)
      end
    end

    it "drains pending child messages when an error occurs before reading" do
      described_class.configure do |cfg|
        cfg.parent_post_fork = ->(_worker, _args, _pid) { raise "parent blew up" }
      end

      worker = define_worker("DrainWorker") do
        def perform(value)
          value
        end
      end

      expect { worker.new.perform(:ok) }.to raise_error(/parent blew up/)
    end

    it "executes child helper inline when requested" do
      worker = define_worker("InlineChildWorker") do
        def perform(value)
          value + 5
        end
      end

      child_reader, writer = IO.pipe
      parent_reader = child_reader.dup

      worker.new.send(:run_child_process, child_reader, writer, [7], 0.5, 2, ensure_exit: false) { 7 + 5 }

      message = Marshal.load(parent_reader)
      expect(message[:ok]).to eq(true)
      expect(message[:result]).to eq(12)
      expect(Thread.current[:fork_reap_interval]).to eq(0.5)
      expect(Thread.current[:fork_redis_ttl]).to eq(2)
    ensure
      begin
        parent_reader.close
      rescue
        nil
      end
      begin
        child_reader.close
      rescue
        nil
      end
      Thread.current[:fork_reap_interval] = nil
      Thread.current[:fork_redis_ttl] = nil
    end

    it "marshals errors when child helper raises" do
      worker = define_worker("InlineChildErrorWorker") do
        def perform(value)
          value
        end
      end

      child_reader, writer = IO.pipe
      parent_reader = child_reader.dup

      worker.new.send(:run_child_process, child_reader, writer, [:arg], 0.5, 2, ensure_exit: false) { raise "boom" }

      message = Marshal.load(parent_reader)
      expect(message[:ok]).to be(false)
      expect(message[:error].first).to eq("RuntimeError")
    ensure
      begin
        parent_reader.close
      rescue
        nil
      end
      begin
        child_reader.close
      rescue
        nil
      end
      Thread.current[:fork_reap_interval] = nil
      Thread.current[:fork_redis_ttl] = nil
    end

    it "disconnects ActiveRecord when available" do
      pool = Class.new do
        class << self
          attr_accessor :disconnected
        end

        self.disconnected = false

        def self.disconnect!
          self.disconnected = true
        end
      end

      base = Class.new do
        define_singleton_method(:connection_pool) { pool }
      end

      stub_const("ActiveRecord", Module.new)
      stub_const("ActiveRecord::Base", base)

      worker = define_worker("ActiveRecordWorker") do
        def perform(value)
          value
        end
      end

      worker.new.send(:disconnect_global_clients_safely)
      expect(pool.disconnected).to be(true)
    end

    it "propagates signals from parent to child" do
      reader, writer = IO.pipe

      described_class.configure do |cfg|
        cfg.child_post_fork = lambda do |_worker, args|
          fd = args.first
          io = IO.for_fd(fd, "w")
          Signal.trap("USR1") do
            io.puts("USR1")
            io.flush
          end
          Thread.current[:signal_writer] = io
        end
        cfg.parent_post_fork = lambda do |_worker, _args, pid|
          sleep 0.05
          Process.kill("USR1", pid)
        end
      end

      worker = define_worker("SignalWorker") do
        def perform(fd)
          io = Thread.current[:signal_writer]
          sleep 0.2
          io.puts("done")
          io.flush
          :ok
        ensure
          io&.close
        end
      end

      result = worker.new.perform(writer.fileno)
      writer.close

      buffer = []
      while IO.select([reader], nil, nil, 0.1)
        line = reader.gets
        break unless line

        buffer << line.strip
      end
      reader.close

      expect(result).to eq(:ok)
      expect(buffer).to include("USR1")
      expect(buffer.last).to eq("done")
    ensure
      writer.close unless writer.closed?
      reader.close unless reader.closed?
    end
  end

  describe "manager delegations" do
    it "exposes redis helper and monotonic time" do
      value = described_class.now_f
      expect(value).to be_a(Float)

      ping = described_class.redis { |redis| redis.ping }
      expect(ping).to eq("PONG")
    end

    it "records and clears child metadata via delegators" do
      child = Process.fork { sleep 5 }
      ttl = 2
      described_class.record_child(pid: child, jid: "jid-test", klass: "Worker", timeout: 1, ttl: ttl)

      meta = Sidekiq.redis { |redis| redis.hget(described_class::FORK_HASH_KEY, child) }
      expect(meta).not_to be_nil

      described_class.clear_child(child)
      remaining = Sidekiq.redis { |redis| redis.hget(described_class::FORK_HASH_KEY, child) }
      expect(remaining).to be_nil
    ensure
      begin
        Process.kill("KILL", child)
      rescue
        nil
      end
      begin
        Process.wait(child)
      rescue
        nil
      end
    end

    it "checks liveness and can hard kill processes" do
      child = Process.fork { sleep 10 }

      expect(described_class.alive?(child)).to be(true)
      described_class.hard_kill(child)
      expect(wait_for_exit(child)).to be(true)
    ensure
      begin
        Process.wait(child)
      rescue
        nil
      end
    end

    it "installs reaper hooks through Sidekiq.configure_server" do
      fake_config = FakeSidekiqConfig.new
      runs = []
      kills = []

      fake_reaper_class = Class.new do
        def initialize(log)
          @log = log
        end

        def run
          @log << [:run, Thread.current.name]
        end
      end

      manager = Sidekiq::Forked::Worker::Manager
      original_factory = manager.reaper_factory
      manager.reaper_factory = -> { fake_reaper_class.new(runs) }
      original_flag = manager.instance_variable_get(:@reaper_installed)
      manager.instance_variable_set(:@reaper_installed, nil)

      reaper_singleton = Sidekiq::Forked::Worker::ZombieReaper.singleton_class
      reaper_singleton.alias_method :__orig_kill_all!, :kill_all!
      reaper_singleton.define_method(:kill_all!) { kills << :kill }

      sidekiq_singleton = class << Sidekiq; self; end
      original_configure = Sidekiq.method(:configure_server)
      sidekiq_singleton.define_method(:configure_server) do |&block|
        block.call(fake_config)
      end

      described_class.install_reaper!

      startup_threads = fake_config.events[:startup].map { |blk| blk.call }
      startup_threads.each { |thread| thread&.join }
      fake_config.events[:quiet].each { |blk| blk.call }
      fake_config.events[:shutdown].each { |blk| blk.call }

      expect(runs).not_to be_empty
      expect(kills.size).to eq(2)
    ensure
      manager.reaper_factory = original_factory
      manager.instance_variable_set(:@reaper_installed, original_flag)
      reaper_singleton.alias_method :kill_all!, :__orig_kill_all!
      reaper_singleton.remove_method :__orig_kill_all!
      sidekiq_singleton.define_method(:configure_server, original_configure)
    end

    it "spawns reaper threads via helper" do
      manager = Sidekiq::Forked::Worker::Manager
      original_factory = manager.reaper_factory
      result = []
      manager.reaper_factory = -> {
        Class.new {
          def initialize(log)
            @log = log
          end

          def run
            @log << Thread.current.name
          end
        }.new(result)
      }

      thread = manager.send(:spawn_reaper_thread)
      thread.join

      expect(result).not_to be_empty
    ensure
      manager.reaper_factory = original_factory
    end
  end

  describe "zombie reaper" do
    it "no-ops when there are no tracked processes" do
      described_class::ZombieReaper.kill_all!
    end

    it "computes default reap interval when thread local absent" do
      reaper = described_class::ZombieReaper.new
      expect(reaper.send(:reap_interval)).to eq(described_class.config.default_reap_interval.to_f)
    end

    it "reaps orphaned children when parent dies" do
      reader, writer = IO.pipe
      orphan_pid = nil

      parent = Process.fork do
        reader.close
        middle = Process.fork do
          child = Process.fork { sleep 10 }

          now = described_class.now_f
          meta = {
            "pid" => child,
            "ppid" => Process.pid,
            "jid" => "jid-orphan",
            "klass" => "Worker",
            "host" => described_class.host_id,
            "started" => now,
            "timeout" => 60,
            "expires" => now + 60
          }

          Sidekiq.redis do |redis|
            redis.multi do |multi|
              multi.zadd(described_class::FORK_ZSET_KEY, now, child)
              multi.hset(described_class::FORK_HASH_KEY, child, JSON.generate(meta))
            end
          end

          writer.puts(child)
          writer.close
          exit!
        end

        begin
          Process.wait(middle)
        rescue
          nil
        end
        exit!
      end

      writer.close
      orphan_pid = reader.gets.to_i
      reader.close
      begin
        Process.wait(parent)
      rescue
        nil
      end

      expect(orphan_pid).to be_positive

      80.times do
        described_class::ZombieReaper.new.send(:reap_once)
        remaining = Sidekiq.redis { |redis| redis.zrange(described_class::FORK_ZSET_KEY, 0, -1) }
        break unless remaining.include?(orphan_pid.to_s)
        sleep 0.05
      end

      expect(wait_for_exit(orphan_pid)).to be(true)
    ensure
      begin
        Process.kill("KILL", orphan_pid) if orphan_pid && Process.kill(0, orphan_pid)
      rescue Errno::ESRCH
      end
      if orphan_pid
        begin
          Process.wait(orphan_pid)
        rescue
          nil
        end
      end
    end

    it "kills children that exceed their timeout even if parent lives" do
      child = Process.fork { sleep 10 }

      now = described_class.now_f
      meta = {
        "pid" => child,
        "ppid" => Process.pid,
        "jid" => "jid-timeout",
        "klass" => "Worker",
        "host" => described_class.host_id,
        "started" => now - 5,
        "timeout" => 0.1,
        "expires" => now + 60
      }

      Sidekiq.redis do |redis|
        redis.multi do |multi|
          multi.zadd(described_class::FORK_ZSET_KEY, now, child)
          multi.hset(described_class::FORK_HASH_KEY, child, JSON.generate(meta))
        end
      end

      80.times do
        described_class::ZombieReaper.new.send(:reap_once)
        break unless Sidekiq.redis { |redis| redis.hexists(described_class::FORK_HASH_KEY, child) }
        sleep 0.05
      end

      expect(wait_for_exit(child)).to be(true)
    ensure
      if child
        begin
          Process.wait(child)
        rescue
          nil
        end
      end
    end

    it "respects TTL expiry and host scoping" do
      now = described_class.now_f
      this_host = described_class.host_id
      other_host = "other-host.example"
      stale_pid = 9_900_001
      foreign_pid = 9_900_002

      Sidekiq.redis do |redis|
        redis.multi do |multi|
          multi.zadd(described_class::FORK_ZSET_KEY, now - 10, stale_pid)
          multi.hset(described_class::FORK_HASH_KEY, stale_pid, {
            pid: stale_pid,
            ppid: 1,
            jid: "jid-stale",
            klass: "Worker",
            host: this_host,
            started: now - 20,
            timeout: 5,
            expires: now - 5
          }.to_json)

          multi.zadd(described_class::FORK_ZSET_KEY, now, foreign_pid)
          multi.hset(described_class::FORK_HASH_KEY, foreign_pid, {
            pid: foreign_pid,
            ppid: 1,
            jid: "jid-foreign",
            klass: "Worker",
            host: other_host,
            started: now,
            timeout: 5,
            expires: now + 1000
          }.to_json)
        end
      end

      Thread.current[:fork_redis_ttl] = 1
      10.times do
        described_class::ZombieReaper.new.send(:reap_once)
        remaining = Sidekiq.redis { |redis| redis.zrange(described_class::FORK_ZSET_KEY, 0, -1) }
        break unless remaining.include?(stale_pid.to_s)
        sleep 0.05
      end
      Thread.current[:fork_redis_ttl] = nil

      zset_pids = Sidekiq.redis { |redis| redis.zrange(described_class::FORK_ZSET_KEY, 0, -1) }
      expect(zset_pids).not_to include(stale_pid.to_s)
      expect(zset_pids).to include(foreign_pid.to_s)

      described_class::ZombieReaper.kill_all!
      post_kill = Sidekiq.redis { |redis| redis.zrange(described_class::FORK_ZSET_KEY, 0, -1) }
      expect(post_kill).to include(foreign_pid.to_s)
      expect(post_kill).not_to include(stale_pid.to_s)
    ensure
      Sidekiq.redis do |redis|
        redis.multi do |multi|
          multi.zrem(described_class::FORK_ZSET_KEY, foreign_pid)
          multi.hdel(described_class::FORK_HASH_KEY, foreign_pid)
        end
      end
    end

    it "kill_all! terminates processes scoped to this host" do
      child = Process.fork { sleep 10 }
      now = described_class.now_f

      Sidekiq.redis do |redis|
        redis.multi do |multi|
          multi.zadd(described_class::FORK_ZSET_KEY, now, child)
          multi.hset(described_class::FORK_HASH_KEY, child, {
            pid: child,
            ppid: Process.pid,
            jid: "jid-host",
            klass: "Worker",
            host: described_class.host_id,
            started: now,
            timeout: 5,
            expires: now + 60
          }.to_json)
        end
      end

      described_class::ZombieReaper.kill_all!

      expect(wait_for_exit(child)).to be(true)
      remaining = Sidekiq.redis { |redis| redis.hget(described_class::FORK_HASH_KEY, child) }
      expect(remaining).to be_nil
    ensure
      Sidekiq.redis do |redis|
        redis.multi do |multi|
          multi.zrem(described_class::FORK_ZSET_KEY, child)
          multi.hdel(described_class::FORK_HASH_KEY, child)
        end
      end
      begin
        Process.wait(child)
      rescue
        nil
      end
    end

    it "supports stop condition when running the reaper loop" do
      reaper = described_class::ZombieReaper.new
      hits = []

      reaper_singleton = class << reaper; self; end
      reaper_singleton.alias_method :__orig_reap_once, :reap_once
      reaper_singleton.define_method(:reap_once) { hits << :hit }

      reaper.run(stop_condition: -> { hits.length >= 2 }, sleep_interval: 0)

      expect(hits.length).to eq(2)
    ensure
      reaper_singleton.alias_method :reap_once, :__orig_reap_once
      reaper_singleton.remove_method :__orig_reap_once
    end

    it "logs and raises after exceeding retry limit" do
      reaper = described_class::ZombieReaper.new
      hits = 0

      reaper_singleton = class << reaper; self; end
      reaper_singleton.alias_method :__orig_reap_once, :reap_once
      reaper_singleton.define_method(:reap_once) do
        hits += 1
        raise "boom"
      end

      logger_io = StringIO.new
      custom_logger = Logger.new(logger_io)
      sidekiq_singleton = class << Sidekiq; self; end
      sidekiq_singleton.alias_method :__orig_logger, :logger
      sidekiq_singleton.define_method(:logger) { custom_logger }

      expect {
        reaper.run(stop_condition: -> { false }, sleep_interval: 0, max_retries: 0)
      }.to raise_error(RuntimeError, "boom")

      expect(logger_io.string).to include("ForkedWorker::ZombieReaper crashed: RuntimeError: boom")
      expect(hits).to eq(1)
    ensure
      reaper_singleton.alias_method :reap_once, :__orig_reap_once
      reaper_singleton.remove_method :__orig_reap_once
      sidekiq_singleton.alias_method :logger, :__orig_logger
      sidekiq_singleton.remove_method :__orig_logger
    end
  end

  describe "host identification" do
    it "uses hostname by default" do
      expect(described_class.host_id).to eq(Socket.gethostname)
    end

    it "respects env override" do
      ENV[HOST_ENV_KEY] = " example-host "
      expect(described_class.host_id).to eq("example-host")
    end
  end
end
