# typed: strict
# frozen_string_literal: true

require "json"

module Hallmark
  module Solver
    # Runs checks in a long-lived JVM (solver/src, built by
    # `hallmark install-sidecar`) that speaks line-delimited JSON-RPC over
    # stdio. The JVM starts on the first check and serves every analysis in
    # this process, so only the first check pays for its start.
    #
    # Supervision: the heap is capped (`c.sidecar_heap`, MB); each check gets
    # `c.timeout` seconds. Alloy cannot interrupt a running solver, so on a
    # timeout the sidecar answers unknown and exits, and if it does not answer
    # within GRACE seconds more the client kills it. A crash also makes the
    # check unknown. Either way the next check starts a fresh sidecar and
    # loads the model again.
    #
    # When that restart fails, or loading the model times out or crashes
    # (the same model would fail again), the rest of the run is unknown and
    # the verdicts so far are kept. The first start of the sidecar, and an
    # Alloy error in the model, still raise. Not thread-safe: use one per
    # thread.
    class Sidecar
      PROTOCOL = 1
      MAIN_CLASS = "hallmark.solver.Sidecar"
      # Seconds for the JVM to start and answer `version`
      START_TIMEOUT = 60
      # Seconds past the check timeout before the client stops waiting
      GRACE = 5

      # A model loaded into one particular sidecar process.
      Loaded = Struct.new(:model, :child, :id, keyword_init: true)

      attr_reader :timeout, :starts

      # `command` replaces the java command line and `grace` the GRACE wait,
      # for tests that run a fake sidecar.
      def initialize(config = Hallmark.configuration, command: nil, grace: GRACE)
        @java = config.java
        @jar = config.sidecar_jar
        @alloy_jar = config.alloy_jar
        @timeout = config.timeout
        @sat_solver = config.sat_solver
        @heap = config.sidecar_heap
        @command = command
        @grace = grace
        @child = nil
        @loaded = nil
        @starts = 0
        @next_id = 0
      end

      def available?
        return true if @command

        File.file?(@jar) && File.file?(@alloy_jar) && Solver.java_runs?(@java)
      end

      def command
        @command || [@java, "-Xmx#{@heap}m", "-XX:+UseSerialGC",
                     "-cp", [@jar, @alloy_jar].join(File::PATH_SEPARATOR),
                     MAIN_CLASS, "--solver", @sat_solver]
      end

      def check(model)
        catalog = File.read(CATALOG_PATH)
        names = model.checks.keys
        commands = []
        names.each_with_index do |name, index|
          ready = prepare(model, catalog)
          if ready.is_a?(String)
            # No sidecar for the rest of the run: those checks are unknown.
            commands.concat(names.drop(index).map { |rest| Receipt::Command.new(rest, nil, nil, ready) })
            break
          end

          commands << check_one(ready, name)
        end
        unload
        Receipt.new(commands, solver: @sat_solver)
      end

      # Sends one request and returns its result. Raises Timeout (after
      # killing the sidecar) when no answer comes within `wait` seconds,
      # Crash when it exits, and SolverError when it answers with an error.
      def call(method, params = {}, wait: @timeout)
        call_child(@child || start, method, params, wait)
      end

      def pid = @child&.pid
      def running? = !@child.nil?

      # Closing stdin tells the sidecar to exit; it is killed if it does not.
      def close
        child = @child
        @child = nil
        child&.finish
      end

      private

      # A running sidecar with the model loaded, or why there is none for the
      # rest of the run: a restart that failed, or a load that timed out or
      # crashed. The first start is not a restart, so its failure raises, as
      # does an Alloy error in the model. A sidecar that an earlier run left
      # stopped counts as a restart.
      def prepare(model, catalog)
        if @child.nil? && @starts.positive?
          begin
            start
          rescue SolverError => e
            return e.message
          end
        end
        loaded(model, catalog)
      rescue Timeout
        "timed out loading the model after #{@timeout} s"
      rescue Crash => e
        "#{e.message} while loading the model"
      end

      # The model, loaded into the running sidecar; a restarted sidecar has
      # lost it, so it is loaded again.
      def loaded(model, catalog)
        loaded = @loaded
        return loaded if loaded && loaded.model.equal?(model) && loaded.child.equal?(@child)

        result = call("load", { "source" => model.source, "modules" => { "catalog" => catalog } })
        @loaded = Loaded.new(model: model, child: @child, id: result.fetch("model_id"))
      end

      # Best-effort: unloading only frees memory, so a failure stops the
      # sidecar (the next run starts another) and keeps every verdict.
      def unload
        loaded = @loaded
        @loaded = nil
        return unless loaded && loaded.child.equal?(@child)

        call("unload", { "model_id" => loaded.id })
      rescue SolverError
        close
      end

      def check_one(loaded, name)
        params = { "model_id" => loaded.id, "command" => name, "timeout_ms" => @timeout * 1000 }
        verdict(name, call("check", params, wait: @timeout + @grace))
      rescue Timeout
        Receipt::Command.new(name, nil, nil, "timed out after #{@timeout} s")
      rescue Crash => e
        Receipt::Command.new(name, nil, nil, e.message)
      end

      def verdict(name, result)
        case result["verdict"]
        when "sat"
          instance = result.fetch("instance")
          Receipt::Command.new(name, nil, Receipt::Instance.new(instance.fetch("fields"), instance.fetch("skolems")))
        when "unsat" then Receipt::Command.new(name, nil, nil)
        when "unknown"
          # The sidecar exits after an unknown; the next check starts another.
          close
          reason = result["reason"].to_s
          Receipt::Command.new(name, nil, nil, reason == "timeout" ? "timed out after #{@timeout} s" : reason)
        else
          raise SolverError, "the sidecar returned no verdict for #{name}: #{result.inspect}"
        end
      end

      def start
        child = ChildProcess.spawn(command)
        @child = child
        @starts += 1
        handshake(child)
        child
      rescue SystemCallError => e
        raise SolverError, "cannot start the sidecar (#{command.first}): #{e.message}"
      end

      def handshake(child)
        version = call_child(child, "version", {}, START_TIMEOUT)
        return if version["protocol"] == PROTOCOL

        close
        raise SolverError, "the sidecar speaks protocol #{version["protocol"].inspect}, not #{PROTOCOL}; " \
                           "run `hallmark install-sidecar`"
      rescue Timeout, Crash => e
        raise SolverError, "the sidecar did not start: #{e.message}"
      end

      def call_child(child, method, params, wait)
        id = (@next_id += 1)
        deadline = ChildProcess.now + wait
        line = exchange(child, JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params }), deadline)
        raise Timeout, "the sidecar did not answer #{method} within #{wait} s" unless line

        response = JSON.parse(line)
        raise SolverError, "the sidecar answered request #{response["id"]}, not #{id}" unless response["id"] == id

        if (error = response["error"])
          raise SolverError, "the sidecar rejected #{method}: #{error["message"]}"
        end

        response.fetch("result")
      end

      # Writes one request and reads its answer. A sidecar that misses the
      # deadline is killed and one that exits is dropped, so the next call
      # starts another.
      def exchange(child, request, deadline)
        child.write_line(request)
        line = child.read_line(deadline)
        unless line
          @child = nil if @child.equal?(child)
          child.kill
        end
        line
      rescue Crash
        @child = nil if @child.equal?(child)
        raise
      end
    end
  end
end
