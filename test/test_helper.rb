# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hallmark"
require "minitest/autorun"

module HallmarkTestHelpers
  ROOT = File.expand_path("..", __dir__)
  FIXTURES = File.join(ROOT, "test", "fixtures")

  def setup
    super
    Hallmark.reset!
  end

  def load_example(name)
    load File.join(ROOT, "examples", name)
    Hallmark.analyses.last
  end

  # Integration tests need Java 17+ and the Alloy jar (`hallmark install-alloy`).
  def require_solver!
    solver = Hallmark::Solver::CLI.new
    skip "Alloy jar or Java not available; run `exe/hallmark install-alloy`" unless solver.available?
    solver
  end
end

Minitest::Test.include HallmarkTestHelpers
