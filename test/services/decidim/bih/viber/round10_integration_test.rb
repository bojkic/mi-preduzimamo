# frozen_string_literal: true

require "test_helper"
require "support/fake_redis"

# Round 10 (corrected Round 14) end-to-end:
# Viber ↔ Decidim identity bridge + corrected Viber phone-verification flow.
#
# Covers:
#   1. OTP link → decidim_user_id stored on Linkage (when sms auth exists)
#   2. Linkage with decidim_user_id → goodwill_reply answers personally
#   3. Linked Viber sender → safe help/form offer, linkage preserved, no write
#   4. Unlinked sender → same help without report/points/identity mutation
#   5. ViberVerifyFlow: corrected sound model (grants sms auth; single-use;
#      expired; cross-org; replay; phone stored on linkage)
#   6. FK nullify on user destroy
#   7. Soundness regression: verification page embeds no token
module Decidim
  module Bih
    module Viber
      class Round10IntegrationTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        SENDER = "viber-r10-001"

        class StubGateway
          attr_reader :sends

          def initialize = (@sends = [])

          def call(phone, text)
            @sends << { phone: phone, text: text }
          end
        end

        class FakeDirectory
          def search(_query, **) = []
        end

        class FakeWaste
          def collection_days_for(_query) = nil
        end

        ViberMessage = Struct.new(:sender, :text, :image_url, :latitude, :longitude, keyword_init: true) do
          def initialize(sender: nil, text: nil, image_url: nil, latitude: nil, longitude: nil)
            super
          end
        end

        setup do
          clear_enqueued_jobs
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @redis = FakeRedis.new
          @gateway = StubGateway.new
          @linking = AccountLinking.new(
            organization: @organization,
            gateway: @gateway,
            otp_store: OtpStore.new(redis: @redis)
          )
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        teardown do
          clear_enqueued_jobs
        end

        # -----------------------------------------------------------------------
        # 1. OTP link stores decidim_user_id when sms auth exists
        # -----------------------------------------------------------------------

        test "link! stores decidim_user_id when a matching sms authorization exists" do
          phone = "38765111222"
          # Create a granted sms authorization matching the phone
          unique_id = Digest::SHA256.hexdigest("#{phone}-#{Rails.application.secret_key_base}")
          FactoryBot.create(:authorization,
                            user: @user,
                            name: "sms",
                            unique_id: unique_id,
                            granted_at: Time.current)

          @linking.start(sender: SENDER, phone: phone)
          code = @gateway.sends.last[:text][/\d{6}/]
          assert_equal :verified, @linking.verify(sender: SENDER, code: code)

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_equal @user.id, linkage.decidim_user_id
        end

        test "link! also tries +-prefixed phone as unique_id candidate" do
          phone_digits = "38765111222"
          phone_with_plus = "+38765111222"
          unique_id = Digest::SHA256.hexdigest("#{phone_with_plus}-#{Rails.application.secret_key_base}")
          FactoryBot.create(:authorization,
                            user: @user,
                            name: "sms",
                            unique_id: unique_id,
                            granted_at: Time.current)

          @linking.start(sender: SENDER, phone: phone_digits)
          code = @gateway.sends.last[:text][/\d{6}/]
          @linking.verify(sender: SENDER, code: code)

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_equal @user.id, linkage.decidim_user_id
        end

        test "link! leaves decidim_user_id nil when no sms auth matches" do
          @linking.start(sender: SENDER, phone: "38765000000")
          code = @gateway.sends.last[:text][/\d{6}/]
          @linking.verify(sender: SENDER, code: code)

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_nil linkage.decidim_user_id
        end

        # -----------------------------------------------------------------------
        # 2. linked_user returns the resolved user
        # -----------------------------------------------------------------------

        test "linked_user returns the Decidim::User for a linked sender" do
          create_granted_sms_authorization(phone: "38765111222")
          _linkage = Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765111222",
            verified_at: Time.current,
            decidim_user_id: @user.id
          )
          assert_equal @user, @linking.linked_user(sender: SENDER)
        end

        test "linked_user returns nil when no linkage exists" do
          assert_nil @linking.linked_user(sender: "unknown-sender")
        end

        test "linked_user returns nil when linkage has no decidim_user_id" do
          Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765111222",
            verified_at: Time.current
          )
          assert_nil @linking.linked_user(sender: SENDER)
        end

        # -----------------------------------------------------------------------
        # 3. Linked sender gets safe guidance; linkage never authorizes a write
        # -----------------------------------------------------------------------

        test "ambiguous problem text by a linked sender preserves linkage but creates no report or points" do
          create_granted_sms_authorization(phone: "38765111222")
          Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765111222",
            verified_at: Time.current,
            decidim_user_id: @user.id
          )

          responder = build_responder(linking: @linking)
          msg = ViberMessage.new(sender: SENDER, text: "Rupa na putu kod škole, hitno!")
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            assert_no_difference -> { Decidim::Bih::Goodwill::Account.count } do
              reply = responder.respond(msg)
            end
          end

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert(reply.quick_replies.any? do |chip|
            chip[:url] == Decidim::Bih::Engine.routes.url_helpers.new_report_path
          end)
          assert_equal @user, @linking.linked_user(sender: SENDER)
        end

        # -----------------------------------------------------------------------
        # 4. Unlinked sender gets the same safe guidance without identity effects
        # -----------------------------------------------------------------------

        test "ambiguous problem text by unlinked sender creates no report points or linkage" do
          responder = build_responder(linking: @linking)
          msg = ViberMessage.new(sender: "unlinked-sender-x", text: "Rupa na putu kod škole, hitno!")
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            assert_no_difference -> { Decidim::Bih::Goodwill::Account.count } do
              reply = responder.respond(msg)
            end
          end

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert(reply.quick_replies.any? do |chip|
            chip[:url] == Decidim::Bih::Engine.routes.url_helpers.new_report_path
          end)
          assert_nil @linking.linked_user(sender: "unlinked-sender-x")
        end

        test "goodwill reply for unlinked sender is the not_linked fallback" do
          responder = build_responder(linking: @linking)
          msg = ViberMessage.new(sender: "unlinked-sender-y", text: "koliko imam bodova")
          reply = responder.respond(msg)

          expected = I18n.t("decidim.bih.concierge.goodwill.not_linked",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path,
                            locale: "sr")
          # Task 6 appends the sign-in route to this fallback on every channel.
          assert_includes reply.text, expected
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in",
                                             url: "/users/sign_in", locale: "sr")
        end

        test "goodwill reply for linked sender returns personal balance" do
          create_granted_sms_authorization(phone: "38765111222")
          @ledger.award(@user, 50, reason: "volunteer_hour")
          Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765111222",
            verified_at: Time.current,
            decidim_user_id: @user.id
          )

          responder = build_responder(linking: @linking)
          msg = ViberMessage.new(sender: SENDER, text: "koliko imam bodova")
          reply = responder.respond(msg)

          assert_includes reply.text, "50"
          assert_not_equal I18n.t("decidim.bih.concierge.goodwill.not_linked",
                                  url: Decidim::Bih::Engine.routes.url_helpers.wallet_path,
                                  locale: "sr"),
                           reply.text
        end

        # -----------------------------------------------------------------------
        # 5. ViberVerifyFlow: corrected sound model (Round 14)
        # -----------------------------------------------------------------------

        test "verify flow: consuming a valid 'verify' token grants sms auth AND creates linkage" do
          phone = "38765111222"
          # unique_id must match the phone so the concern's phone-binding check passes.
          # Recipe: SHA256("#{phone.gsub(/[^+0-9]/, "")}-#{secret_key_base}")
          # — mirrors Decidim::Verifications::Sms::MobilePhoneForm#unique_id exactly.
          unique_id = Digest::SHA256.hexdigest(
            "#{phone.gsub(/[^+0-9]/, "")}-#{Rails.application.secret_key_base}"
          )
          # Create a pending sms authorization
          pending_auth = FactoryBot.create(:authorization,
                                           user: @user,
                                           name: "sms",
                                           unique_id: unique_id,
                                           granted_at: nil,
                                           verification_metadata: {
                                             "verification_code" => "123456",
                                             "code_sent_at" => 5.minutes.ago.iso8601
                                           })

          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify",
                                                phone: phone)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          flow = ViberVerifyFlow.new(organization: @organization)
          reply = flow.call(msg)

          assert_not_nil reply
          assert_equal I18n.t("decidim.bih.goodwill.verify_cta.viber.welcome", locale: "sr"), reply.text

          # Authorization was granted — this is the sound model
          pending_auth.reload
          assert_not_nil pending_auth.granted_at,
                         "ViberVerifyFlow MUST grant the sms authorization (corrected model)"

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_not_nil linkage
          assert_equal @user.id, linkage.decidim_user_id
          assert_not_nil linkage.verified_at
        end

        test "verify flow: token stores phone; linkage receives the real phone" do
          phone = "38765111333"
          create_pending_sms_authorization(phone:)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone:)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_not_nil linkage
          assert_equal "38765111333", linkage.phone,
                       "real phone from token must be stored on the linkage"
        end

        test "verify flow: token is single-use (replay returns nil)" do
          phone = "38765111222"
          create_pending_sms_authorization(phone:)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone:)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")
          flow = ViberVerifyFlow.new(organization: @organization)

          first = flow.call(msg)
          assert_not_nil first

          second = flow.call(msg)
          assert_nil second
        end

        test "verify flow: expired token returns nil" do
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify",
                                                phone: "38765111222")
          Decidim::Bih::LoginToken.last.update!(expires_at: 1.minute.ago)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          flow = ViberVerifyFlow.new(organization: @organization)
          assert_nil flow.call(msg)
        end

        test "verify flow: missing sms authorization rolls back token consumption and writes no linkage" do
          raw = Decidim::Bih::LoginToken.issue!(
            user: @user,
            purpose: "verify",
            phone: "38765111222"
          )
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          assert_no_difference -> { Linkage.count } do
            assert_nil ViberVerifyFlow.new(organization: @organization).call(msg)
          end

          assert Decidim::Bih::LoginToken.peek(raw:, organization: @organization, purpose: "verify")
        end

        test "verify flow: cross-org token returns nil" do
          other_org = create_organization(host: "other-r10.lvh.me")
          other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
          raw = Decidim::Bih::LoginToken.issue!(user: other_user, purpose: "verify",
                                                phone: "38765111222")
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          flow = ViberVerifyFlow.new(organization: @organization)
          assert_nil flow.call(msg)

          # No linkage was created
          assert_nil Linkage.find_by(organization: @organization, viber_sender: SENDER)
        end

        test "verify flow: non-verify message returns nil" do
          flow = ViberVerifyFlow.new(organization: @organization)
          msg = ViberMessage.new(sender: SENDER, text: "koliko imam bodova")
          assert_nil flow.call(msg)
        end

        test "verify flow: 'viber_verify' purpose tokens are not accepted (purpose retired)" do
          # viber_verify is no longer in PURPOSES; issue! would raise.
          # Simulate an old row still in the DB by inserting directly.
          old_raw = SecureRandom.urlsafe_base64(24)
          # rubocop:disable Rails/SkipsModelValidations
          Decidim::Bih::LoginToken.insert!({
                                             decidim_user_id: @user.id,
                                             decidim_organization_id: @organization.id,
                                             purpose: "viber_verify",
                                             token_digest: Decidim::Bih::LoginToken.digest(old_raw),
                                             expires_at: 30.minutes.from_now,
                                             consumed_at: nil,
                                             created_at: Time.current,
                                             updated_at: Time.current
                                           })
          # rubocop:enable Rails/SkipsModelValidations

          msg = ViberMessage.new(sender: SENDER, text: "verify_#{old_raw}")
          flow = ViberVerifyFlow.new(organization: @organization)

          # consume! finds the token but the flow rejects purpose != "verify"
          result = flow.call(msg)
          assert_nil result, "viber_verify tokens must not be accepted by the corrected flow"
          assert Decidim::Bih::LoginToken.peek(raw: old_raw, organization: @organization, purpose: "viber_verify"),
                 "a token from another purpose must not be consumed"
        end

        test "verify flow: linked exactly once even when called multiple times" do
          phone = "38765111222"
          create_pending_sms_authorization(phone:)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone:)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")
          flow = ViberVerifyFlow.new(organization: @organization)

          assert_difference -> { Linkage.count }, 1 do
            flow.call(msg)
            flow.call(msg) # second call returns nil but must not create another row
          end
        end

        test "verify flow: never raises on any error" do
          # Pass a message object that explodes when accessed
          exploding_msg = Object.new
          exploding_msg.define_singleton_method(:text) { raise "simulated error" }

          flow = ViberVerifyFlow.new(organization: @organization)
          assert_nothing_raised { flow.call(exploding_msg) }
        end

        # Fix 1: blocked user holding a live verify token is NOT granted
        test "verify flow: blocked user with live token is not granted (concern guard)" do
          phone = "38765555001"
          normalized_phone = phone.gsub(/[^+0-9]/, "")
          unique_id = Digest::SHA256.hexdigest(
            "#{normalized_phone}-#{Rails.application.secret_key_base}"
          )
          pending_auth = FactoryBot.create(:authorization,
                                           user: @user,
                                           name: "sms",
                                           unique_id: unique_id,
                                           granted_at: nil,
                                           verification_metadata: {
                                             "verification_code" => "111222",
                                             "code_sent_at" => 2.minutes.ago.iso8601
                                           })

          @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: phone)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          # Authorization must NOT be granted for a blocked user
          pending_auth.reload
          assert_nil pending_auth.granted_at,
                     "blocked user must not receive sms authorization grant via ViberVerifyFlow"
        end

        # Fix 1 (linkage gate): a blocked user's verify flow writes NO linkage.
        # The grant is correctly refused, but the linkage write must be gated on
        # the same active predicate so a since-blocked account never keeps earning
        # points/authorship via Viber.
        test "verify flow: blocked user with live token writes no linkage" do
          phone = "38765556001"
          @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: phone)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          assert_no_difference -> { Linkage.count } do
            ViberVerifyFlow.new(organization: @organization).call(msg)
          end

          assert_nil Linkage.find_by(organization: @organization, viber_sender: SENDER),
                     "no linkage may be written for a blocked user"
        end

        # Fix 1 (linkage gate): a deleted user's verify flow writes NO linkage.
        test "verify flow: deleted user with live token writes no linkage" do
          phone = "38765556002"
          @user.update!(deleted_at: Time.current)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: phone)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          assert_no_difference -> { Linkage.count } do
            ViberVerifyFlow.new(organization: @organization).call(msg)
          end

          assert_nil Linkage.find_by(organization: @organization, viber_sender: SENDER),
                     "no linkage may be written for a deleted user"
        end

        # Fix 1 (consumer hardening): a PRE-EXISTING linkage to an account that was
        # blocked AFTER linking must stop resolving — linked_user returns nil so the
        # blocked account no longer confers points/authorship.
        test "linked_user returns nil when the linked user has since been blocked" do
          create_granted_sms_authorization(phone: "38765556003")
          Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765556003",
            verified_at: Time.current,
            decidim_user_id: @user.id
          )
          assert_equal @user, @linking.linked_user(sender: SENDER)
          @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})

          assert_nil @linking.linked_user(sender: SENDER),
                     "a since-blocked linked user must not be resolved"
        end

        test "linked_user returns nil when the linked user has since been deleted" do
          create_granted_sms_authorization(phone: "38765556004")
          Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765556004",
            verified_at: Time.current,
            decidim_user_id: @user.id
          )
          assert_equal @user, @linking.linked_user(sender: SENDER)
          @user.update!(deleted_at: Time.current)

          assert_nil @linking.linked_user(sender: SENDER),
                     "a since-deleted linked user must not be resolved"
        end

        # Fix 1: deleted user holding a live verify token is NOT granted
        test "verify flow: deleted user with live token is not granted (concern guard)" do
          phone = "38765555002"
          normalized_phone = phone.gsub(/[^+0-9]/, "")
          unique_id = Digest::SHA256.hexdigest(
            "#{normalized_phone}-#{Rails.application.secret_key_base}"
          )
          pending_auth = FactoryBot.create(:authorization,
                                           user: @user,
                                           name: "sms",
                                           unique_id: unique_id,
                                           granted_at: nil,
                                           verification_metadata: {
                                             "verification_code" => "333444",
                                             "code_sent_at" => 2.minutes.ago.iso8601
                                           })

          @user.update!(deleted_at: Time.current)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: phone)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          pending_auth.reload
          assert_nil pending_auth.granted_at,
                     "deleted user must not receive sms authorization grant via ViberVerifyFlow"
        end

        # Fix 2: phone-binding — token for phone A cannot grant authorization for phone B
        test "verify flow: token phone mismatch does not grant the authorization" do
          phone_a = "38765555111"
          phone_b = "38765555222"
          # Authorization belongs to phone B's unique_id
          unique_id_b = Digest::SHA256.hexdigest(
            "#{phone_b.gsub(/[^+0-9]/, "")}-#{Rails.application.secret_key_base}"
          )
          pending_auth = FactoryBot.create(:authorization,
                                           user: @user,
                                           name: "sms",
                                           unique_id: unique_id_b,
                                           granted_at: nil,
                                           verification_metadata: {
                                             "verification_code" => "555666",
                                             "code_sent_at" => 2.minutes.ago.iso8601
                                           })

          # Token was issued for phone A — mismatch with phone B authorization
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: phone_a)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          pending_auth.reload
          assert_nil pending_auth.granted_at,
                     "authorization for phone B must not be granted when token was issued for phone A"
        end

        # Fix 2: matching phone grants correctly
        test "verify flow: token phone match grants the authorization" do
          phone = "38765555333"
          normalized = phone.gsub(/[^+0-9]/, "")
          unique_id = Digest::SHA256.hexdigest(
            "#{normalized}-#{Rails.application.secret_key_base}"
          )
          pending_auth = FactoryBot.create(:authorization,
                                           user: @user,
                                           name: "sms",
                                           unique_id: unique_id,
                                           granted_at: nil,
                                           verification_metadata: {
                                             "verification_code" => "777888",
                                             "code_sent_at" => 2.minutes.ago.iso8601
                                           })

          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: phone)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          pending_auth.reload
          assert_not_nil pending_auth.granted_at,
                         "matching phone must allow authorization grant via ViberVerifyFlow"
        end

        # -----------------------------------------------------------------------
        # 6. FK nullify on user destroy
        # -----------------------------------------------------------------------

        test "destroying the Decidim::User nullifies decidim_user_id on the linkage" do
          linkage = Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            phone: "38765111222",
            verified_at: Time.current,
            decidim_user_id: @user.id
          )

          @user.destroy!
          linkage.reload

          assert_nil linkage.decidim_user_id, "decidim_user_id must be nullified, not cascade-deleted"
          assert Linkage.exists?(linkage.id), "the linkage row itself must survive user destruction"
        end

        # -----------------------------------------------------------------------
        # 7. Linkage phone handling: phone from token stored on linkage
        # -----------------------------------------------------------------------

        test "verify flow: Viber-link-only linkage has phone from token (not nil)" do
          phone = "38765111999"
          create_pending_sms_authorization(phone:)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone:)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_not_nil linkage
          # With the corrected flow the phone comes from the token
          assert_equal "38765111999", linkage.phone,
                       "phone from token must be stored on linkage in the corrected flow"
        end

        test "verify flow normalizes the token phone to digits before storing it on the linkage" do
          # MobilePhoneForm keeps a leading "+", so the token can carry
          # "+38765...". The linkage must store the SAME digits-only form the OTP
          # path uses (Linkage.normalize_phone), or report attribution can't
          # reconcile a web reporter_phone against the linkage.
          phone = "+38765111999"
          create_pending_sms_authorization(phone:)
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone:)
          msg = ViberMessage.new(sender: SENDER, text: "verify_#{raw}")

          ViberVerifyFlow.new(organization: @organization).call(msg)

          linkage = Linkage.find_by(organization: @organization, viber_sender: SENDER)
          assert_equal "38765111999", linkage.phone
        end

        test "verify flow: Viber-link-only linkage cannot authorize an attributed chat report" do
          # A linkage with nil phone (legacy or no-phone token) is not report
          # authorization. The legacy bot must hand off to the supported form.
          Linkage.create!(
            organization: @organization,
            viber_sender: SENDER,
            verified_at: Time.current,
            decidim_user_id: @user.id
            # phone intentionally omitted (nil) — legacy row
          )

          responder = build_responder(linking: @linking)
          msg = ViberMessage.new(sender: SENDER, text: "Želim da prijavim rupu na putu")
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(msg)
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        private

        def create_granted_sms_authorization(phone:)
          FactoryBot.create(:authorization, user: @user, name: "sms",
                                            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone), granted_at: Time.current)
        end

        def create_pending_sms_authorization(phone:)
          FactoryBot.create(
            :authorization,
            user: @user,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            granted_at: nil,
            verification_metadata: {
              "verification_code" => "123456",
              "code_sent_at" => 2.minutes.ago.iso8601
            }
          )
        end

        def build_responder(linking:)
          Decidim::Bih::Concierge::Responder.new(
            organization: @organization,
            directory: FakeDirectory.new,
            waste_schedule: FakeWaste.new,
            report_intake: Decidim::Bih::ReportIntake.new(
              processing_job: Class.new { def self.perform_later(*) = nil }
            ),
            goodwill_user_resolver: lambda { |msg|
              sender = msg.respond_to?(:sender) ? msg.sender : nil
              return nil if sender.blank?

              linking.linked_user(sender: sender)
            }
          )
        end
      end
    end
  end
end
