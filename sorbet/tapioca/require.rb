# typed: true
# frozen_string_literal: true

# Loaded by `tapioca gems` before it generates RBIs, for gems whose require
# path differs from the gem name or whose Rails parts load only under Rails.
require "rails"
require "action_controller/railtie"
require "action_policy"
require "action_policy/rails/controller"
require "action_policy/rails/authorizer"
# pundit/rspec defines the `permit` matcher the Pundit collector hooks.
require "rspec/core"
require "rspec/expectations"
require "pundit/rspec"
