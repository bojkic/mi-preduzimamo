# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require "uri"

# Validate the final child environment AFTER task-env loading and BEFORE any DB
# preparation or tests. No Rails, Bundler, environment sourcing or DB connection.
# API: MiTestGuard.validate!(env: ENV) -> credential-free Hash; raises Invalid.
# CLI: ruby script/lib/mi_test_guard.rb -> JSON / exit 0; rejection -> exit 2.
# This guard rejects overrides; it never silently scrubs or mutates the caller.
module MiTestGuard
  class Invalid < StandardError; end

  LIVE_ROOTS = %w(/home/deploy/decidim_app /home/deploy/decidim-bih).freeze
  DISCOVERY_KEYS = %w(DEFAULT_TEST DEFAULT_TEST_EXCLUDE TEST).freeze
  OPTION_KEYS = %w(TESTOPTS TESTOPT TEST_OPTS TEST_OPT MINITEST_OPTS).freeze
  DATABASE_NAME = /\A[a-zA-Z0-9_]+_test[_-][a-zA-Z0-9_][a-zA-Z0-9_-]*\z/
  SUFFIX = /\A[_-][a-zA-Z0-9_][a-zA-Z0-9_-]*\z/

  module_function

  def validate!(env: ENV)
    roots = validate_roots!(env)
    validate_filters!(env)
    %w(RAILS_ENV RACK_ENV).each do |key|
      raise Invalid, "#{key} must be test or unset" if env.has_key?(key) && env[key] != "test"
    end
    roots.merge("database" => effective_database!(env))
  end

  def validate_roots!(env)
    forbidden = forbidden_live_roots(env)
    roots = %w(APP_ROOT ENGINE_ROOT).to_h { |key| [key.downcase, git_root!(env[key], key, forbidden)] }
    raise Invalid, "APP_ROOT and ENGINE_ROOT must be distinct, nonoverlapping roots" if overlap?(roots.fetch("app_root"), roots.fetch("engine_root"))

    roots
  end

  def forbidden_live_roots(env)
    (LIVE_ROOTS + %w(LIVE_APP_ROOT LIVE_ENGINE_ROOT).filter_map { |key| env[key] }).flat_map do |path|
      raise Invalid, "live root must be an absolute path" unless path.start_with?("/")

      # Keep lexical protection even when a configured live root is unavailable.
      [File.expand_path(path), live_realpath(path)]
    end.uniq
  end

  def live_realpath(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path)
  end

  def git_root!(path, key, forbidden)
    raise Invalid, "#{key} must name an explicit absolute Git root" unless path.to_s.start_with?("/")

    root = File.realpath(path)
    raise Invalid, "#{key} overlaps a live root" if forbidden.any? { |live| overlap?(root, live) || overlap?(File.expand_path(path), live) }
    raise Invalid, "#{key} must be a directory" unless File.directory?(root)

    git_env = ENV.keys.grep(/\AGIT_/).zip([]).to_h
    output, _error, status = Open3.capture3(git_env, "git", "-C", root, "rev-parse", "--show-toplevel")
    raise Invalid, "#{key} must be an exact Git root" unless status.success? && output.strip == root

    root
  rescue SystemCallError
    raise Invalid, "test repository root unavailable"
  end

  def overlap?(left, right)
    left == right || left.start_with?("#{right.delete_suffix("/")}/") || right.start_with?("#{left.delete_suffix("/")}/")
  end

  def validate_filters!(env)
    # Empty strings still override Rails/Rake defaults, and can select zero tests.
    DISCOVERY_KEYS.each do |key|
      raise Invalid, "#{key} overrides test discovery; unset it" if env.has_key?(key)
    end
    OPTION_KEYS.each { |key| seed_options!(key, env[key].to_s) }
    raise Invalid, "SEED must be a nonnegative integer" if env.has_key?("SEED") && !env["SEED"].to_s.match?(/\A\d+\z/)
  end

  def seed_options!(key, value)
    args = Shellwords.split(value)
    until args.empty?
      option = args.shift
      next if option.match?(/\A--seed=\d+\z/) || option.match?(/\A-s\d+\z/)
      next if %w(--seed -s).include?(option) && args.shift.to_s.match?(/\A\d+\z/)

      raise Invalid, "#{key} permits seed arguments only; unset test filters"
    end
  rescue ArgumentError
    raise Invalid, "malformed test options"
  end

  # Safe to call before Rails in focused tests: no roots, suffix or filter checks.
  # Returns true when both named URLs are absent/empty; otherwise raises Invalid.
  def reject_named_database_urls!(env)
    # Rails named-connection URLs can override DATABASE_URL/config/database.yml.
    %w(PRIMARY_DATABASE_URL TEST_DATABASE_URL).each do |key|
      raise Invalid, "#{key} is not supported; use DATABASE_URL" unless env[key].to_s.empty?
    end
    true
  end

  def effective_database!(env)
    reject_named_database_urls!(env)
    url = env["DATABASE_URL"]
    return database_from_url!(url) unless url.to_s.empty?

    suffix = env["TEST_ENV_NUMBER"].to_s
    raise Invalid, "TEST_ENV_NUMBER must be a nonempty isolated suffix beginning with _ or -" unless SUFFIX.match?(suffix)
    raise Invalid, "DATABASE_USERNAME is required without DATABASE_URL" if env["DATABASE_USERNAME"].to_s.strip.empty?

    isolated_database!("decidim_app_test#{suffix}")
  end

  def database_from_url!(url)
    uri = URI.parse(url)
    raise Invalid, "DATABASE_URL must use postgres or postgresql" unless %w(postgres postgresql).include?(uri.scheme) && !uri.opaque
    raise Invalid, "DATABASE_URL fragments are forbidden" if uri.fragment
    raise Invalid, "DATABASE_URL must name one isolated test database" unless uri.path&.start_with?("/")

    validate_query!(uri.query)
    # Decode exactly once, as Rails does. A decoded slash, NUL, URI, conninfo or
    # another percent escape cannot pass the database-name allowlist.
    isolated_database!(URI::DEFAULT_PARSER.unescape(uri.path.delete_prefix("/")))
  rescue URI::Error, ArgumentError
    # Never include a URL, username, password or parser exception in errors.
    raise Invalid, "invalid DATABASE_URL"
  end

  def validate_query!(raw)
    query = URI.decode_www_form(raw.to_s)
    keys = query.map(&:first)
    raise Invalid, "DATABASE_URL query permits only unique host/port keys" unless (keys - %w(host port)).empty? && keys.uniq == keys

    query.each do |key, value|
      if key == "port"
        raise Invalid, "DATABASE_URL query port is invalid" unless value.match?(/\A\d+\z/) && (1..65_535).cover?(value.to_i)
      else
        raise Invalid, "DATABASE_URL query host is invalid" unless value.match?(%r{\A[a-zA-Z0-9_./:\[\]-]+\z})
      end
    end
  end

  def isolated_database!(name)
    raise Invalid, "database must have an isolated _test_ or _test- suffix (maximum 63 bytes)" unless name.bytesize <= 63 && DATABASE_NAME.match?(name)

    name
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise MiTestGuard::Invalid, "usage: ruby script/lib/mi_test_guard.rb (configuration via environment)" unless ARGV.empty?

    puts JSON.generate(MiTestGuard.validate!)
  rescue MiTestGuard::Invalid => e
    warn "mi_test_guard: #{e.message}"
    exit 2
  end
end
