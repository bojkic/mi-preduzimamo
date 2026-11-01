# frozen_string_literal: true

require "open3"

# Checks source identity, not a clean working tree or release approval.
module PublicEngineBinding
  class Invalid < StandardError; end

  module_function

  def verify!(locked_revision:, engine_root:, expected_root: nil)
    raise Invalid, "An exact Git engine revision is required" unless /\A[0-9a-f]{40}\z/.match?(locked_revision.to_s)

    actual_root = File.realpath(engine_root)
    if expected_root && !expected_root.empty? && actual_root != File.realpath(expected_root)
      raise Invalid, "Loaded engine differs from EXPECTED_ENGINE_ROOT"
    end
    output, status = Open3.capture2e("git", "-C", actual_root, "rev-parse", "HEAD")
    raise Invalid, "Loaded engine does not match the locked Git commit" unless status.success? && output.strip == locked_revision

    true
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise Invalid, "Engine checkout or Git is unavailable"
  end
end

if $PROGRAM_NAME == __FILE__
  require "bundler"
  begin
    locked = Bundler.locked_gems.specs.find { |spec| spec.name == "decidim-bih" }
    revision = locked&.source&.respond_to?(:revision) ? locked.source.revision : nil
    PublicEngineBinding.verify!(locked_revision: revision, engine_root: Gem.loaded_specs.fetch("decidim-bih").full_gem_path,
                                expected_root: ENV["EXPECTED_ENGINE_ROOT"])
    puts "Engine binding verified."
  rescue PublicEngineBinding::Invalid, KeyError => error
    warn "Refusing verification: #{error.message}"
    exit 64
  end
end
