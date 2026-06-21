class Settings::GuidesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.guides"), nil ]
    ]
    raw_content = fetch_guide_content

    md_opts = { autolink: true, tables: true, fenced_code_blocks: true, strikethrough: true, superscript: true }
    toc_md   = Redcarpet::Markdown.new(Redcarpet::Render::HTML_TOC.new, **md_opts)
    body_md  = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(with_toc_data: true), **md_opts)

    toc_html = toc_md.render(raw_content)
    @guide_toc     = toc_html.present? ? toc_html.html_safe : nil
    @guide_content = body_md.render(raw_content).html_safe
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
