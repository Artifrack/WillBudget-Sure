class Settings::GuidesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.guides"), nil ]
    ]
    markdown = Redcarpet::Markdown.new(Redcarpet::Render::HTML,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true
    )
    raw_content = fetch_guide_content
    @guide_content = markdown.render(raw_content)
  end

  private

    def fetch_guide_content
      billing_url = ENV["BILLING_SERVICE_URL"].presence
      if billing_url
        begin
          uri = URI.parse("#{billing_url}/api/guide")
          response = Net::HTTP.get_response(uri)
          if response.is_a?(Net::HTTPSuccess)
            parsed = JSON.parse(response.body)
            return parsed["content"] if parsed["content"].present?
          end
        rescue => e
          Rails.logger.warn("[GuidesController] Failed to fetch guide from billing API: #{e.message}")
        end
      end
      local_guide = Rails.root.join("docs/onboarding/guide.md")
      local_guide.exist? ? File.read(local_guide) : ""
    end
end
