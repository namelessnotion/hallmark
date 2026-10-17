# frozen_string_literal: true

require "hallmark"

# A solver backend for tests without Java. Each check gets the verdict the
# table names (`:counterexample`, `:none`, or a String: unknown, for that
# reason); unnamed checks get `:none`. A counterexample is the captured
# Storefront witness (test/fixtures/storefront), renamed to the check, so it
# fits any check whose guard lets a seller's admin update another seller's
# product. Logs every model it was given and whether it was closed.
class FixtureSolver
  WITNESS = "safe_LinksController_update_write_Link"
  XML = File.expand_path("../fixtures/storefront/#{WITNESS}-solution-0.xml", __dir__)

  attr_reader :models

  def initialize(verdicts = {})
    @verdicts = verdicts
    @models = []
    @closed = false
  end

  def check(model)
    @models << model
    commands = model.checks.keys.map do |name|
      case (verdict = @verdicts.fetch(name, :none))
      when :counterexample then Hallmark::Receipt::Command.new(name, nil, instance(name))
      when String then Hallmark::Receipt::Command.new(name, nil, nil, verdict)
      else Hallmark::Receipt::Command.new(name, nil, nil)
      end
    end
    Hallmark::Receipt.new(commands)
  end

  def checks = @models.flat_map { |model| model.checks.keys }

  def close
    @closed = true
  end

  def closed? = @closed

  private

  def instance(name) = Hallmark::Receipt::Instance.parse(File.read(XML).gsub(WITNESS, name))
end
