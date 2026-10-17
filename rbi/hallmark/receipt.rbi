# typed: strict

module Hallmark
  class Receipt
    # Tuples of atom labels, keyed by relation label
    Relations = T.type_alias { T::Hash[String, T::Array[T::Array[String]]] }

    class Instance
      sig { params(xml: String).returns(Instance) }
      def self.parse(xml); end

      sig { params(document: REXML::Document, tag: String).returns(Relations) }
      def self.relations(document, tag); end

      sig { params(fields: Relations, skolems: Relations).void }
      def initialize(fields, skolems)
        @fields = T.let(T.unsafe(nil), Relations)
        @skolems = T.let(T.unsafe(nil), Relations)
      end

      sig { params(name: String).returns(T.nilable(String)) }
      def skolem(name); end

      sig { params(atom: String, name: String).returns(T::Array[String]) }
      def field(atom, name); end

      sig { params(name: String, atom: String).returns(T::Array[String]) }
      def sources(name, atom); end
    end

    class Command
      sig { returns(String) }
      def name; end

      sig { returns(T.nilable(String)) }
      def source; end

      sig { returns(T.nilable(Instance)) }
      def instance; end

      # Why there is no verdict; nil when there is one
      sig { returns(T.nilable(String)) }
      def reason; end

      sig do
        params(name: String, source: T.nilable(String), instance: T.nilable(Instance), reason: T.nilable(String)).void
      end
      def initialize(name, source, instance, reason = nil); end

      sig { returns(T::Boolean) }
      def counterexample?; end

      sig { returns(T::Boolean) }
      def unknown?; end
    end

    sig { params(directory: String).returns(Receipt) }
    def self.load(directory); end

    sig do
      params(
        data: T::Hash[String, T.untyped],
        load_instance: T.proc.params(name: String).returns(Instance)
      ).returns(Receipt)
    end
    def self.from_data(data, &load_instance); end

    sig { returns(Receipt) }
    def self.empty; end

    sig { params(names: T::Array[String], reason: String).returns(Receipt) }
    def self.unknown(names, reason); end

    sig { returns(T::Hash[String, Command]) }
    attr_reader :commands

    sig { returns(T.nilable(String)) }
    attr_reader :solver

    sig { params(commands: T::Array[Command], solver: T.nilable(String)).void }
    def initialize(commands, solver: nil)
      @solver = T.let(T.unsafe(nil), T.nilable(String))
      @commands = T.let(T.unsafe(nil), T::Hash[String, Command])
    end

    sig { params(name: String).returns(T.nilable(Command)) }
    def [](name); end
  end
end
