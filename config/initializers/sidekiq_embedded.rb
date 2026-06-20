# Runs Sidekiq workers inside the Puma web process instead of a separate service.
# Toggle by setting EMBED_SIDEKIQ=true on the web service in Railway.
# To switch back to a separate worker: remove EMBED_SIDEKIQ and re-enable the worker service.
if ENV["EMBED_SIDEKIQ"] == "true"
  Rails.application.config.after_initialize do
    next if Rails.env.test?
    next if defined?(Rails::Console)
    next if defined?(Rake) && Rake.application.top_level_tasks.any?

    begin
      require "sidekiq/embedded"
    rescue LoadError => e
      Rails.logger.error("[SidekiqEmbedded] Cannot load sidekiq/embedded: #{e.message}. Embedded mode disabled.")
      next
    end

    unless defined?(Sidekiq::Embedded)
      Rails.logger.error("[SidekiqEmbedded] Sidekiq::Embedded not defined after require. Embedded mode disabled.")
      next
    end

    Rails.logger.info("[SidekiqEmbedded] Starting embedded Sidekiq within web process")

    # config/sidekiq.yml is only read by the sidekiq CLI, not in embedded mode.
    # Load queues and concurrency explicitly so embedded Sidekiq watches the right queues.
    sidekiq_yml = Rails.root.join("config/sidekiq.yml")
    if sidekiq_yml.exist?
      require "yaml"
      require "erb"
      yml = YAML.safe_load(ERB.new(sidekiq_yml.read).result, permitted_classes: [Symbol]) || {}
      queues = (yml[:queues] || yml["queues"])
      if queues.present?
        Sidekiq.default_configuration.queues = queues.map { |q| q.is_a?(Array) ? [q[0].to_s, q[1].to_i] : [q.to_s, 1] }
        Rails.logger.info("[SidekiqEmbedded] Loaded queues from sidekiq.yml: #{Sidekiq.default_configuration.queues.inspect}")
      end
    end

    embedded = Sidekiq::Embedded.new(Sidekiq.default_configuration)
    embedded.run

    at_exit do
      Rails.logger.info("[SidekiqEmbedded] Stopping embedded Sidekiq (graceful shutdown)")
      embedded.stop
    end
  end
end
