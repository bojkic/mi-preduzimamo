# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module RaceProjectPermissions
      # Hook the permission entry point: Awesome aliases can_vote_proposal?
      # during initialization, which would capture a prepended implementation
      # and recurse when that implementation calls super.
      def permissions
        return super unless race_vote_action?
        return super if RaceProjectSelection.eligible_voter?(user, component)

        disallow!
        permission_action
      end

      private

      def race_vote_action?
        permission_action.scope == :public && permission_action.subject == :proposal &&
          permission_action.action == :vote && RaceProjectSelection.component?(component)
      end
    end
  end
end
