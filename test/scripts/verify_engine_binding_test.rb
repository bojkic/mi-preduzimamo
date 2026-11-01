# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../script/verify_engine_binding"

class OpenSourceEngineBindingTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("public-engine-binding-")
    git("init", "-q")
    File.write(File.join(@root, "engine.rb"), "# authored test\n")
    git("add", ".")
    git("-c", "user.name=Synthetic Maintainer", "-c", "user.email=maintainer@example.invalid", "commit", "-qm", "Authored test")
    @revision = git("rev-parse", "HEAD").strip
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_exact_checkout_and_expected_root_pass
    assert PublicEngineBinding.verify!(locked_revision: @revision, engine_root: @root, expected_root: @root)
  end

  def test_wrong_engine_commit_rejects_even_when_expected_path_matches
    assert_raises(PublicEngineBinding::Invalid) { PublicEngineBinding.verify!(locked_revision: "0" * 40, engine_root: @root, expected_root: @root) }
  end

  def test_wrong_expected_root_rejects_even_when_commit_matches
    Dir.mktmpdir("other-public-engine-") do |other|
      assert_raises(PublicEngineBinding::Invalid) { PublicEngineBinding.verify!(locked_revision: @revision, engine_root: @root, expected_root: other) }
    end
  end

  def test_missing_or_symbolic_revision_is_not_an_exact_pin
    [nil, "", "main", "HEAD", "a" * 39].each do |revision|
      assert_raises(PublicEngineBinding::Invalid) { PublicEngineBinding.verify!(locked_revision: revision, engine_root: @root) }
    end
  end

  def test_dirty_development_files_do_not_claim_a_clean_release
    File.write(File.join(@root, "engine.rb"), "# uncommitted developer edit\n")
    assert PublicEngineBinding.verify!(locked_revision: @revision, engine_root: @root)
  end

  def test_non_git_directory_is_rejected
    Dir.mktmpdir("not-engine-checkout-") do |other|
      assert_raises(PublicEngineBinding::Invalid) { PublicEngineBinding.verify!(locked_revision: @revision, engine_root: other) }
    end
  end

  private

  def git(*args)
    output, status = Open3.capture2e({ "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null" }, "git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-C", @root, *args)
    raise "Fixture Git command failed" unless status.success?

    output
  end
end
