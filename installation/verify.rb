# frozen_string_literal: true

require "bundler"
require "digest"
require "json"

abort "Local Bundler override refused" unless Bundler.settings.local_overrides.empty?
identity = JSON.parse(Rails.root.join("installation/build-identity.json").read)
abort "Expected installation identity arguments required" unless ARGV.length == 3
abort "Unexpected app build revision" unless identity.fetch("app_sha") == ARGV[0]
abort "Unexpected engine build revision" unless identity.fetch("engine_sha") == ARGV[1]
abort "Unexpected build lockfile" unless identity.fetch("lock_sha256") == ARGV[2]
lock = Bundler::LockfileParser.new(Bundler.read_file(Rails.root.join("Gemfile.lock")))
expected = lock.specs.find { |spec| spec.name == "decidim-bih" }.source.revision
spec = Bundler.load.specs.find { |entry| entry.name == "decidim-bih" }
abort "Wrong engine provenance" unless spec.source.is_a?(Bundler::Source::Git) && spec.source.revision == expected && identity.fetch("engine_sha") == expected
abort "Lockfile changed" unless Digest::SHA256.file(Rails.root.join("Gemfile.lock")).hexdigest == identity.fetch("lock_sha256")
[[spec.full_gem_path, identity.fetch("engine_files")], [Rails.root.to_s, identity.fetch("app_files")]].each do |root, files|
  files.each do |name, digest|
    path = File.join(root, name)
    abort "Runtime source changed" unless File.file?(path) && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == digest
  end
end
abort "Legacy authorization adapter loaded" unless Decidim::Verifications::ConfirmUserAuthorization.instance_method(:initialize).arity == 2
abort "DB unavailable" unless ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1
abort "App DB role must not be superuser" unless ActiveRecord::Base.connection.select_value("SELECT rolsuper FROM pg_roles WHERE rolname = current_user") == false
abort "Wrong installation/database identity" unless ActiveRecord::Base.connection_pool.internal_metadata["mi_installation_id"] == ENV.fetch("MI_INSTALL_ID")
abort "Redis unavailable" unless Redis.new(url: ENV.fetch("REDIS_URL")).ping == "PONG"
abort "Wrong queue adapter" unless ActiveJob::Base.queue_adapter.class.name.include?("Sidekiq")
profile = ENV.fetch("MI_INSTALL_PROFILE")
{ "00_profile.rb" => "mi_demo_profile.rb", "10_phone_capture.rb" => "mi_demo_phone_capture.rb" }.each do |source, initializer|
  target = Rails.root.join("config/initializers", initializer)
  if profile == "demo"
    unless File.file?(target) && Digest::SHA256.file(target).hexdigest == identity.fetch("app_files").fetch("installation/demo/#{source}")
      abort "Demo initializer differs from recorded source"
    end
  elsif File.exist?(target)
    abort "Demo initializer present in production image"
  end
end
phone_delivery = profile == "demo" ? "local_simulation_or_disabled; not provider readiness" : "provider_not_verified"
puts JSON.generate(status: "passed", profile:, app_sha: identity.fetch("app_sha"), engine_sha: expected, lock_sha256: identity.fetch("lock_sha256"),
                   organizations: Decidim::Organization.count, database: "connected_non_superuser", redis: "PONG", phone_delivery:)
