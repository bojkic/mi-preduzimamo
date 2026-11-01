# frozen_string_literal: true

# Blocks Decidim's notification-digest rake tasks unless they are enabled on
# purpose, for this invocation, by the operator running them.
#
# WHY. `core:lib/tasks/decidim_mailers_tasks.rake` defines
# `decidim:mailers:notifications_digest_daily` and `..._weekly`. Each one loads
# every `Decidim::User` whose `notifications_sending_frequency` is `daily` /
# `weekly` and enqueues a `Decidim::EmailNotificationsDigestGeneratorJob` per
# user with pending notifications. Nothing on this deployment schedules them —
# they are in no cron manifest and no crontab — yet roughly ninety production
# accounts still carry a `daily`/`weekly` frequency that nobody on this platform
# deliberately chose. Adding one cron line, or typing the task name once, would
# mail all of them. The frequencies themselves are not rewritten here: this
# guard only stops the dispatch side, and it is reversible per invocation.
#
# HOW. `MiDigestGuard.install!` takes each guarded task's own actions out of the
# task and puts them inside a `Gate`, which becomes the task's ONLY action. The
# original action is therefore unreachable except from inside the gate, on the
# enabled branch: `Rake::Task#execute` runs `@actions.each { |act| act.call(...) }`
# (rake 13.4.2, `lib/rake/task.rb:270-283`), so the check cannot run after the
# send. This is deliberately not `Rake::Task#enhance`, which APPENDS an action —
# an enhanced guard would abort after the digest had already been enqueued.
# Both `Rake::Task#invoke` (which first runs the `:environment` prerequisite)
# and a direct `Rake::Task#execute` go through the same `@actions` list, so both
# entry points are covered, as is any number of `reenable` + `invoke` rounds.
#
# BOUNDARY. This guard is task-level, not worker-level. It stops the two rake
# tasks from evaluating recipients and enqueueing. It does NOT intercept
# `Decidim::EmailNotificationsDigestGeneratorJob` itself: a job already in the
# queue, or one enqueued from elsewhere (console, another task), still runs.
# There is no such producer today because nothing schedules the tasks.
#
# ENABLE / DISABLE. `MI_DIGEST_ENABLED=1` — and only the exact string "1" —
# runs the task. Unset, "0", "true", "yes" or anything else blocks it. It is
# read from the environment of the rake process at the moment the action runs,
# so it applies to that one invocation and needs no restart or deploy:
#
#     MI_DIGEST_ENABLED=1 bin/rails decidim:mailers:notifications_digest_daily
module MiDigestGuard
  # The core task names this guard refuses to leave unprotected.
  GUARDED_TASK_NAMES = %w(
    decidim:mailers:notifications_digest_daily
    decidim:mailers:notifications_digest_weekly
  ).freeze

  ENABLE_VARIABLE = "MI_DIGEST_ENABLED"
  ENABLE_VALUE = "1"

  # Raised when a task this guard is supposed to protect is not defined at
  # install time. That means the digest tasks are NOT guarded — either the core
  # task was renamed/removed by an upgrade, or the host's `lib/tasks` were
  # loaded before `decidim-core`'s. Both are failed integrations, and both are
  # reported loudly rather than silently leaving the dispatch path open.
  class MissingTaskError < StandardError; end

  # The single action each guarded task is left with. Holds the task's original
  # actions and calls them only when the guard is enabled.
  class Gate
    attr_reader :task_name, :guarded_actions

    def initialize(task_name, guarded_actions)
      @task_name = task_name
      @guarded_actions = guarded_actions
    end

    # Rake calls each action with (task, args), and with keyword arguments too
    # when the task was invoked with named arguments. Forward both unchanged so
    # the original action sees exactly what rake would have handed it.
    def call(task, args = nil, **opts)
      return MiDigestGuard.refuse(task_name) unless MiDigestGuard.enabled?

      guarded_actions.each { |action| action.call(task, args, **opts) }
    end
  end

  def self.enabled?
    ENV.fetch(ENABLE_VARIABLE, nil) == ENABLE_VALUE
  end

  # Wraps every named task. Idempotent: installing twice re-wraps the same
  # original actions instead of nesting gates or dropping them.
  def self.install!(task_names = GUARDED_TASK_NAMES, application: Rake.application)
    missing = task_names.reject { |name| application.lookup(name) }

    unless missing.empty?
      raise MissingTaskError,
            "#{ENABLE_VARIABLE} guard could not be installed: #{missing.join(", ")} " \
            "#{missing.one? ? "is" : "are"} not defined. The notification digest dispatch " \
            "is unguarded. Check that decidim-core still defines these tasks and that its " \
            "rake files load before the host's lib/tasks."
    end

    task_names.map { |name| gate(application[name]) }
  end

  # Takes the task's actions out of the task and hides them behind a Gate.
  def self.gate(task)
    originals = task.actions.flat_map do |action|
      action.is_a?(Gate) ? action.guarded_actions : [action]
    end

    Gate.new(task.name, originals).tap { |gate| task.actions.replace([gate]) }
  end

  def self.refuse(task_name)
    warn <<~MESSAGE
      [mi] BLOCKED: #{task_name} did not run. No digest recipients were looked up,
      [mi] and no digest email was enqueued or sent.
      [mi] Nothing schedules notification digests on this deployment, and accounts still
      [mi] carry daily/weekly frequencies nobody deliberately chose — an unguarded run
      [mi] would mail all of them.
      [mi] To run it on purpose:  #{ENABLE_VARIABLE}=#{ENABLE_VALUE} bin/rails #{task_name}
    MESSAGE

    nil
  end
end

MiDigestGuard.install!
