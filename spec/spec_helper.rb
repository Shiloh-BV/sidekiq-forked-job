# frozen_string_literal: true

begin
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
    minimum_coverage line: 95, branch: 70
    minimum_coverage_by_file 90
  end
rescue LoadError
  # simplecov optional
end

require "sidekiq/forked/worker"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
