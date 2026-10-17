# typed: strict
# frozen_string_literal: true

require "json"
require "rexml/document"

module Hallmark
  # The verdicts of one solver run. `Receipt.load` reads what
  # `alloy exec --type xml` writes into its output directory:
  #
  #   receipt.json                    one entry per command; a check with a
  #                                   counterexample carries a `solution`
  #   <command>-solution-0.xml        the counterexample itself
  #
  # The verdict comes from receipt.json. The witness comes from the XML,
  # because the receipt's own `values` map keys atoms by their parent
  # signature and silently drops some of them.
  class Receipt
    # One Alloy instance: field and skolem tuples keyed by label, parsed from
    # the A4 XML the CLI writes or sent as JSON by the sidecar.
    class Instance
      def self.parse(xml)
        document = REXML::Document.new(xml)
        new(relations(document, "field"), relations(document, "skolem"))
      end

      def self.relations(document, tag)
        result = Hash.new { |hash, key| hash[key] = [] }
        document.elements.each("alloy/instance/#{tag}") do |element|
          element.elements.each("tuple") do |tuple|
            result[element.attributes["label"]] << tuple.elements.to_a("atom").map { |atom| atom.attributes["label"] }
          end
        end
        result.default_proc = nil
        result
      end
      private_class_method :relations

      def initialize(fields, skolems)
        @fields = fields
        @skolems = skolems
      end

      # First atom bound to a skolem, e.g. "$safe_x_p" -> "catalog/User$0"
      def skolem(name)
        @skolems.fetch(name, []).dig(0, 0)
      end

      # Targets of a binary field on an atom, e.g. field("Post$0", "owner")
      def field(atom, name)
        @fields.fetch(name, []).filter_map { |source, target| target if source == atom }
      end

      # Sources of a binary field pointing at an atom, e.g.
      # sources("member", "catalog/User$0") -> ["catalog/Membership$1"]
      def sources(name, atom)
        @fields.fetch(name, []).filter_map { |source, target| source if target == atom }
      end
    end

    # One check's result: a counterexample (instance), none within scope, or
    # unknown when the solver gave no verdict (reason says why, such as a
    # timeout). An unknown is never read as "no counterexample".
    Command = Struct.new(:name, :source, :instance, :reason) do
      def counterexample? = !instance.nil?
      def unknown? = !reason.nil?
    end

    def self.load(directory)
      data = JSON.parse(File.read(File.join(directory, "receipt.json")))
      from_data(data) do |name|
        path = File.join(directory, "#{name}-solution-0.xml")
        raise SolverError, "Alloy reported a counterexample for #{name} but wrote no instance" unless File.file?(path)

        Instance.parse(File.read(path))
      end
    end

    # A receipt.json as the Alloy CLI writes it. The block loads the instance
    # for a command that has a counterexample.
    def self.from_data(data, &load_instance)
      commands = data.fetch("commands").map do |name, command|
        instance = load_instance.call(name) if Array(command["solution"]).any?
        Command.new(name, command["source"], instance)
      end
      new(commands, solver: data["solver"])
    end

    # The receipt of a run with no checks.
    def self.empty = new([])

    # Every named check without a verdict, for a run that stopped before
    # answering any of them.
    def self.unknown(names, reason) = new(names.map { |name| Command.new(name, nil, nil, reason) })

    attr_reader :commands, :solver

    def initialize(commands, solver: nil)
      @solver = solver
      @commands = commands.to_h { |command| [command.name, command] }
    end

    def [](name) = @commands[name]
  end
end
