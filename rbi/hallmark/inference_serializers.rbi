# typed: strict

module Hallmark
  class Inference
    class SerializerNotes
      sig { returns(T::Array[String]) }
      def unknown; end

      sig { returns(T::Array[String]) }
      def unauthorized; end

      sig { returns(T::Array[String]) }
      def nested; end

      sig { returns(T::Array[String]) }
      def unread; end

      sig { returns(T::Array[String]) }
      def unpoliced; end

      sig { returns(Integer) }
      def unrendered; end

      sig { params(count: Integer).returns(Integer) }
      def unrendered=(count); end

      sig { returns(Integer) }
      def jbuilder; end

      sig do
        params(unknown: T::Array[String], unauthorized: T::Array[String], nested: T::Array[String],
               unread: T::Array[String], unpoliced: T::Array[String], unrendered: Integer, jbuilder: Integer).void
      end
      def initialize(unknown:, unauthorized:, nested:, unread:, unpoliced:, unrendered:, jbuilder:); end

      # Each list by its title
      sig { returns(T::Hash[String, T::Array[String]]) }
      def lists; end

      sig { returns(T::Boolean) }
      def empty?; end
    end

    class FieldShown
      sig { returns(Extractor::Serializers::Field) }
      def field; end

      sig { returns(Extractor::Serializers::Rendering) }
      def rendering; end

      sig { returns(T::Array[Exposure]) }
      def base; end

      sig { returns(Guard) }
      def guard; end

      sig { returns(Guard) }
      def condition; end

      sig do
        params(field: Extractor::Serializers::Field, rendering: Extractor::Serializers::Rendering,
               base: T::Array[Exposure], guard: Guard, condition: Guard).void
      end
      def initialize(field:, rendering:, base:, guard:, condition:); end
    end

    # Nil until inference ran over an app with serializer directories
    sig { returns(T.nilable(SerializerNotes)) }
    attr_reader :serializer_notes

    private

    sig { params(exposures: T::Array[AnyExposure]).returns(T::Array[Exposure]) }
    def serializer_exposures(exposures); end

    class SerializerFields
      VIEWER = T.let(T.unsafe(nil), T::Array[Symbol])
      VIEWER_WORDS = T.let(T.unsafe(nil), Regexp)

      sig { returns(SerializerNotes) }
      attr_reader :notes

      sig do
        params(mapping: Mapping, extractor: Extractor, serializers: Extractor::Serializers, coverage: Coverage).void
      end
      def initialize(mapping, extractor, serializers, coverage)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @extractor = T.let(T.unsafe(nil), Extractor)
        @serializers = T.let(T.unsafe(nil), Extractor::Serializers)
        @coverage = T.let(T.unsafe(nil), Coverage)
        @notes = T.let(T.unsafe(nil), SerializerNotes)
        @rendered = T.let(T.unsafe(nil), T::Array[String])
      end

      sig { params(exposures: T::Array[AnyExposure]).returns(T::Array[Exposure]) }
      def exposures(exposures); end

      private

      sig { params(entry_point: String).returns(T::Array[Extractor::Serializers::Rendering]) }
      def renderings_at(entry_point); end

      # [entry point, resource, field] => the rendering's share
      Key = T.type_alias { [String, String, String] }

      sig do
        params(entry_point: String, rendering: Extractor::Serializers::Rendering, exposures: T::Array[AnyExposure])
          .returns(T::Hash[Key, FieldShown])
      end
      def shown_fields(entry_point, rendering, exposures); end

      sig do
        params(entry_point: String, rendering: Extractor::Serializers::Rendering, name: String,
               resource: T.nilable(String), exposures: T::Array[AnyExposure])
          .returns([T.nilable(String), T.nilable(T::Array[Exposure])])
      end
      def rendered_base(entry_point, rendering, name, resource, exposures); end

      sig do
        params(entry_point: String, rendering: Extractor::Serializers::Rendering,
               fields: T::Array[Extractor::Serializers::Field], resource: String, base: T::Array[Exposure])
          .returns(T::Hash[Key, FieldShown])
      end
      def parts(entry_point, rendering, fields, resource, base); end

      sig do
        params(entry_point: String, field: Extractor::Serializers::Field, resource: String, guard: Guard)
          .returns(T.nilable(Guard))
      end
      def checked_lower(entry_point, field, resource, guard); end

      sig { params(resource: String, field: String).returns(T::Boolean) }
      def checked_field?(resource, field); end

      sig { params(field: Extractor::Serializers::Field).returns(NilClass) }
      def note_unpoliced(field); end

      sig { params(condition: Guard).returns(T::Boolean) }
      def viewer?(condition); end

      sig do
        params(entry_point: String, rendering: Extractor::Serializers::Rendering, exposures: T::Array[AnyExposure])
          .returns(T.nilable(String))
      end
      def authorized_resource(entry_point, rendering, exposures); end

      sig { params(rendering: Extractor::Serializers::Rendering).returns(T.nilable(String)) }
      def mapped_model(rendering); end

      sig { params(entry_point: String, exposures: T::Array[AnyExposure]).returns(T.nilable(String)) }
      def only_resource(entry_point, exposures); end

      sig { params(authorization: Extractor::Controllers::Authorization).returns(T.nilable(String)) }
      def policy_resource(authorization); end

      sig { params(rendering: Extractor::Serializers::Rendering, shows: T.nilable(String)).returns(T.nilable(String)) }
      def helper_resource(rendering, shows); end

      sig do
        params(entry_point: String, resource: String, exposures: T::Array[AnyExposure], list: T::Boolean)
          .returns(T.nilable(T::Array[Exposure]))
      end
      def base_exposures(entry_point, resource, exposures, list:); end

      sig { params(entry_point: String, rendering: Extractor::Serializers::Rendering, resource: String).returns(Guard) }
      def rendering_condition(entry_point, rendering, resource); end

      sig { params(entry_point: String, resource: String, field: String, parts: T::Array[FieldShown]).returns(Exposure) }
      def field_exposure(entry_point, resource, field, parts); end

      sig { params(parts: T::Array[FieldShown]).returns(T::Array[String]) }
      def locations(parts); end

      sig { params(part: FieldShown).returns(String) }
      def shown_basis(part); end
    end
  end
end
