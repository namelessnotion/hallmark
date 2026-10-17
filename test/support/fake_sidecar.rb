# frozen_string_literal: true

# A stand-in for the Java sidecar that speaks the same line-delimited
# JSON-RPC, so the Ruby client is tested without Java. Verdicts come from the
# captured Alloy runs in test/fixtures (every receipt.json there, keyed by
# command name).
#
#   ruby fake_sidecar.rb MODE STATE_DIR
#
# STATE_DIR keeps a start counter, so a mode ending in "-once" misbehaves in
# the first process only, and requests.jsonl, a log of every request.
#
#   ok             answer from the fixtures
#   hang-once      never answer the first check
#   unknown-once   answer the first check unknown (timeout), then exit 75
#   crash-once     exit 3 on the first check, after a line on stderr
#   die            exit 1 before answering anything
#   protocol-0     claim protocol version 0
#   reject         reject every load as an Alloy error
#   load-crash     exit 3 on every load, after a line on stderr
#   load-hang-second  never answer the first check; in later processes,
#                  never answer the load
#   crash-then-die exit 3 on the first check; later processes exit 1 before
#                  answering anything
#   unload-crash   exit 3 on unload

require "json"
require "rexml/document"

FIXTURES = File.expand_path("../fixtures", __dir__)
mode, state = ARGV
counter = File.join(state, "starts")
start = (File.exist?(counter) ? Integer(File.read(counter)) : 0) + 1
File.write(counter, start.to_s)

if mode == "die" || (mode == "crash-then-die" && start > 1)
  warn "fake sidecar: refusing to start"
  exit 1
end

def relations(document, tag)
  result = Hash.new { |hash, key| hash[key] = [] }
  document.elements.each("alloy/instance/#{tag}") do |element|
    element.elements.each("tuple") do |tuple|
      result[element.attributes["label"]] << tuple.elements.to_a("atom").map { |atom| atom.attributes["label"] }
    end
  end
  result
end

def instance(name)
  path = Dir[File.join(FIXTURES, "*", "#{name}-solution-0.xml")].first
  return nil unless path

  document = REXML::Document.new(File.read(path))
  { "fields" => relations(document, "field"), "skolems" => relations(document, "skolem") }
end

# Answers requests in one mode; `start` counts the processes started, from 1.
class FakeSidecar
  def initialize(mode, state, start:)
    @mode = mode
    @start = start
    @log = File.join(state, "requests.jsonl")
    @misbehave = !mode.end_with?("-once") || start == 1
    @known = Dir[File.join(FIXTURES, "*", "receipt.json")].flat_map do |path|
      JSON.parse(File.read(path))["commands"].keys
    end
    @models = 0
  end

  def serve(input)
    input.each_line do |line|
      File.open(@log, "a") { |log| log.puts(line) }
      request = JSON.parse(line)
      respond(request["id"], request["method"], request["params"] || {})
    end
  end

  private

  def respond(request_id, method, params)
    case method
    when "version"
      answer(request_id, { "protocol" => @mode == "protocol-0" ? 0 : 1, "alloy" => "fake", "solver" => "sat4j" })
    when "load" then load(request_id)
    when "check" then check(request_id, params)
    when "unload" then unload(request_id)
    else answer(request_id, error: { "code" => -32_601, "message" => "unknown method" })
    end
  end

  def load(request_id)
    if @mode == "reject"
      return answer(request_id, error: { "code" => 1, "message" => "Syntax error at line 1 column 1" })
    end

    crash if @mode == "load-crash"
    sleep if @mode == "load-hang-second" && @start > 1

    answer(request_id, { "model_id" => "m#{@models += 1}", "commands" => @known })
  end

  def check(request_id, params)
    misbehave(request_id, params) if @misbehave
    name = params["command"]
    unless @known.include?(name)
      return answer(request_id, error: { "code" => -32_602, "message" => "no command #{name}" })
    end

    found = instance(name)
    answer(request_id, found ? { "verdict" => "sat", "instance" => found } : { "verdict" => "unsat" })
  end

  def unload(request_id)
    exit 3 if @mode == "unload-crash"

    answer(request_id, {})
  end

  def misbehave(request_id, params)
    case @mode
    when "hang-once" then sleep
    when "load-hang-second" then sleep if @start == 1
    when "unknown-once"
      answer(request_id, { "verdict" => "unknown", "reason" => "timeout", "ms" => params["timeout_ms"] })
      exit 75
    when "crash-once" then crash
    when "crash-then-die" then crash if @start == 1
    end
  end

  def crash
    warn "fake sidecar: java.lang.OutOfMemoryError: Java heap space"
    exit 3
  end

  def answer(request_id, result = nil, error: nil)
    response = { "jsonrpc" => "2.0", "id" => request_id }
    error ? response["error"] = error : response["result"] = result
    $stdout.puts(JSON.generate(response))
    $stdout.flush
  end
end

FakeSidecar.new(mode, state, start: start).serve($stdin)
