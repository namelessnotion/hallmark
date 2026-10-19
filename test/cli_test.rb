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
