# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

class PublicConciergeActivationTest < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  OVERLAY = File.join(REPO, "script/open_source/overlays/app")
  ROOT = File.directory?(OVERLAY) ? OVERLAY : REPO

  def configured(value)
    script = <<~RUBY
      require "json"
      module Rails
        def self.application = self
        def self.config = self
        def self.to_prepare(&block) = block.call
      end
      module Decidim
        module Bih
          class << self; attr_accessor :concierge_resolver; end
        end
      end
      require #{File.join(ROOT, "config/initializers/decidim_bih_concierge.rb").inspect}
      resolver = Decidim::Bih.concierge_resolver
      lazy = resolver.is_a?(Proc)
      # Host code need not exist during initializer execution.
      module DecidimApp
        module Bijeljina
          module WebConcierge; end
        end
      end
      puts JSON.generate(enabled: !resolver.nil?, lazy: lazy, resolved: resolver && resolver.call.name)
    RUBY
    output, errors, status = Open3.capture3({ "MI_ENABLE_REFERENCE_CONCIERGE" => value }, RbConfig.ruby, "-e", script)
    assert status.success?, errors
    JSON.parse(output)
  end

  def test_missing_false_and_nonexact_values_leave_reference_adapter_disabled
    [nil, "false", "1", "TRUE"].each do |value|
      assert_equal({ "enabled" => false, "lazy" => false, "resolved" => nil }, configured(value))
    end
  end

  def test_explicit_true_installs_only_a_lazy_host_resolver
    assert_equal({ "enabled" => true, "lazy" => true, "resolved" => "DecidimApp::Bijeljina::WebConcierge" }, configured("true"))
  end
end
