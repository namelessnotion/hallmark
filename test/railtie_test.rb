# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# The Railtie loads config/hallmark.rb once the app has booted, and installs
# the collectors, in the test environment only. Each case boots a real Rails
# app in a child process.
class RailtieTest < Minitest::Test
  APP = File.join(ROOT, "test", "support", "rails_app.rb")
  CONFIG = "Hallmark.configure { |config| config.map { Shop.map(self) } }\n"

  # `models` maps file names to sources written under the app's app/models,
  # which Rails autoloads (or eager loads with `eager_load: true`).
  def boot(environment, mode: nil, config: CONFIG, models: {}, eager_load: false)
    Dir.mktmpdir("hallmark-app") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "hallmark.rb"), config)
      write_models(root, models)
      env = { "RAILS_ENV" => environment, "HALLMARK_MODE" => mode, "HALLMARK_STAMPS" => nil, "HALLMARK_RUN" => nil,
              "SHOP_EAGER_LOAD" => eager_load ? "1" : nil }
      output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), APP, root)
      assert_predicate status, :success?, error
      JSON.parse(output.lines.last).merge("routes" => routes_after_exit(root))
    end
  end

  # The routes the Railtie recorded when the child process exited.
  def routes_after_exit(root)
    dir = File.join(root, "tmp", "hallmark")
    return nil unless File.directory?(dir) && Hallmark::StampSet.files(dir).any?

    Hallmark::StampSet.load(dir).routes.map { |route| [route.entry_point, route.verb, route.path] }.sort
  end

  def write_models(root, models)
    return if models.empty?

    FileUtils.mkdir_p(File.join(root, "app", "models"))
    models.each { |name, source| File.write(File.join(root, "app", "models", name), source) }
  end

  WIDGET = { "widget.rb" => "class Widget; end\n" }.freeze
  BY_CONSTANT = "Hallmark.configure { |config| config.map { Shop.map(self); resource Widget } }\n"

  def test_collects_in_the_test_environment
    result = boot("test")

    assert result.fetch("active")
    assert_equal [200, 200], result.fetch("statuses")
    assert_equal [["PunditShop::LinksController#edit", "edit?", "allow"]], result.fetch("stamps")
    assert_equal ["PunditShop::LinksController#show"], result.fetch("unchecked")
  end

  def test_records_the_apps_routes_when_the_run_ends
    assert_equal [["PunditShop::LinksController#edit", "GET", "/links/:id/edit(.:format)"],
                  ["PunditShop::LinksController#show", "GET", "/links/:id(.:format)"]], boot("test").fetch("routes")
  end

  # Rails sets up autoloading after config initializers, so the mapping
  # loads after boot to name app classes by constant.
  def test_maps_app_models_by_constant
    [false, true].each do |eager_load|
      result = boot("test", config: BY_CONSTANT, models: WIDGET, eager_load: eager_load)

      assert result.fetch("active")
      assert_includes result.fetch("mapped"), "Widget"
      assert_equal [["PunditShop::LinksController#edit", "edit?", "allow"]], result.fetch("stamps")
    end
  end

  # With the collectors off the file is not loaded, so it never loads app
  # classes at development or console boot.
  def test_stays_off_in_other_environments
    result = boot("development", config: BY_CONSTANT, models: WIDGET)

    refute result.fetch("active")
    assert_nil result.fetch("mapped")
    assert_nil result.fetch("stamps")
  end

  def test_the_mode_overrides_the_environment
    refute boot("test", mode: "off").fetch("active")
    assert boot("development", mode: "test").fetch("active")
  end

  def test_the_file_can_still_turn_the_collectors_off
    result = boot("test",
                  config: "Hallmark.configure { |config| config.mode = \"off\"; config.map { Shop.map(self) } }\n")

    refute result.fetch("active")
    refute_nil result.fetch("mapped")
  end

  def test_enabled_by_mode_or_environment
    assert Hallmark::Collectors.enabled?(nil, "test")
    refute Hallmark::Collectors.enabled?(nil, "production")
    refute Hallmark::Collectors.enabled?("off", "test")
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Configuration.new.mode = "shadow" }
  end
end
