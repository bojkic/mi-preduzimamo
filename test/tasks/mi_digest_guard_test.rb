# frozen_string_literal: true

require "test_helper"
require "rake"

# Load the rake tasks through the real Rails path, exactly as `bin/rails <task>`
# does: decidim-core's rake files first (it is a railtie), the host's lib/tasks
# last. Guarded against double-loading like the other task tests — calling
# load_tasks twice re-loads every rake file and appends a second copy of every
# action.
Rails.application.load_tasks unless Rake::Task.task_defined?("decidim:mailers:notifications_digest_daily")

# Tests for lib/tasks/mi_digest_guard.rake.
#
# The point of the guard is ORDER: it has to refuse before Decidim's digest task
# looks up recipients or enqueues anything. A check that runs after the send is
# not protection. These tests prove the ordering three ways — the gate is the
# task's only action and holds the original action object, a disabled run never
# reaches `Decidim::User.where`, and the same inputs that enqueue a digest when
# enabled enqueue nothing when disabled.
class MiDigestGuardTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  DAILY_TASK = "decidim:mailers:notifications_digest_daily"
  WEEKLY_TASK = "decidim:mailers:notifications_digest_weekly"
  GUARDED_TASKS = [DAILY_TASK, WEEKLY_TASK].freeze
  ENABLE_VARIABLE = "MI_DIGEST_ENABLED"
  # The installed decidim-core rake file itself, never a copy. If core stops
  # defining these tasks the guard protects nothing, and this suite has to fail
  # instead of exercising a task the test invented.
  CORE_RAKE_FILE = Pathname.new(Gem.loaded_specs.fetch("decidim-core").gem_dir)
                           .join("lib/tasks/decidim_mailers_tasks.rake")
  HOST_GUARD_RAKE_FILE = Rails.root.join("lib/tasks/mi_digest_guard.rake")

  # Stands in for the two ActiveRecord relations the core action walks, so the
  # task can be driven all the way to `perform_later` without reading or writing
  # a single row. It records what the action asked for, which is how "recipient
  # evaluation never started" is asserted.
  class FakeDigestQuery
    attr_reader :user_scopes, :notification_scopes, :notification_filters

    def initialize(user_ids = [])
      @user_ids = user_ids
      @user_scopes = []
      @notification_scopes = []
      @notification_filters = []
    end

    def record_user_scope(conditions)
      @user_scopes << conditions
      self
    end

    def record_notification_scope(frequency)
      @notification_scopes << frequency
      self
    end

    def find_in_batches
      yield(@user_ids.map { |id| Struct.new(:id).new(id) })
      self
    end

    def where(conditions)
      @notification_filters << conditions
      self
    end

    def select(*)
      self
    end

    def distinct
      self
    end

    def pluck(*)
      @user_ids
    end
  end

  setup do
    @original_enable_value = ENV.fetch(ENABLE_VARIABLE, :unset)
    ENV.delete(ENABLE_VARIABLE)
    reenable_guarded_tasks
  end

  teardown do
    if @original_enable_value == :unset
      ENV.delete(ENABLE_VARIABLE)
    else
      ENV[ENABLE_VARIABLE] = @original_enable_value
    end
    reenable_guarded_tasks
  end

  test "decidim-core still defines both digest tasks with a single action each" do
    assert_path_exists CORE_RAKE_FILE

    with_isolated_rake_application do |application|
      Rake::Task.define_task(:environment)
      load CORE_RAKE_FILE.to_s

      GUARDED_TASKS.each do |name|
        task = application.lookup(name)

        assert task, "#{name} is not defined by #{CORE_RAKE_FILE}"
        assert_equal 1, task.actions.size, "#{name} no longer has exactly one action"
        assert_equal ["environment"], task.prerequisites
      end
    end
  end

  test "guarding replaces the core action instead of appending after it" do
    with_isolated_rake_application do |application|
      Rake::Task.define_task(:environment)
      load CORE_RAKE_FILE.to_s
      core_actions = GUARDED_TASKS.index_with { |name| application.lookup(name).actions.dup }

      load_host_guard

      GUARDED_TASKS.each do |name|
        actions = application.lookup(name).actions

        assert_equal 1, actions.size, "#{name} must be left with the gate as its only action"
        gate = actions.first

        assert_instance_of MiDigestGuard::Gate, gate
        # The very action object core defined, now reachable only from inside
        # the gate's enabled branch.
        assert_same core_actions.fetch(name).first, gate.guarded_actions.first
        assert_equal 1, gate.guarded_actions.size
      end
    end
  end

  test "the guard is installed on the real rake application the same way" do
    GUARDED_TASKS.each do |name|
      actions = Rake::Task[name].actions

      assert_equal 1, actions.size, "#{name} must be left with the gate as its only action"
      assert_instance_of MiDigestGuard::Gate, actions.first
      assert_equal 1, actions.first.guarded_actions.size
      assert_not_instance_of MiDigestGuard::Gate, actions.first.guarded_actions.first
    end
  end

  test "installing twice leaves one gate and never an unguarded action" do
    with_isolated_rake_application do |application|
      Rake::Task.define_task(:environment)
      load CORE_RAKE_FILE.to_s
      load_host_guard

      MiDigestGuard.install!(application: application)

      GUARDED_TASKS.each do |name|
        actions = application.lookup(name).actions

        assert_equal 1, actions.size
        assert_equal 1, actions.first.guarded_actions.size
      end

      # A second `load_tasks` would re-run the core rake file and append a
      # second, unguarded copy of its action. Re-installing has to swallow it.
      load CORE_RAKE_FILE.to_s
      MiDigestGuard.install!(application: application)

      GUARDED_TASKS.each do |name|
        actions = application.lookup(name).actions

        assert_equal 1, actions.size
        assert_equal 2, actions.first.guarded_actions.size
        assert_not(actions.first.guarded_actions.any? { |action| action.is_a?(MiDigestGuard::Gate) })
      end
    end
  end

  test "install! refuses to report a missing core task as guarded" do
    with_isolated_rake_application do |application|
      Rake::Task.define_task(:environment)

      error = assert_raises(MiDigestGuard::MissingTaskError) do
        MiDigestGuard.install!(application: application)
      end

      GUARDED_TASKS.each { |name| assert_includes error.message, name }
    end
  end

  test "every value other than 1 stops the task before recipient evaluation" do
    [:unset, "", "0", "true", "yes", "11"].each do |value|
      GUARDED_TASKS.each do |name|
        value == :unset ? ENV.delete(ENABLE_VARIABLE) : ENV[ENABLE_VARIABLE] = value
        Rake::Task[name].reenable
        query = FakeDigestQuery.new([42])
        stderr = nil

        assert_no_enqueued_jobs do
          assert_no_emails do
            _stdout, stderr = capture_io { drive(query) { Rake::Task[name].invoke } }
          end
        end

        assert_empty query.user_scopes,
                     "#{name} evaluated recipients with #{ENABLE_VARIABLE}=#{value.inspect}"
        assert_empty query.notification_scopes
        assert_includes stderr, "BLOCKED"
        assert_includes stderr, name
      end
    end
  end

  test "MI_DIGEST_ENABLED=1 runs the core action exactly once and it does enqueue" do
    ENV[ENABLE_VARIABLE] = "1"

    { DAILY_TASK => :daily, WEEKLY_TASK => :weekly }.each do |name, frequency|
      Rake::Task[name].reenable
      query = FakeDigestQuery.new([42])

      assert_enqueued_jobs 1, only: Decidim::EmailNotificationsDigestGeneratorJob do
        drive(query) { Rake::Task[name].invoke }
      end

      assert_equal [{ notifications_sending_frequency: frequency }], query.user_scopes
      assert_equal [frequency], query.notification_scopes
      assert_equal [{ decidim_user_id: [42] }], query.notification_filters
    end
  end

  test "a direct execute, which skips prerequisites, is guarded as well" do
    query = FakeDigestQuery.new([42])

    assert_no_enqueued_jobs do
      capture_io { drive(query) { Rake::Task[DAILY_TASK].execute } }
    end
    assert_empty query.user_scopes

    ENV[ENABLE_VARIABLE] = "1"
    enabled_query = FakeDigestQuery.new([42])

    assert_enqueued_jobs 1, only: Decidim::EmailNotificationsDigestGeneratorJob do
      drive(enabled_query) { Rake::Task[DAILY_TASK].execute }
    end
    assert_equal 1, enabled_query.user_scopes.size
  end

  test "repeated invocation and reenable keep going through the guard" do
    query = FakeDigestQuery.new([42])

    assert_no_enqueued_jobs do
      capture_io do
        drive(query) do
          Rake::Task[DAILY_TASK].invoke
          Rake::Task[DAILY_TASK].invoke
          Rake::Task[DAILY_TASK].reenable
          Rake::Task[DAILY_TASK].invoke
        end
      end
    end
    assert_empty query.user_scopes

    ENV[ENABLE_VARIABLE] = "1"
    Rake::Task[DAILY_TASK].reenable
    enabled_query = FakeDigestQuery.new([42])

    assert_enqueued_jobs 2, only: Decidim::EmailNotificationsDigestGeneratorJob do
      drive(enabled_query) do
        Rake::Task[DAILY_TASK].invoke
        # Without the reenable rake would treat the task as already invoked.
        Rake::Task[DAILY_TASK].invoke
        Rake::Task[DAILY_TASK].reenable
        Rake::Task[DAILY_TASK].invoke
      end
    end
    assert_equal 2, enabled_query.user_scopes.size
  end

  private

  def reenable_guarded_tasks
    GUARDED_TASKS.each { |name| Rake::Task[name].reenable if Rake::Task.task_defined?(name) }
  end

  # Runs the block with a throwaway Rake application in place, so tasks loaded
  # for a test never reach the real one. `:environment` is defined as an empty
  # task because `invoke` resolves prerequisites — it is Rails plumbing, never a
  # stand-in for the digest tasks themselves, which are always the real ones
  # loaded from the installed decidim-core file.
  def with_isolated_rake_application
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    yield Rake.application
  ensure
    Rake.application = previous_application
  end

  # Re-running the guard file re-opens its module, which Ruby warns about for
  # every constant. The warnings are an artefact of loading it more than once in
  # one process, not of the file.
  def load_host_guard
    silence_warnings { load HOST_GUARD_RAKE_FILE.to_s }
  end

  # Points the core action's two relations at the recorder above.
  def drive(query)
    user_scope = ->(*args, **kwargs) { query.record_user_scope(kwargs.presence || args.first) }

    Decidim::User.stub(:where, user_scope) do
      Decidim::Notification.stub(:daily, ->(*) { query.record_notification_scope(:daily) }) do
        Decidim::Notification.stub(:weekly, ->(*) { query.record_notification_scope(:weekly) }) do
          yield
        end
      end
    end
  end
end
