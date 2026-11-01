# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class KomsilukNameMarkerRemovalTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @mz = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-janja", name: { "sr" => "Janja" })
        @removal = KomsilukNameMarkerRemoval.new(organization: @organization)
      end

      test "the marker goes and the name itself is untouched" do
        area = komsiluk("komsiluk-1", { "sr" => "Dazdarevo (prijedlog)", "bs" => "Dazdarevo (prijedlog)" })

        result = @removal.call(apply: true)

        assert_equal ["komsiluk-1"], result.renamed
        assert_equal({ "sr" => "Dazdarevo", "bs" => "Dazdarevo" }, area.reload.name)
      end

      test "a confirmed name is left completely alone" do
        area = komsiluk("komsiluk-2", { "sr" => "Janja" })

        assert_empty @removal.call(apply: true).renamed
        assert_equal({ "sr" => "Janja" }, area.reload.name)
      end

      test "every spelling the operators used is recognised" do
        cyrillic = komsiluk("komsiluk-3", { "sr" => "Даздарево (приједлог)" })
        bare = komsiluk("komsiluk-4", { "sr" => "Ostojićevo prijedlog" })

        @removal.call(apply: true)

        assert_equal "Даздарево", cyrillic.reload.name.fetch("sr")
        assert_equal "Ostojićevo", bare.reload.name.fetch("sr")
      end

      test "a name that is nothing but the marker is reported, never blanked" do
        area = komsiluk("komsiluk-5", { "sr" => "(prijedlog)" })

        result = @removal.call(apply: true)

        assert_equal ["komsiluk-5"], result.skipped
        assert_equal({ "sr" => "(prijedlog)" }, area.reload.name)
      end

      test "a dry run writes nothing and a second apply is a no-op" do
        area = komsiluk("komsiluk-6", { "sr" => "Dazdarevo (prijedlog)" })

        assert_equal ["komsiluk-6"], @removal.call.renamed
        assert_equal({ "sr" => "Dazdarevo (prijedlog)" }, area.reload.name)

        @removal.call(apply: true)

        assert_empty @removal.call(apply: true).renamed
      end

      private

      def komsiluk(slug, name)
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug:, name:,
                                        parent: @mz, primary_mz_slug: "mz-janja", overlapping_mz_slugs: ["mz-janja"])
      end
    end
  end
end
