# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

env = ENV["RAILS_ENV"] || "development"
evaluation_without_bootsnap = env == "test" && ENV["MILICA_EVALUATION_DISABLE_BOOTSNAP"] == "1"

unless evaluation_without_bootsnap
  require "bootsnap"

  Bootsnap.setup(
    cache_dir: ENV.fetch("BOOTSNAP_CACHE_DIR") { File.expand_path(File.join("..", "tmp", "cache"), __dir__) },
    development_mode: env == "development",
    load_path_cache: true,
    compile_cache_iseq: !ENV["SIMPLECOV"],
    compile_cache_yaml: true
  )
end
