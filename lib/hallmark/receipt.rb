# frozen_string_literal: true

require "json"
require "rexml/document"

module Hallmark
  # Reads what `alloy exec --type xml` writes into its output directory:
  #
  #   receipt.json                    one entry per command; a check with a
  #                                   counterexample carries a `solution`
  #   <command>-solution-0.xml        the counterexample itself
  #
  # The verdict comes from receipt.json. The witness comes from the XML,
  # because the receipt's own `values` map keys atoms by their parent
  # signature and silently drops some of them.
  class Receipt
    # One Alloy instance in the A4 XML format.
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
        @fields.fetch(name, []).select { |tuple| tuple.first == atom }.map(&:last)
      end
    end

    Command = Struct.new(:name, :source, :instance) do
      def counterexample? = !instance.nil?
    end

    def self.load(directory)
      data = JSON.parse(File.read(File.join(directory, "receipt.json")))
      new(data) do |name|
        path = File.join(directory, "#{name}-solution-0.xml")
        raise SolverError, "Alloy reported a counterexample for #{name} but wrote no instance" unless File.file?(path)

        Instance.parse(File.read(path))
      end
    end

    attr_reader :commands, :solver

    # The block loads the instance for a command that has a counterexample.
    def initialize(data, &load_instance)
      @solver = data["solver"]
      @commands = data.fetch("commands").to_h do |name, command|
        instance = load_instance.call(name) if Array(command["solution"]).any?
        [name, Command.new(name, command["source"], instance)]
      end
    end

    def [](name) = @commands[name]
  end
end
