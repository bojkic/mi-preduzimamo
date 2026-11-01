# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Server-only authorized presentation. No result from this reader is sent
      # to the public composer or included in its conversation frame.
      class PrivateAccountRead
        KINDS = %w(balance invitation area verification referrals identity affordability).freeze
        Dialogue = Decidim::Bih::Concierge::Dialogue
        Result = Data.define(:status, :text) do
          def inspect = "#<PrivateAccountRead::Result status=#{status.inspect} text=[PRIVATE]>"
          alias_method :to_s, :inspect
        end

        def initialize(organization:, actor_lookup: nil)
          @organization = organization
          @actor_lookup = actor_lookup || lambda { |id|
            Decidim::User.where(decidim_organization_id: organization.id).find_by(id: id)
          }
        end

        def call(kind:, context:, locale: "sr", reward_key: nil)
          validate_request!(kind, context, locale)
          user = context.actor_id && @actor_lookup.call(context.actor_id)
          return Result.new(status: "not_authorized", text: I18n.t("decidim.bih.dialogue.handoff_sign_in", locale:, url: "/users/sign_in")) unless authorized_actor?(user, context)

          text = I18n.with_locale(locale) { present(kind, user, reward_key:) }
          raise Dialogue::Contracts::Invalid, "Private deadline exceeded" if context.deadline.expired?

          return Result.new(status: "unavailable", text: I18n.t("decidim.bih.dialogue.context_unavailable", locale:)) if text.nil?

          Result.new(status: "ok", text: text.to_s)
        end

        private

        def validate_request!(kind, context, locale)
          raise Dialogue::Contracts::Invalid, "Unknown private read" unless KINDS.include?(kind)
          raise Dialogue::Contracts::Invalid, "Trusted private context required" unless context.is_a?(Dialogue::Contracts::TrustedContext)
          raise Dialogue::Contracts::Invalid, "Private tenant mismatch" unless context.organization_id == @organization.id
          raise Dialogue::Contracts::Invalid, "Private deadline required" unless context.deadline && !context.deadline.expired?

          Dialogue::Contracts.enum!(locale, Dialogue::Contracts::LOCALES)
        end

        def authorized_actor?(user, context)
          return false unless user && user.id == context.actor_id && user.decidim_organization_id == context.organization_id
          return false if context.account_state == "unavailable" || !context.allows?("own_report_reads")
          return false if [:group?, :blocked?, :deleted?].any? { |flag| user.respond_to?(flag) && user.public_send(flag) }

          active_actor?(user)
        end

        def active_actor?(user)
          !user.respond_to?(:active_for_authentication?) || user.active_for_authentication?
        end

        def present(kind, user, reward_key:)
          case kind
          when "balance" then balance(user)
          when "invitation" then invitation(user)
          when "area" then area(user)
          when "verification" then verification(user)
          when "referrals" then referrals(user)
          when "identity" then identity(user)
          when "affordability" then affordability(user, reward_key)
          end
        end

        def t(key, **values) = I18n.t("decidim.bih.concierge.#{key}", **values)

        def d(key, **values) = I18n.t("decidim.bih.dialogue.#{key}", **values)

        def path(value) = Decidim::Bih.public_path(value)

        def routes = Decidim::Bih::Engine.routes.url_helpers

        def points(value) = t("goodwill.earning.points", count: value.to_i)

        def account(user)
          Decidim::Bih::Goodwill::Account.find_by(decidim_organization_id: @organization.id,
                                                  owner_type: user.class.base_class.name, owner_id: user.id, kind: "user")
        end

        def balance(user)
          row = account(user)
          return t("goodwill.none", url: routes.wallet_path) if row.nil? || (row.contribution_score.to_i.zero? && row.balance.to_i.zero?)

          level = row.level
          values = { balance: row.balance, level: I18n.t("decidim.bih.goodwill.levels.#{level.key}"),
                     rank: Decidim::Bih::Goodwill::Account.rank_for(row), url: routes.wallet_path }
          suffix = values[:rank].nil? ? "_unranked" : ""
          return t("goodwill.found_top#{suffix}", **values) unless level.points_to_next.to_i.positive?

          t("goodwill.found#{suffix}", **values, to_next: level.points_to_next)
        end

        def invitation(user)
          key = invitation_key
          row = invitation_for(user, key)
          return issued_invitation(row) if row

          reward = Decidim::Bih::Goodwill::RewardsCatalog.find(key, @organization)
          return t("account_state.invitation.unavailable", hub_url: path("zajednistvo")) unless reward && !reward.expired?

          score = account(user)&.contribution_score.to_i
          return t("account_state.invitation.reached", threshold: points(reward.cost), score: points(score), hub_url: path("zajednistvo")) if score >= reward.cost

          text = t("account_state.invitation.not_yet", threshold: points(reward.cost), score: points(score), missing: points(reward.cost - score),
                                                       rules_url: path("zajednistvo?tab=kako"))
          verified = Decidim::Authorization.find_by(user:, name: "sms")&.granted?
          text += "\n#{d("handoff_verify", url: routes.verification_explainer_path)}" unless verified
          text
        end

        def invitation_key
          configured = Decidim::Bih.launch_invitation_reward_key if Decidim::Bih.respond_to?(:launch_invitation_reward_key)
          configured.presence || Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY
        end

        def invitation_for(user, key)
          rows = Decidim::Bih::Goodwill::RewardFulfillment.where(decidim_organization_id: @organization.id,
                                                                 decidim_user_id: user.id, reward_key: key).order(created_at: :desc, id: :desc).to_a
          rows.find { |item| %w(requested reserved fulfilled).include?(item.status) } || rows.first
        end

        def issued_invitation(row)
          status = case row.status.to_s
                   when "fulfilled" then "fulfilled"
                   when "canceled", "reversed" then "canceled"
                   else row.attendance_confirmed_at ? "confirmed" : "reserved"
                   end
          code = row.entry_code.to_s.strip
          status += "_without_code" if code.empty? && %w(confirmed reserved).include?(status)
          t("account_state.invitation.#{status}", code:, hub_url: path("zajednistvo"))
        end

        def own_area?(area, kind)
          area && area.decidim_organization_id == @organization.id && area.kind == kind
        end

        def area(user)
          profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: user.id)
          selected = profile&.komsiluk
          return [t("account_state.komsiluk.none"), d("handoff_choose_area", url: routes.edit_komsiluk_path)].join("\n") unless own_area?(selected, "komsiluk")

          mz = profile.mz
          mz = selected.primary_mz unless own_area?(mz, "mz")
          values = { komsiluk: selected.translated_name, board_url: routes.komsiluk_board_index_path, url: routes.edit_komsiluk_path }
          return t("account_state.komsiluk.assigned_without_mz", **values) unless own_area?(mz, "mz")

          t("account_state.komsiluk.assigned", **values, mz: mz.translated_name)
        end

        def verification(user)
          summary = Decidim::Bih::AccountSummary.new(organization: @organization, user:)
          lines = [t("account_state.verification.#{summary.sms_verified? ? "verified" : "not_verified"}", account_url: routes.account_overview_path),
                   t("account_state.verification.postal_#{summary.postal_verified? ? "done" : "open"}", url: routes.verification_explainer_path),
                   t("account_state.verification.email_#{Decidim::Bih::EmailConfirmation.confirmed?(user) ? "done" : "open"}")]
          lines << d("handoff_verify", url: routes.verification_explainer_path) unless summary.sms_verified?
          lines.join("\n")
        end

        def referrals(user)
          rows = Decidim::Bih::Goodwill::Referral.where(decidim_organization_id: @organization.id, referrer_id: user.id)
          count = rows.count
          return t("account_state.referrals.none", url: path("zajednistvo?tab=pozovi")) if count.zero?

          rewarded = rows.rewarded.count
          text = t("account_state.referrals.count", count:, rewarded:, url: path("zajednistvo?tab=pozovi"))
          if count > rewarded
            hours = Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY.to_i / 3600
            text += "\n#{t("account_state.referrals.pending", count: count - rewarded, hours:)}"
          end
          text
        end

        def identity(user)
          values = { name: user.name, nickname: user.nickname, url: routes.account_overview_path }
          key = if user.name.blank? && user.nickname.blank?
                  "unknown"
                elsif user.nickname.blank?
                  "name_only"
                elsif user.name.blank?
                  "nickname_only"
                else
                  "known"
                end
          t("account_state.identity.#{key}", **values)
        end

        def affordability(user, reward_key)
          reward = if reward_key
                     Decidim::Bih::Goodwill::RewardsCatalog.manually_redeemable(@organization).find do |item|
                       item.key == reward_key && !(item.respond_to?(:expired?) && item.expired?)
                     end
                   end
          return unless reward

          current = account(user)&.balance.to_i
          cost = reward.cost.to_i
          values = { reward: reward.name, cost: points(cost), balance: points(current), url: path("zajednistvo?tab=nagrade") }
          return t("goodwill.affordability.enough", **values) if current >= cost

          t("goodwill.affordability.not_enough", **values, missing: points(cost - current), rules_url: path("zajednistvo?tab=kako"))
        end
      end
    end
  end
end
