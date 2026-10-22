# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "fileutils"

# bin/hallmark in a child process. Errors here stop before the solver, so no
# Java is needed.
class CLITest < Minitest::Test
  BIN = File.join(ROOT, "bin", "hallmark")

  def hallmark(*)
    Open3.capture3(RbConfig.ruby, BIN, *)
  end

  # The CLI runs outside the app, so it cannot load a class the Railtie
  # would autoload; it says to name the class in a string.
  def test_a_mapping_naming_an_app_class_by_constant_gets_a_clear_error
    Dir.mktmpdir("hallmark-cli") do |dir|
      file = File.join(dir, "hallmark.rb")
      File.write(file, "Hallmark.configure { |c| c.map { resource Widget } }\n")
      _output, error, status = hallmark("check", file)

      assert_equal 2, status.exitstatus
      assert_match(/names the class Widget, which the hallmark command cannot load/, error)
      assert_match(/resource "Widget"/, error)
    end
  end

  def test_extract_prints_the_guards_read_from_the_examples_policy_code
    output, _error, status = hallmark("extract", File.join(ROOT, "examples", "storefront", "hallmark.rb"))

    assert_predicate status, :success?
    assert_includes output, "LinkPolicy#update? (app/policies/link_policy.rb:11; on Link)\n  " \
                            "(logged_in & (role(:owner, tenant: :current) | role(:admin, tenant: :current)))"
    assert_includes output, "list LinkPolicy#Scope#resolve (app/policies/link_policy.rb:36; on Link)\n  member"
  end

  # config/hallmark.rb belongs to the app one directory up; unread calls
  # print with both bounds.
  def test_extract_reads_the_app_a_config_file_belongs_to
    Dir.mktmpdir("hallmark-cli") do |dir|
      FileUtils.mkdir_p([File.join(dir, "config"), File.join(dir, "app", "policies")])
      File.write(File.join(dir, "config", "hallmark.rb"), "Hallmark.configure { |c| c.map { resource \"Post\" } }\n")
      File.write(File.join(dir, "app", "policies", "post_policy.rb"),
                 "class PostPolicy\n  def update?\n    user && user.beta?\n  end\nend\n")
      output, _error, status = hallmark("extract", File.join(dir, "config", "hallmark.rb"))

      assert_predicate status, :success?
      assert_includes output, "PostPolicy#update? (app/policies/post_policy.rb:2; on Post)"
      assert_includes output,
                      "  lower: never\n  upper: logged_in\n  not read: `user.beta?` (app/policies/post_policy.rb:3)"
    end
  end

  # A deny the code explains in the older run, a query (no entry point, so
  # no solver) the code allows denied in it; HALLMARK_RUN picks the run.
  def test_check_fails_on_drift_in_the_run_hallmark_run_names
    Dir.mktmpdir("hallmark-cli") do |dir|
      config = drift_app(dir)
      stamps = File.join(dir, "tmp", "hallmark")
      write_run(stamps, "old", owner: true, mtime: Time.now - 60)
      write_run(stamps, "new", owner: false, mtime: Time.now)

      output, _error, status = hallmark_in(stamps, nil, "check", config)

      assert_equal 0, status.exitstatus, output
      output, _error, status = hallmark_in(stamps, "old", "check", config)

      assert_equal 1, status.exitstatus, output
      assert_includes output, "DRIFT PostPolicy#update? (Post) at app/policies/post_policy.rb:2: denied, but its " \
                              "code allows wherever (logged_in & owner) (lower bound), true here\n      facts: " \
                              "logged_in & owner\n      stamped at: outside a request"
      _output, error, status = hallmark_in(stamps, "missing", "check", config)

      assert_equal 2, status.exitstatus
      assert_match(/no stamps found in .* for run missing/, error)
    end
  end

  def hallmark_in(stamps, run, *)
    Open3.capture3({ "HALLMARK_STAMPS" => stamps, "HALLMARK_RUN" => run, "HALLMARK_ROOT" => nil }, RbConfig.ruby, BIN,
                   *)
  end

  def drift_app(dir)
    FileUtils.mkdir_p([File.join(dir, "config"), File.join(dir, "app", "policies")])
    File.write(File.join(dir, "app", "policies", "post_policy.rb"),
               "class PostPolicy\n  def update?\n    user && record.user == user\n  end\nend\n")
    File.join(dir, "config", "hallmark.rb").tap do |file|
      File.write(file, "Hallmark.configure { |c| c.map { resource \"Post\", owner: :user } }\n")
    end
  end

  def write_run(stamps, run, owner:, mtime:)
    FileUtils.mkdir_p(stamps)
    file = File.join(stamps, "stamps-#{run}-1.jsonl")
    stamp = Hallmark::Stamp.new(policy: "PostPolicy", rule: "update?", resource: "Post", class_level: false,
                                enforced: false, decision: "deny", logged_in: true, owner: owner, roles: [])
    File.write(file, "#{stamp.to_json_line}\n")
    File.utime(mtime, mtime, file)
  end

  def test_other_errors_in_the_file_are_not_reworded
    Dir.mktmpdir("hallmark-cli") do |dir|
      file = File.join(dir, "hallmark.rb")
      File.write(file, "Hallmark.configure(&:unknown_setting)\n")
      _output, error, status = hallmark("model", file)

      refute_predicate status, :success?
      assert_match(/NoMethodError/, error)
      refute_match(/names the class/, error)
    end
  end
end
