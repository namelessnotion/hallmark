# typed: strict
# frozen_string_literal: true

module Hallmark
  # REST serializer fields (phase 3 step 8, threat 4): for each entry point
  # that renders a record it authorizes (or a list it shows), each field of
  # the serializer with a field policy, or named by a restriction's
  # `fields:`, becomes a field exposure (step 4's
  # `safe_<Action>_read_<Resource>_<field>`), guarded by the entry point's
  # own exposures on that resource AND the rendering's condition AND the
  # field's, each by its lower bound (docs/adr/0003).
  class Inference
    # What the serializers leave open, by kind: never findings.
    # `unrendered` and `jbuilder` are counts.
    SerializerNotes = Struct.new(:unknown, :unauthorized, :nested, :unread, :unpoliced, :unrendered, :jbuilder,
                                 keyword_init: true) do
      def lists
        {
          "Renderings whose serializer Hallmark cannot tell" => unknown,
          "Rendered records the entry point does not authorize (not checked)" => unauthorized,
          "Records of other resources shown through associations (not checked)" => nested,
          "Fields whose condition Hallmark could not read (not checked)" => unread,
          "Conditional fields that read the viewer and have no field policy (declare `field_policy` to check " \
          "them)" => unpoliced
        }
      end

      def empty? = lists.values.all?(&:empty?) && unrendered.zero? && jbuilder.zero?
    end

    # One rendering's share of a field exposure: the field, the rendering,
    # the exposures it rests on, its guard (their AND with both conditions'
    # lower bounds) and the conditions as read.
    FieldShown = Struct.new(:field, :rendering, :base, :guard, :condition, keyword_init: true)

    attr_reader :serializer_notes

    private

    # Field exposures for the entry points among `exposures` that render
    # a serializer, and the notes on what was not checked.
    def serializer_exposures(exposures)
      extractor = @extractor
      serializers = extractor&.serializers
      return [] unless extractor && serializers

      fields = SerializerFields.new(@mapping, extractor, serializers, @coverage)
      @serializer_notes = fields.notes
      fields.exposures(exposures)
    end

    # Reads every entry point's renderings into field exposures and notes.
    class SerializerFields
      # Leaves that read the viewer, and words that say an unread call does.
      VIEWER = %i[logged_in owner role permitted member admin].freeze
      VIEWER_WORDS = /user|abilit|allowed|can\?|policy\(|scope|current_|account|member|owner|admin/i

      attr_reader :notes

      def initialize(mapping, extractor, serializers, coverage)
        @mapping = mapping
        @extractor = extractor
        @serializers = serializers
        @coverage = coverage
        @notes = SerializerNotes.new(unknown: [], unauthorized: [], nested: [], unread: [], unpoliced: [],
                                     unrendered: 0, jbuilder: serializers.jbuilder_views)
        @rendered = []
      end

      def exposures(exposures)
        found = Hash.new { |hash, key| hash[key] = [] }
        exposures.reject(&:field).map(&:action).uniq.sort.each do |entry_point|
          renderings_at(entry_point).each do |rendering|
            shown_fields(entry_point, rendering, exposures).each { |key, part| found[key] << part }
          end
        end
        @notes.unrendered = (@serializers.serializers - @rendered).size
        found.map { |(entry_point, resource, field), parts| field_exposure(entry_point, resource, field, parts) }
      end

      private

      def renderings_at(entry_point)
        read = @extractor.controllers.fetch(entry_point)
        return read.renderings if read

        endpoint = @extractor.grape&.endpoint_named(entry_point)
        endpoint ? endpoint.renderings : []
      end

      # The fields one rendering shows that need a check, by exposure key.
      def shown_fields(entry_point, rendering, exposures)
        resource = authorized_resource(entry_point, rendering, exposures)
        name = @serializers.resolve(rendering, resource)
        unless name
          @notes.unknown << "#{entry_point}: #{rendering.unknown || rendering.text} (#{rendering.location})"
          return {}
        end
        @rendered << name
        resource, base = rendered_base(entry_point, rendering, name, resource, exposures)
        if resource && base
          return parts(entry_point, rendering, @serializers.fields(name, resource, rendering), resource, base)
        end

        @notes.unauthorized << "#{entry_point}: #{rendering.text} shown by #{name} (#{rendering.location})"
        {}
      end

      # The resource shown and the exposures it rests on: a collection's
      # list, else the authorized record's exposures; no base when
      # neither is there.
      def rendered_base(entry_point, rendering, name, resource, exposures)
        shows = @serializers.resource_of(name)
        list = rendering.collection == true
        resource = list ? shows : resource || helper_resource(rendering, shows)
        [resource, resource && base_exposures(entry_point, resource, exposures, list: list)]
      end

      def parts(entry_point, rendering, fields, resource, base)
        condition = rendering_condition(entry_point, rendering, resource)
        base_guard = base.map(&:guard).reduce { |left, right| Guard.conjoin(left, right) } || Guard.new(:none)
        fields.each_with_object({}) do |field, found|
          guard = Guard.conjoin(condition, field.condition)
          next unless (lower = checked_lower(entry_point, field, resource, guard))

          found[[entry_point, resource, field.name]] =
            FieldShown.new(field: field, rendering: rendering, base: base, guard: Guard.conjoin(base_guard, lower),
                           condition: guard)
        end
      end

      # The lower bound a field is checked with; nil when it is a nested
      # record, needs no check, or shows nothing certain (noted).
      def checked_lower(entry_point, field, resource, guard)
        if field.nested?
          @notes.nested << "#{entry_point}: #{field.shown_by} shows #{field.resource}"
          return nil
        end
        return note_unpoliced(field) unless checked_field?(resource, field.name)

        lower = guard.lower
        return lower unless lower.kind == :never

        @coverage.observe_field("#{entry_point} #{field.serializer}##{field.name}", guard)
        line = "#{entry_point}: #{field.shown_by}"
        @notes.unread << line if guard.opaque? && !@notes.unread.include?(line)
        nil
      end

      # A field with a field policy, or one a restriction's `fields:` names.
      def checked_field?(resource, field)
        return true if @mapping.field_policy_for(resource, field)

        @mapping.restrictions.values.any? do |restriction|
          restriction.denials.any? do |denial|
            denial.resource == resource && denial.ops.include?(:read) && (denial.fields || []).include?(field)
          end
        end
      end

      # A conditional field that reads the viewer: where a field policy is
      # worth writing, since the app itself treats it as narrower than the
      # record. Always nil: nothing is checked.
      def note_unpoliced(field)
        condition = field.condition
        line = "#{field.shown_by}: #{condition}"
        @notes.unpoliced << line if viewer?(condition) && !@notes.unpoliced.include?(line)
        nil
      end

      # A leaf about the principal, or an unread call that names the user
      # or an ability outside the record's own attributes
      # (`record.user.invited?` reads the record, not the viewer).
      def viewer?(condition)
        condition.leaves.any? do |leaf|
          next true if VIEWER.include?(leaf.kind)

          leaf.kind == :opaque && leaf.operands[0].to_s.gsub(/\brecord(?:\.\w+[?!]?)*/, "").match?(VIEWER_WORDS)
        end
      end

      # The resource of the record an authorize call checks, when the
      # rendering shows that record: the rule's, else the loaded model's,
      # else the entry point's one resource.
      def authorized_resource(entry_point, rendering, exposures)
        authorization = rendering.authorization
        return nil unless authorization

        policy_resource(authorization) || mapped_model(rendering) || only_resource(entry_point, exposures)
      end

      def mapped_model(rendering)
        model = rendering.model
        model && @mapping.resources.key?(model) ? model : nil
      end

      def only_resource(entry_point, exposures)
        resources = exposures.select { |each| each.action == entry_point && !each.list? }.map(&:resource).uniq
        resources.size == 1 ? resources.first : nil
      end

      def policy_resource(authorization)
        policy = authorization.policy
        policy ? @extractor.policy_resource(policy, authorization.rule) : nil
      end

      # A Grape check made inside the helper that returns the rendered
      # record (GitLab's `user_project`), when it checks the serializer's
      # resource.
      def helper_resource(rendering, shows)
        return nil unless shows

        rendering.candidates.any? { |each| policy_resource(each) == shows } ? shows : nil
      end

      # What a request must pass before it renders: the entry point's
      # exposures on the record, all ops (a request that passes a write
      # check and then renders the record shows its fields to whoever
      # passed), or its list for a collection. Nil when there are none.
      def base_exposures(entry_point, resource, exposures, list:)
        found = exposures.grep(Exposure).select do |each|
          each.action == entry_point && each.resource == resource && each.field.nil? && each.list? == list
        end
        found.empty? ? nil : found
      end

      # The branches the rendering sits in, read as the controller's
      # checks are (Rails) or in the API class (Grape).
      def rendering_condition(entry_point, rendering, resource)
        rendering.branches.reduce(Guard.new(:none)) do |all, branch|
          guard = if rendering.kind == :rails
                    @extractor.controllers.branch_guard(entry_point, branch, resource)
                  else
                    @serializers.branch_guard(branch, resource)
                  end
          Guard.conjoin(all, guard)
        end
      end

      # One exposure per entry point, resource and field: the OR of the
      # renderings that show it.
      def field_exposure(entry_point, resource, field, parts)
        guard = parts.map(&:guard).reduce { |left, right| Guard.disjoin(left, right) } || Guard.new(:never)
        Exposure.new(action: entry_point, op: :read, resource: resource, guard: guard, field: field,
                     basis: parts.map { |part| shown_basis(part) }.uniq.join("; "), locations: locations(parts),
                     rules: parts.flat_map { |part| part.base.flat_map(&:rules).compact }.uniq,
                     shown_by: parts.map { |part| part.field.shown_by }.uniq.join(", "))
      end

      # The field first (where a fix goes), then the rendering, then what
      # the base exposures point at.
      def locations(parts)
        found = parts.flat_map do |part|
          [part.field.location, part.rendering.location, *part.base.flat_map { |each| each.locations || [] }]
        end
        found.uniq.grep(/\A.+:\d+\z/)
      end

      def shown_basis(part)
        field = part.field
        where = " where #{part.condition}" unless part.condition.kind == :none
        [*part.base.filter_map(&:basis), "shown by #{field.serializer} (#{field.location})#{where}"].join("; ")
      end
    end
  end
end
