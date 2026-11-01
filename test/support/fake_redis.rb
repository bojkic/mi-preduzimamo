# frozen_string_literal: true

# Minimal in-memory Redis double implementing exactly the commands the Viber
# OTP/session stores use (set/get/del/ttl/incr/expire). Keeps the OTP and
# state-machine tests deterministic and Redis-server-independent under the
# parallel test runner. TTLs are recorded but not auto-expired; tests that need
# to exercise expiry backdate the stored payload explicitly.
class FakeRedis
  def initialize
    @data = {}
    @ttls = {}
  end

  # `ex:` mirrors the real Redis#set keyword, so its short name is intentional.
  def set(key, val, ex: nil) # rubocop:disable Naming/MethodParameterName
    @data[key] = val.to_s
    @ttls[key] = ex if ex
    "OK"
  end

  def get(key)
    @data[key]
  end

  # Real Redis#del is variadic and returns the count removed.
  def del(*keys)
    keys.sum do |key|
      @ttls.delete(key)
      @data.delete(key) ? 1 : 0
    end
  end

  def ttl(key)
    return -2 unless @data.has_key?(key)

    @ttls[key] || -1
  end

  def incr(key)
    value = @data[key].to_i + 1
    @data[key] = value.to_s
    value
  end

  def expire(key, ttl)
    return false unless @data.has_key?(key)

    @ttls[key] = ttl
    true
  end

  # OtpStore uses bounded, allowlisted Lua scripts to make OTP replacement and
  # limiter mutations atomic. Model only those exact observable transitions.
  def eval(script, keys:, argv: [])
    store = Decidim::Bih::Viber::OtpStore
    case script
    when store::PUT_SCRIPT
      set(keys.fetch(0), argv.fetch(0), ex: argv.fetch(1).to_i)
      del(keys.fetch(1))
      "OK"
    when store::INCREMENT_COUNTER_SCRIPT
      value = incr(keys.fetch(0))
      expire(keys.fetch(0), argv.fetch(0).to_i) if value == 1
      value
    when store::ROLLBACK_COUNTER_SCRIPT
      key = keys.fetch(0)
      return 0 unless @data.has_key?(key)

      value = @data.fetch(key).to_i - 1
      if value <= 0
        del(key)
        0
      else
        @data[key] = value.to_s
        value
      end
    else
      raise ArgumentError, "unsupported FakeRedis script"
    end
  end
end
