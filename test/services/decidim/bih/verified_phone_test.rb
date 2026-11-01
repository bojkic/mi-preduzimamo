# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class VerifiedPhoneTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = create(:user, :confirmed, organization: @organization)
        @phone = "+38765123456"
        @grant = Decidim::Authorization.create!(user: @user, name: "sms",
                                                unique_id: SmsAuthorization.unique_id_for(@phone), granted_at: 1.hour.ago)
      end

      test "synchronization repairs both destinations idempotently without changing permission" do
        preferences = @user.notification_settings.deep_dup
        CitizenPhone.store!(@user, @phone)
        assert_not VerifiedPhone.consistent?(user: @user, organization: @organization)
        assert_difference("Viber::BusinessContact.count", 1) { assert synchronize }
        record = CitizenPhoneRecord.find_by!(user: @user)
        contact = Viber::BusinessContact.find_by!(user: @user)
        times = [record.updated_at, contact.updated_at]
        assert_no_difference("CitizenPhoneRecord.count + Viber::BusinessContact.count") { assert synchronize }
        assert_equal times, [record.reload.updated_at, contact.reload.updated_at]
        assert_equal preferences, @user.reload.notification_settings
        assert VerifiedPhone.consistent?(user: @user, organization: @organization)
      end

      test "grant revocation immediately suppresses both readers even with stale rows" do
        assert synchronize
        @grant.destroy!
        assert_nil CitizenPhone.for(@user)
        assert_nil Viber::BusinessRecipient.phone_for(user: @user, organization_id: @organization.id)
        assert_not synchronize
      end

      test "another current grant never permits sending to the old stored number" do
        assert synchronize
        @grant.update!(unique_id: SmsAuthorization.unique_id_for("+38765999888"))
        assert_nil CitizenPhone.for(@user)
        assert_nil Viber::BusinessRecipient.phone_for(user: @user, organization_id: @organization.id)
      end

      test "phone mismatch and cross organization repair fail closed" do
        assert_not VerifiedPhone.synchronize!(user: @user, organization: @organization, phone: "+38765999888")
        other = create_organization
        assert_not VerifiedPhone.synchronize!(user: @user, organization: other, phone: @phone)
        assert_nil VerifiedPhone.phone_for(user: @user, organization: other)
        assert_equal 0, CitizenPhoneRecord.where(user: @user).count
      end

      test "duplicate active grants in one organization fail closed" do
        other = create(:user, :confirmed, organization: @organization)
        Decidim::Authorization.create!(user: other, name: "sms", unique_id: SmsAuthorization.unique_id_for(@phone), granted_at: Time.current)
        assert_not synchronize
      end

      test "same phone in another organization is independent" do
        other = create(:user, :confirmed, organization: create_organization)
        Decidim::Authorization.create!(user: other, name: "sms", unique_id: SmsAuthorization.unique_id_for(@phone), granted_at: Time.current)
        assert synchronize
      end

      test "expired grant cannot repair or resolve an address" do
        assert synchronize
        manifest = Struct.new(:expires_in).new(1.minute)
        Decidim::Verifications.stub(:find_workflow_manifest, manifest) do
          assert_nil VerifiedPhone.phone_for(user: @user, organization: @organization)
          assert_not synchronize
        end
      end

      test "legacy phone representations retain their authorization hash" do
        ["+38765123456", "38765123456", "065123456"].each do |shape|
          @grant.update!(unique_id: SmsAuthorization.unique_id_for(shape))
          assert synchronize
          assert_equal @phone, CitizenPhone.for(@user)
          assert_equal SmsAuthorization.unique_id_for(shape), @grant.reload.unique_id
        end
      end

      test "foreign number is not reinterpreted as a Bosnian number" do
        @phone = "+493012345678"
        @grant.update!(unique_id: SmsAuthorization.unique_id_for(@phone))
        assert synchronize
        assert_equal @phone, CitizenPhone.for(@user)
        assert_equal "493012345678", Viber::BusinessRecipient.phone_for(user: @user, organization_id: @organization.id)
      end

      test "delivery uses explicit international numbers without guessing foreign country codes" do
        {
          "+38765123456" => "+38765123456", "38765123456" => "+38765123456",
          "065123456" => "+38765123456", "+493012345678" => "+493012345678",
          "00493012345678" => "+493012345678", "66900004" => nil,
          "493012345678" => nil
        }.each do |stored, destination|
          @phone = stored
          @grant.update!(unique_id: SmsAuthorization.unique_id_for(stored))
          assert synchronize
          actual = VerifiedPhone.delivery_phone_for(user: @user, organization: @organization)
          destination.nil? ? assert_nil(actual) : assert_equal(destination, actual)
        end
      end

      test "database failure inside synchronization does not poison the surrounding grant transaction" do
        @user.with_lock do
          Viber::BusinessContact.stub(:find_or_initialize_by, ->(**) { ActiveRecord::Base.connection.execute("SELECT missing_verified_phone_column") }) do
            assert_not synchronize
          end
          assert_equal @grant.id, Decidim::Authorization.find(@grant.id).id
        end
        assert_equal 0, CitizenPhoneRecord.where(user: @user).count
        assert @grant.reload.granted?
      end

      test "revocation clears destinations and leaves opaque Bot history" do
        assert synchronize
        linkage = Viber::Linkage.create!(organization: @organization, user: @user,
                                         viber_sender: "opaque", phone: "38765123456", verified_at: Time.current)
        @user.with_lock do
          @grant.destroy!
          VerifiedPhone.revoke_destinations!(user: @user, organization: @organization)
        end
        assert_nil linkage.reload.phone
        assert_nil linkage.verified_at
        assert_equal "opaque", linkage.viber_sender
        assert_equal 0, CitizenPhoneRecord.where(user: @user).count
        assert_equal 0, Viber::BusinessContact.where(user: @user).count
      end

      private

      def synchronize
        VerifiedPhone.synchronize!(user: @user, organization: @organization, phone: @phone)
      end
    end
  end
end
