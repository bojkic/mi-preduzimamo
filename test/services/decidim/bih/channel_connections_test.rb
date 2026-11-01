# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ChannelConnectionsTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @other = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "chat proof alone does not link and same account must confirm separate secret" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          reply = ChannelConnections.observe!(organization: @organization, message: inbound(command))
          code = reply[/[A-F0-9]{12}/]
          assert code
          assert_nil ChannelConnections.for_user(user: @user, organization: @organization, channel: "messenger")
          assert_raises(ChannelConnections::InvalidProof) { confirm(challenge, code, @other) }
          assert_raises(ChannelConnections::InvalidProof) { confirm(challenge, "WRONG") }
          connection = confirm(challenge, code)
          assert_equal "opaque.sender", connection.recipient_id
          assert_not_includes connection.recipient_ciphertext, "opaque.sender"
          assert_raises(ChannelConnections::InvalidProof) { confirm(challenge, code) }
          assert_equal connection, ChannelConnections.for_user(user: @user, organization: @organization, channel: "messenger")
          ChannelConnections.disconnect!(user: @user, organization: @organization, channel: "messenger")
          assert_nil ChannelConnections.for_user(user: @user, organization: @organization, channel: "messenger")
        end
      end

      test "five wrong confirmations consume proof and expiry clears secret payload" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          reply = ChannelConnections.observe!(organization: @organization, message: inbound(command))
          5.times { assert_raises(ChannelConnections::InvalidProof) { confirm(challenge, "WRONG") } }
          assert challenge.reload.consumed_at
          assert_raises(ChannelConnections::InvalidProof) { confirm(challenge, reply[/[A-F0-9]{12}/]) }
          travel_to 11.minutes.from_now do
            ExpireChannelConnectionChallengeJob.perform_now(challenge.id)
          end
          assert_nil challenge.reload.recipient_ciphertext
          assert_nil challenge.confirmation_digest
        end
      end

      test "early expiry jobs reschedule and repeated expiry is harmless" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          ChannelConnections.observe!(organization: @organization, message: inbound(command))
          assert_enqueued_with(job: ExpireChannelConnectionChallengeJob, args: [challenge.id], at: challenge.expires_at) do
            ExpireChannelConnectionChallengeJob.perform_now(challenge.id)
          end
          assert challenge.reload.recipient_ciphertext
          travel_to 11.minutes.from_now do
            2.times { ExpireChannelConnectionChallengeJob.perform_now(challenge.id) }
          end
          assert_nil challenge.reload.recipient_ciphertext
          assert_nil challenge.confirmation_digest
        end
      end

      test "account deletion removes connection secrets and retention is scoped dry-run" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          reply = ChannelConnections.observe!(organization: @organization, message: inbound(command))
          connection = confirm(challenge, reply[/[A-F0-9]{12}/])
          ChannelConnections.disconnect!(user: @user, organization: @organization, channel: "messenger")
          assert_equal "", connection.reload.recipient_ciphertext
          counts = Privacy::RetentionSweep.call(organization: @organization, channel_connection_before: 1.second.from_now).counts
          assert_equal 1, counts[:channel_connections]
          assert ChannelConnection.exists?(connection.id)
          @user.update!(deleted_at: Time.current)
          assert_not ChannelConnection.exists?(connection.id)
          assert_not ChannelConnectionChallenge.exists?(challenge.id)
        end
      end

      test "scope expiry and missing event timestamps fail closed" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          assert_nil ChannelConnections.observe!(organization: @organization, message: inbound(command, recipient: "other-business"))
          assert_nil ChannelConnections.observe!(organization: @organization, message: inbound(command, occurred_at: nil))
          challenge.update!(expires_at: 1.second.ago)
          ChannelConnections.observe!(organization: @organization, message: inbound(command))
          assert_nil challenge.reload.proved_at
          assert_equal 0, ChannelConnection.count
        end
      end

      test "replayed event cannot refresh session or consume command twice" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          reply = ChannelConnections.observe!(organization: @organization, message: inbound(command))
          connection = confirm(challenge, reply[/[A-F0-9]{12}/])
          latest = connection.last_inbound_at
          ChannelConnections.observe!(organization: @organization, message: inbound("hello", occurred_at: 25.hours.ago))
          assert_equal latest, connection.reload.last_inbound_at
          assert_equal latest + 23.hours, connection.session_expires_at
          assert_equal I18n.t("decidim.bih.channel_connections.invalid"), ChannelConnections.observe!(organization: @organization, message: inbound(command))
          assert_equal 1, ChannelConnection.count
        end
      end

      test "recipient already linked to another account cannot be stolen" do
        with_sender do
          challenge, command = ChannelConnections.begin!(user: @user, organization: @organization, channel: "messenger")
          reply = ChannelConnections.observe!(organization: @organization, message: inbound(command))
          confirm(challenge, reply[/[A-F0-9]{12}/])
          second, command = ChannelConnections.begin!(user: @other, organization: @organization, channel: "messenger")
          reply = ChannelConnections.observe!(organization: @organization, message: inbound(command))
          assert_raises(ChannelConnections::InvalidProof) { confirm(second, reply[/[A-F0-9]{12}/], @other) }
        end
      end

      private

      def with_sender(&)
        ChannelConnections.stub(:configured_sender, "business", &)
      end

      def confirm(challenge, code, user = @user)
        ChannelConnections.confirm!(user:, organization: @organization, challenge_id: challenge.id, confirmation: code)
      end

      def inbound(text, recipient: "business", occurred_at: Time.current)
        Struct.new(:channel, :recipient, :sender, :text, :occurred_at).new("messenger", recipient, "opaque.sender", text, occurred_at)
      end
    end
  end
end
