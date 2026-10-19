# typed: strict
# frozen_string_literal: true

require "json"

module Hallmark
  # One distinct authorization decision: which rule an entry point called,
  # whether it allowed, and the facts that held, as booleans and role names.
  # Collectors build one per decision (an event); equal events collapse into
  # one stamp. Stamps hold no record or user ids.
  #
  # Facts are nil when they do not apply: record facts for a rule checked
  # against a class (`authorize! Link, to: :create?`), tenant facts when the
  # resource lives outside tenants or the mapping has no current tenant.
  # `outside_tenants` is nil in lines written before Oct 18, 2026; Inference
  # reads a record-level stamp of a `tenant_optional:` resource with no
  # `record_roles` as outside tenants.
  Stamp = Struct.new(
    :entry_point,       # "LinksController#update", or nil outside a request (a policy spec, a service object)
    :policy,            # "LinkPolicy"
    :rule,              # "update?", or a DeclarativePolicy ability such as "read_project"
    :resource,          # the record's class name, or the class or Symbol checked in place of a record
    :class_level,       # checked against a class, a Symbol (a headless or global policy) or nil
    :enforced,          # an `authorize` call, which denies the request; false for queries such as `allowed_to?`
    :decision,          # "allow" or "deny"
    :raised,            # class name of an exception raised inside the rule, stamped as a deny
    :logged_in,
    :owner,             # the user owns the record
    :public_record,
    :member,            # the user holds a role in the record's tenant
    :in_current_tenant, # the record lives in the current tenant
    :outside_tenants,   # the record lives in no tenant; nil unless its resource is mapped with `tenant_optional:`
    :granted,           # a mapped grant covers this rule's op for the roles that count
    :permitted,         # the user holds an explicit permission on the record for this rule's op
    :roles,             # roles held outside any tenant
    :record_roles,      # roles held in the record's tenant
    :current_roles,     # roles held in the current tenant
    keyword_init: true
  ) do
    def allow? = decision == "allow"
    def rule_key = "#{policy}##{rule}"

    def to_json_line
      JSON.generate({ "type" => "stamp" }.merge(to_h.transform_keys(&:to_s)))
    end
  end

  # An entry point that finished without any authorization call (threat 10),
  # with the response status and the request's HTTP verb ("GET"). Both are
  # nil in lines written before Oct 17, 2026, and for an event recorded
  # outside a controller.
  Unchecked = Struct.new(:entry_point, :status, :verb, keyword_init: true) do
    def to_json_line
      JSON.generate({ "type" => "unchecked", "entry_point" => entry_point, "status" => status, "verb" => verb })
    end
  end

  # A route the app defines, as "Controller#action" with its HTTP verb
  # ("GET", "GET|POST", or "" for any) and path. The Railtie records every
  # route at the end of a test run, so Hallmark knows the entry points no
  # test reached (phase 2 step 3).
  Route = Struct.new(:entry_point, :verb, :path, keyword_init: true) do
    def to_json_line
      JSON.generate({ "type" => "route", "entry_point" => entry_point, "verb" => verb, "path" => path })
    end
  end

  # The stamps of one run, read back from JSONL.
  class StampSet
    attr_reader :stamps, :unchecked, :routes

    # A JSONL file, or a directory of them (`tmp/hallmark`), in which case
    # every file of the latest run (the one with the most recently written
    # file) is read: parallel test workers each write their own file of the
    # same run. `run:` picks another run.
    def self.load(path, run: nil)
      files = files(path, run: run)
      if files.empty?
        raise Error, "no stamps found in #{path}#{" for run #{run}" if run}; " \
                     "run the test suite with Hallmark's collectors installed"
      end

      read(files)
    end

    # The JSONL files `load` reads: the path itself, or the files of one run
    # in a directory (unless `run:` names one, the latest: the run with the
    # most recently written file); none when the path does not exist.
    def self.files(path, run: nil)
      return File.exist?(path) ? [path] : [] unless File.directory?(path)

      runs = Dir[File.join(path, "stamps-*.jsonl")].group_by { |file| File.basename(file)[/\Astamps-([^-]+)-/, 1] }
      key = run || latest(runs)
      key ? runs.fetch(key, []).sort : []
    end

    # The run whose newest file has the newest mtime, ties broken by run id.
    # Run ids do not order runs: HALLMARK_RUN can be any word ("ci"), and a
    # string comparison puts it after every timestamp. Files that do not
    # match the naming pattern (a nil id) are ignored, and so is a file that
    # disappears between the listing and its mtime.
    def self.latest(runs)
      written = runs.filter_map do |id, files|
        newest = files.filter_map do |file|
          File.mtime(file)
        rescue Errno::ENOENT
          nil
        end.max
        [newest, id] if id && newest
      end
      written.max_by { |newest, id| [newest, id] }&.last
    end
    private_class_method :latest

    def self.read(files) = parse(files.flat_map { |file| File.readlines(file, chomp: true) })

    def self.parse(lines)
      stamps = []
      unchecked = []
      routes = []
      lines.each do |line|
        next if line.strip.empty?

        data = JSON.parse(line)
        case data["type"]
        when "stamp"
          stamps << Stamp.new(**data.slice(*Stamp.members.map(&:to_s)).transform_keys(&:to_sym))
        when "unchecked"
          unchecked << Unchecked.new(entry_point: data.fetch("entry_point").to_s, status: data["status"],
                                     verb: data["verb"])
        when "route"
          routes << Route.new(entry_point: data.fetch("entry_point").to_s, verb: data["verb"].to_s,
                              path: data["path"].to_s)
        end
      end
      new(stamps, unchecked, routes)
    end

    def initialize(stamps = [], unchecked = [], routes = [])
      @stamps = stamps.uniq
      @unchecked = unchecked.uniq
      @routes = routes.uniq
    end
  end
end
