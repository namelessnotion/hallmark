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

  # Installs the collectors with a fresh stamp store for the block, then
  # returns what they stamped. Needs test/support/shop.rb.
  def collect(current_tenant: :seller, sample_rate: 1.0)
    Dir.mktmpdir("hallmark-stamps") do |dir|
      mapping = Shop.map(Hallmark::Mapping.new, current_tenant: current_tenant)
      Hallmark::Collectors.install!(mapping: mapping, store: Hallmark::StampStore.new(dir, run: "test"),
                                    sample_rate: sample_rate)
      begin
        yield
      ensure
        Hallmark::Collectors.uninstall!
      end
      # Nothing sampled writes no file.
      Hallmark::StampSet.files(dir).empty? ? Hallmark::StampSet.new : Hallmark::StampSet.load(dir)
    end
  end

  # Integration tests need Java 17+ and the Alloy jar (`hallmark install-alloy`).
  def require_solver!
    solver = Hallmark::Solver::CLI.new
    skip "Alloy jar or Java not available; run `bin/hallmark install-alloy`" unless solver.available?
    solver
  end

  # Sidecar integration tests also need the built sidecar (`hallmark install-sidecar`).
  def require_sidecar!
    sidecar = Hallmark::Solver::Sidecar.new
    skip "solver sidecar not built; run `bin/hallmark install-sidecar`" unless sidecar.available?
    sidecar
  end

  # A Sidecar client talking to test/support/fake_sidecar.rb in MODE, which
  # keeps its start counter and request log in `state` (a directory).
  def fake_sidecar(mode, state, grace: 0)
    command = [RbConfig.ruby, File.join(ROOT, "test", "support", "fake_sidecar.rb"), mode, state]
    Hallmark::Solver::Sidecar.new(Hallmark.configuration, command: command, grace: grace)
  end
end

Minitest::Test.include HallmarkTestHelpers
