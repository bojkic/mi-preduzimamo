# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    class CityServiceBoardActions
      ACTIONS = %w(withdraw_source correct_source withdraw_all).freeze

      def initialize(post:, actor:)
        @post = post
        @actor = actor
      end

      def events
        CityServiceBoardVisibility.events_for(@post).order(:id)
      end

      def posts
        ids = events.flat_map(&:komsiluk_post_id_values).uniq
        Decidim::Bih::KomsilukPost.where(organization: @post.organization, id: ids).includes(:komsiluk).order(:id)
      end

      def token
        verifier.generate(snapshot, expires_in: 15.minutes, purpose: "komsiluk_source_action")
      end

      def call(action:, event_id:, token:, note:)
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(@actor, :city_alerts_manage, organization: @post.organization)
        return :invalid_action unless ACTIONS.include?(action)
        return :note_required if note.to_s.strip.blank? || note.to_s.length > 2000

        CityServiceIncident.synchronize(@post.organization) do
          return :stale_review unless verifier.verified(token.to_s, purpose: "komsiluk_source_action") == snapshot

          selected = events.where(state: %w(board_published published))
          selected = selected.where(id: event_id) unless action == "withdraw_all"
          selected = selected.to_a
          return :not_publishable if selected.empty?

          selected.each do |event|
            result = CityServicePublicationWithdrawal.call(event:, actor: @actor, review_token: event.answer_review_token,
                                                           note:, correct: action == "correct_source")
            raise ActiveRecord::Rollback unless result == :withdrawn
          end
          :withdrawn
        end || :stale_review
      end

      private

      def snapshot
        { "organization_id" => @post.decidim_organization_id, "actor_id" => @actor.id, "post_id" => @post.id,
          "events" => events.map { |event| [event.id, event.answer_review_token] },
          "placements" => posts.map { |post| [post.id, post.lock_version, post.status, post.expires_at&.iso8601] } }
      end

      def verifier
        Rails.application.message_verifier("komsiluk-source-actions-v1")
      end
    end
  end
end
