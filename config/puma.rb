# frozen_string_literal: true

# Puma config for Decidim (production: unix socket + cluster workers; dev: port 3000)
max_threads = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads max_threads, max_threads

rails_env = ENV.fetch("RAILS_ENV", "development")
environment rails_env

app_dir = File.expand_path("..", __dir__)

if rails_env == "production"
  # Ensure runtime dirs exist before binding. Git does not track empty
  # directories, so a `git reset`/`git clean` of shared/ can wipe
  # shared/sockets and leave Puma unable to bind its socket — taking the
  # site down at the next boot (happened 2026-06-22). Recreate defensively.
  require "fileutils"
  %w(sockets pids log).each { |dir| FileUtils.mkdir_p("#{app_dir}/shared/#{dir}") }

  workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
  preload_app!
  bind "unix://#{app_dir}/shared/sockets/puma.sock"
  pidfile "#{app_dir}/shared/pids/puma.pid"
  state_path "#{app_dir}/shared/pids/puma.state"
  stdout_redirect "#{app_dir}/shared/log/puma.stdout.log", "#{app_dir}/shared/log/puma.stderr.log", true
  on_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  end
else
  port ENV.fetch("PORT", 3000)
end

plugin :tmp_restart
