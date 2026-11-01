# frozen_string_literal: true

# New citizens should not be enrolled into e-mail notifications by a column
# default nobody chose. Decidim ships `notifications_sending_frequency` with a
# default of "daily", and nothing in either sign-up path sets the value
# explicitly, so every citizen who has ever registered here arrived on "daily"
# — 87 of 91 at the time of writing.
#
# That has sent nothing so far, because `decidim:mailers:notifications_digest_daily`
# is scheduled nowhere on this server. The risk it leaves behind is the point:
# schedule that task once and 87 people receive mail the next morning without
# having opted in since. "none" makes the quiet state the deliberate one.
#
# EXISTING ROWS ARE NOT TOUCHED. A column default applies to new rows only, and
# rewriting 91 people's stored preference is their choice to make, not a
# migration's. Citizens change this themselves in notification settings.
class DefaultNotificationFrequencyToNone < ActiveRecord::Migration[7.2]
  def up
    change_column_default :decidim_users, :notifications_sending_frequency,
                          from: "daily", to: "none"
  end

  def down
    change_column_default :decidim_users, :notifications_sending_frequency,
                          from: "none", to: "daily"
  end
end
