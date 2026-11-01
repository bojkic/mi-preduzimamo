# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # The MI cells and goodwill surfaces render RemixIcons that Decidim 0.31 only
    # shows if they are present in the registry. They are registered in the
    # engine's after_initialize (after core/decidim_awesome) so the names they
    # also own do not trip an "already registered" deprecation.
    class MiIconsTest < ActiveSupport::TestCase
      Decidim::Bih::Engine::MI_ICONS.each do |name, _description|
        test "the '#{name}' icon is registered for rendering" do
          assert Decidim.icons.all.has_key?(name), "#{name} must be in the icon registry"
        end
      end
    end
  end
end
