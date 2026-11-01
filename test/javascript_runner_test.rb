# frozen_string_literal: true

require "test_helper"
require "open3"

# test/javascript holds a node:test suite that nothing ran.
#
# `bin/rails test` collects Ruby files only, so the coverage of
# public/mi/mi-install.js — the PWA install prompt that ships to every
# citizen's browser — was checked by hand, i.e. never. A test suite no command
# runs is not coverage; it is a file that agrees with whatever the code says.
#
# So the Ruby suite shells out to node. When node is missing the test SKIPS with
# a message that names the fix, rather than passing quietly and letting the same
# gap reopen on a machine without Node installed.
class JavascriptRunnerTest < ActiveSupport::TestCase
  SUITE_DIR = "test/javascript"

  test "the node:test suite under test/javascript passes" do
    skip("node is not on PATH — install Node 22.x (see CLAUDE.md) to run #{SUITE_DIR}") unless node_available?

    # The file list is expanded here rather than handed to node as a directory
    # or a glob: which of those a given node build accepts has moved between
    # releases (22.22 rejects the directory), and a misread argument fails in a
    # way that looks like a broken test rather than a broken invocation.
    stdout, stderr, status = Open3.capture3("node", "--test", *suite_files, chdir: Rails.root.to_s)

    assert status.success?,
           "`node --test #{SUITE_DIR}/*_test.js` failed:\n#{stdout}\n#{stderr}"
  end

  test "the node:test suite is not empty" do
    # A runner that runs nothing is the same false green as no runner at all.
    assert_not_empty suite_files,
                     "#{SUITE_DIR} has no *_test.js files — the runner above would pass on nothing"
  end

  private

  def suite_files
    Rails.root.glob("#{SUITE_DIR}/**/*_test.js").map(&:to_s)
  end

  def node_available?
    _stdout, _stderr, status = Open3.capture3("node", "--version")
    status.success?
  rescue Errno::ENOENT
    false
  end
end
