# frozen_string_literal: true

require 'json'

# Public: Allows to resolve configuration sourced from `config/vite.json` and
# environment variables, combining them with the default options.
class ViteRuby::Config
  def protocol
    https ? 'https' : 'http'
  end

  def host_with_port
    "#{ host }:#{ port }"
  end

  # Internal: Path where Vite outputs the manifest file.
  def manifest_path
    build_output_dir.join('manifest.json')
  end

  # Internal: Path where vite-plugin-ruby outputs the assets manifest file.
  def assets_manifest_path
    build_output_dir.join('manifest-assets.json')
  end

  # Public: The directory where Vite will store the built assets.
  def build_output_dir
    root.join(public_dir, public_output_dir)
  end

  # Public: The directory where the entries are located.
  def resolved_entrypoints_dir
    vite_root_dir.join(entrypoints_dir)
  end

  # Internal: The directory where Vite stores its processing cache.
  def vite_cache_dir
    root.join('node_modules/.vite')
  end

  # Public: The directory that Vite uses as root.
  def vite_root_dir
    root.join(source_code_dir)
  end

  # Public: Loads an optional config/vite.rb file that can modify ViteRuby.env
  def load_ruby_config
    rb_config_path = File.expand_path(config_path.sub(/.json$/, '.rb'), root)
    load rb_config_path if File.exist?(rb_config_path)
  end

  # Public: Sets additional environment variables for vite-plugin-ruby.
  def to_env
    CONFIGURABLE_WITH_ENV.each_with_object({}) do |option, env|
      unless (value = @config[option]).nil?
        env["#{ ViteRuby::ENV_PREFIX }_#{ option.upcase }"] = value.to_s
      end
    end.merge(ViteRuby.env)
  end

  # Internal: Files and directories that should be watched for changes.
  def watched_paths
    [
      *(watch_additional_paths + additional_entrypoints).reject { |dir|
        dir.start_with?('~/') || dir.start_with?(source_code_dir)
      },
      "#{ source_code_dir }/**/*",
      config_path.sub(/.json$/, '.{rb,json}'),
      *DEFAULT_WATCHED_PATHS,
    ].freeze
  end

private

  # Internal: Coerces all the configuration values, in case they were passed
  # as environment variables which are always strings.
  def coerce_values(config)
    config['mode'] = config['mode'].to_s
    config['port'] = config['port'].to_i
    config['root'] = Pathname.new(config['root'])
    config['build_cache_dir'] = config['root'].join(config['build_cache_dir'])
    config['ssr_output_dir'] = config['root'].join(config['ssr_output_dir'])
    coerce_booleans(config, 'auto_build', 'hide_build_console_output', 'https', 'skip_compatibility_check')
  end

  # Internal: Coerces configuration options to boolean.
  def coerce_booleans(config, *names)
    names.each { |name| config[name] = [true, 'true'].include?(config[name]) }
  end

  def initialize(attrs)
    @config = attrs.tap { |config| coerce_values(config) }.freeze
    ViteRuby::CompatibilityCheck.verify_plugin_version(root) unless skip_compatibility_check
  end

  class << self
    private :new

    # Public: Returns the project configuration for Vite.
    def resolve_config(**attrs)
      config = config_defaults.merge(attrs.transform_keys(&:to_s))
      file_path = File.join(config['root'], config['config_path'])
      file_config = config_from_file(file_path, mode: config['mode'])
      new DEFAULT_CONFIG.merge(file_config).merge(config_from_env).merge(config)
    end

  private

    # Internal: Converts camelCase to snake_case.
    SNAKE_CASE = ->(camel_cased_word) {
      camel_cased_word.to_s.gsub(/::/, '/')
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr('-', '_')
        .downcase
    }

    # Internal: Default values for a Ruby application.
    def config_defaults(asset_host: nil, mode: ENV.fetch('RACK_ENV', 'development'), root: Dir.pwd)
      {
        'asset_host' => option_from_env('asset_host') || asset_host,
        'config_path' => option_from_env('config_path') || DEFAULT_CONFIG.fetch('config_path'),
        'mode' => option_from_env('mode') || mode,
        'root' => option_from_env('root') || root,
      }.select { |_, value| value }
    end

    # Internal: Used to load a JSON file from the specified path.
    def load_json(path)
      JSON.parse(File.read(File.expand_path(path))).each do |_env, config|
        config.transform_keys!(&SNAKE_CASE) if config.is_a?(Hash)
      end.tap do |config|
        config.transform_keys!(&SNAKE_CASE)
      end
    end

    # Internal: Retrieves a configuration option from environment variables.
    def option_from_env(name)
      ViteRuby.env["#{ ViteRuby::ENV_PREFIX }_#{ name.upcase }"]
    end

    # Internal: Extracts the configuration options provided as env vars.
    def config_from_env
      CONFIGURABLE_WITH_ENV.each_with_object({}) do |option, env_vars|
        if value = option_from_env(option)
          env_vars[option] = value
        end
      end
    end

    # Internal: Loads the configuration options provided in a JSON file.
    def config_from_file(path, mode:)
      multi_env_config = load_json(path)
      multi_env_config.fetch('all', {})
        .merge(multi_env_config.fetch(mode, {}))
    rescue Errno::ENOENT => error
      $stderr << "Check that your vite.json configuration file is available in the load path:\n\n\t#{ error.message }\n\n"
      {}
    end
  end

  # Internal: Shared configuration with the Vite plugin for Ruby.
  DEFAULT_CONFIG = load_json("#{ __dir__ }/../../default.vite.json").freeze

  # Internal: Configuration options that can not be provided as env vars.
  NOT_CONFIGURABLE_WITH_ENV = %w[additional_entrypoints watch_additional_paths].freeze

  # Internal: Configuration options that can be provided as env vars.
  CONFIGURABLE_WITH_ENV = (DEFAULT_CONFIG.keys + %w[mode root] - NOT_CONFIGURABLE_WITH_ENV).freeze

  # Internal: If any of these files is modified the build won't be skipped.
  DEFAULT_WATCHED_PATHS = %w[
    package-lock.json
    package.json
    pnpm-lock.yaml
    postcss.config.js
    tailwind.config.js
    vite.config.js
    vite.config.ts
    windi.config.ts
    yarn.lock
  ].freeze

public

  # Define getters for the configuration options.
  (CONFIGURABLE_WITH_ENV + NOT_CONFIGURABLE_WITH_ENV).each do |option|
    define_method(option) { @config[option] }
  end
end
