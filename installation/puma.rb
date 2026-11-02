# frozen_string_literal: true
# Container process logs to stdout; systemd host configuration stays separate.
threads ENV.fetch("RAILS_MAX_THREADS", 3).to_i, ENV.fetch("RAILS_MAX_THREADS", 3).to_i
workers ENV.fetch("WEB_CONCURRENCY", 0).to_i
environment ENV.fetch("RAILS_ENV", "production")
bind "tcp://0.0.0.0:3000"
pidfile "/app/tmp/pids/puma.pid"
