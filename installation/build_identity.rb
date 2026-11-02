# frozen_string_literal: true

require "bundler"
require "digest"
require "json"
require "open3"
require "rubygems/package"
require "stringio"

app = ENV.fetch("MI_APP_BUILD_REVISION")
abort "Exact app revision required" unless app.match?(/\A[0-9a-f]{40}\z/)
abort "Local Bundler override refused" unless Bundler.settings.local_overrides.empty?
lock = Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock"))
expected = lock.specs.find { |spec| spec.name == "decidim-bih" }.source.revision
spec = Bundler.load.specs.find { |entry| entry.name == "decidim-bih" }
abort "Engine source is not locked Git" unless spec.source.is_a?(Bundler::Source::Git) && spec.source.revision == expected
path = spec.full_gem_path
archive, _, status = Open3.capture3("git", "-C", path, "archive", expected)
abort "Engine Git provenance unavailable" unless status.success?
engine_files = {}
Gem::Package::TarReader.new(StringIO.new(archive)) do |tar|
  tar.each do |entry|
    next unless entry.file?

    name = entry.full_name
    actual = File.join(path, name)
    abort "Engine source file missing" unless File.file?(actual) && !File.symlink?(actual)
    content = entry.read
    # Bundler legitimately generates its installation gemspec stub. Record the
    # installed bytes separately; every other tracked engine byte must match Git.
    abort "Engine source differs from locked Git" unless name == "decidim-bih.gemspec" || Digest::SHA256.file(actual).hexdigest == Digest::SHA256.hexdigest(content)
    engine_files[name] = Digest::SHA256.file(actual).hexdigest
  end
end
app_files = {}
Dir.glob("{app,config,db,lib,installation}/**/*").each do |name|
  next unless File.file?(name) && name != "installation/build-identity.json"

  app_files[name] = Digest::SHA256.file(name).hexdigest
end
manifest = { app_sha: app, engine_sha: expected, lock_sha256: Digest::SHA256.file("Gemfile.lock").hexdigest, engine_files:, app_files:,
             boundary: "Engine matches exact locked Git except Bundler-generated gemspec; recorded installed bytes verified at runtime" }
File.write("installation/build-identity.json", "#{JSON.pretty_generate(manifest)}\n")
puts "build_identity=recorded"
