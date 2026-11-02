# frozen_string_literal: true

require Rails.root.join("installation/demo/provision")
MiDemoProvisioner.new.call("system")
