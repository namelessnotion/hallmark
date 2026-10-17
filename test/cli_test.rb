# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

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
