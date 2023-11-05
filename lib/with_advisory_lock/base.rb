# frozen_string_literal: true

require 'zlib'

module WithAdvisoryLock
  class Result
    attr_reader :result

    def initialize(lock_was_acquired, result = false)
      @lock_was_acquired = lock_was_acquired
      @result = result
    end

    def lock_was_acquired?
      @lock_was_acquired
    end
  end

  FAILED_TO_LOCK = Result.new(false)

  LockStackItem = Struct.new(:name, :shared)

  class Base
    attr_reader :connection, :lock_name, :timeout_seconds, :shared, :transaction, :disable_query_cache

    def initialize(connection, lock_name, options)
      options = { timeout_seconds: options } unless options.respond_to?(:fetch)
      options.assert_valid_keys :timeout_seconds, :shared, :transaction, :disable_query_cache

      @connection = connection
      @lock_name = lock_name
      @timeout_seconds = options.fetch(:timeout_seconds, nil)
      @shared = options.fetch(:shared, false)
      @transaction = options.fetch(:transaction, false)
      @disable_query_cache = options.fetch(:disable_query_cache, false)
    end

    def lock_str
      @lock_str ||= "#{ENV['WITH_ADVISORY_LOCK_PREFIX']}#{lock_name}"
    end

    def lock_stack_item
      @lock_stack_item ||= LockStackItem.new(lock_str, shared)
    end

    def self.lock_stack
      # access doesn't need to be synchronized as it is only accessed by the current thread.
      Thread.current[:with_advisory_lock_stack] ||= []
    end
    delegate :lock_stack, to: 'self.class'

    def already_locked?
      lock_stack.include? lock_stack_item
    end

    def with_advisory_lock_if_needed(&block)
      if disable_query_cache
        return lock_and_yield do
          ActiveRecord::Base.uncached(&block)
        end
      end

      lock_and_yield(&block)
    end

    def lock_and_yield(&block)
      if already_locked?
        Result.new(true, yield)
      elsif timeout_seconds == 0
        yield_with_lock(&block)
      else
        yield_with_lock_and_timeout(&block)
      end
    end

    def stable_hashcode(input)
      if input.is_a? Numeric
        input.to_i
      else
        # Ruby MRI's String#hash is randomly seeded as of Ruby 1.9 so
        # make sure we use a deterministic hash.
        Zlib.crc32(input.to_s)
      end
    end

    def yield_with_lock_and_timeout(&block)
      if lock
        yield_with_acquired_lock(&block)
      else
        FAILED_TO_LOCK
      end
    end

    def yield_with_lock(&block)
      if try_lock
        yield_with_acquired_lock(&block)
      else
        FAILED_TO_LOCK
      end
    end

    # Prevent AR from caching results improperly
    def unique_column_name
      "t#{SecureRandom.hex}"
    end

    private

    def yield_with_acquired_lock
      begin
        lock_stack.push(lock_stack_item)
        result = block_given? ? yield : nil
        Result.new(true, result)
      ensure
        lock_stack.pop
        release_lock
      end
    end

    def lock_via_sleep_loop
      give_up_at = Time.now + timeout_seconds if timeout_seconds
      loop do
        return true if try_lock

        # Randomizing sleep time may help reduce contention.
        sleep(rand(0.05..0.15))

        return false if timeout_seconds && Time.now > give_up_at
      end
    end
  end
end
