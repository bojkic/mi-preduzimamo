# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Komsiluk
      # R22 — the bot/web write-path that turns a message into a moderated
      # KomsilukPost (same model, points, daily cap).
      class PostCreatorTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @komsiluk = LocalArea.create!(organization: @organization, kind: "komsiluk",
                                        slug: "k-pc", name: { "sr" => "K" })
        end

        def creator
          PostCreator.new(organization: @organization, author: @user, komsiluk: @komsiluk)
        end

        test "creates a post and awards the idempotent komšiluk points" do
          result = nil
          assert_difference -> { KomsilukPost.count }, 1 do
            result = creator.call(category: "general", title: "Naslov", body: "Tekst objave")
          end

          assert_equal :created, result.status
          assert_equal @user, result.post.author
          assert_equal @komsiluk, result.post.komsiluk

          account = Decidim::Bih::Goodwill::Account.find_by(
            decidim_organization_id: @organization.id,
            owner_type: @user.class.base_class.name, owner_id: @user.id, kind: "user"
          )
          assert_equal 10, account.contribution_score
        end

        test "rejects a post once the per-citizen daily limit is reached" do
          PostCreator::DAILY_LIMIT.times { |i| creator.call(category: "general", title: "T#{i}", body: "B#{i}") }

          result = nil
          assert_no_difference -> { KomsilukPost.count } do
            result = creator.call(category: "general", title: "Jos", body: "jedna")
          end
          assert_equal :rate_limited, result.status
        end

        test "returns :invalid for a blank body without raising" do
          result = nil
          assert_no_difference -> { KomsilukPost.count } do
            result = creator.call(category: "general", title: "Naslov", body: "")
          end
          assert_equal :invalid, result.status
        end

        %w(safety lost_pet general).each do |category|
          test "a new #{category} post captures and notifies the assigned neighbor" do
            neighbor = FactoryBot.create(:user, :confirmed, organization: @organization)
            CitizenProfile.for_user(neighbor, organization: @organization).assign_komsiluk!(@komsiluk, source: "dropdown")
            result = nil
            assert_enqueued_with(job: Decidim::Bih::KomsilukNoticeDeliveryJob) do
              result = creator.call(category:, title: "Obavještenje", body: "Novost iz komšiluka")
            end
            assert_equal :created, result.status
            receipt = PlatformDelivery.find_by!(komsiluk_post: result.post, user: neighbor)
            assert_equal [neighbor.id], PlatformDelivery.where(identity: receipt.identity).pluck(:decidim_user_id)
            assert_enqueued_with(job: Decidim::Bih::KomsilukNoticeDeliveryJob, args: [receipt.id])
            assert_no_enqueued_jobs(only: Decidim::Bih::KomsilukPostNotificationJob)
          end
        end

        test "the daily limit is scoped per citizen (another citizen is unaffected)" do
          PostCreator::DAILY_LIMIT.times { |i| creator.call(category: "general", title: "T#{i}", body: "B#{i}") }
          other = FactoryBot.create(:user, :confirmed, organization: @organization)

          result = PostCreator.new(organization: @organization, author: other, komsiluk: @komsiluk)
                              .call(category: "general", title: "Prva", body: "objava")
          assert_equal :created, result.status
        end
      end
    end
  end
end
