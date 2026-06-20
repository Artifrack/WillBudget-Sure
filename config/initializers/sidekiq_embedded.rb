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

    embedded = Sidekiq::Embedded.new(Sidekiq.default_configuration)
    embedded.run

    at_exit do
      Rails.logger.info("[SidekiqEmbedded] Stopping embedded Sidekiq (graceful shutdown)")
      embedded.stop
    end
  end
end
