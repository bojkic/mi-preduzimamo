# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class LevelsTest < ActiveSupport::TestCase
        test "maps contribution scores to the right level" do
          assert_equal "komsija", Levels.for(0).key
          assert_equal "komsija", Levels.for(49).key
          assert_equal "aktivista", Levels.for(50).key
          assert_equal "predvodnik", Levels.for(200).key
          assert_equal "ambasador", Levels.for(600).key
          assert_equal "heroj", Levels.for(1500).key
          assert_equal "heroj", Levels.for(99_999).key
        end

        test "computes points to the next level (nil at the top)" do
          assert_equal 50, Levels.for(0).points_to_next
          assert_equal 20, Levels.for(180).points_to_next
          assert_nil Levels.for(2000).points_to_next
        end

        test "blank or negative score floors to the first level" do
          assert_equal "komsija", Levels.for(nil).key
          assert_equal "komsija", Levels.for(-5).key
        end

        test "title follows the request locale" do
          I18n.with_locale(:en) { assert_equal "Activist", Levels.for(100).title }
        end
      end
    end
  end
end
