class Settings::GuidesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.guides"), nil ]
    ]

    guide_data = fetch_guide_data
    @pages = guide_data[:pages] || []
    @current_page_slug = params[:page].presence || @pages.first&.dig(:slug)

    raw_content = if @current_page_slug && guide_data[:page_contents]
      guide_data[:page_contents][@current_page_slug] || ""
    else
      guide_data[:content] || ""
    end

    md_opts = { autolink: true, tables: true, fenced_code_blocks: true, strikethrough: true, superscript: true }
    toc_md  = Redcarpet::Markdown.new(Redcarpet::Render::HTML_TOC.new, **md_opts)
    body_md = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(with_toc_data: true), **md_opts)

    @guide_toc     = toc_md.render(raw_content).presence&.html_safe
    @guide_content = body_md.render(raw_content).html_safe
  end

  private

    def fetch_guide_data
      billing_url = ENV["BILLING_SERVICE_URL"].presence
      return { pages: [], content: local_guide_content } unless billing_url

      begin
        pages_uri = URI.parse("#{billing_url}/api/guide/pages")
        pages_res = Net::HTTP.get_response(pages_uri)

        if pages_res.is_a?(Net::HTTPSuccess)
          parsed = JSON.parse(pages_res.body)
          pages = (parsed["pages"] || []).map { |p| { slug: p["slug"], title: p["title"] } }

          if pages.any?
            slug = params[:page].presence || pages.first[:slug]
            page_uri = URI.parse("#{billing_url}/api/guide/page/#{URI.encode_uri_component(slug)}")
            page_res = Net::HTTP.get_response(page_uri)

            if page_res.is_a?(Net::HTTPSuccess)
              page_data = JSON.parse(page_res.body)
              return {
                pages: pages,
                page_contents: { slug => page_data["content"].to_s }
              }
            end
          end
        end
      rescue => e
        Rails.logger.warn("[GuidesController] Multi-page guide fetch failed: #{e.message}")
      end

      begin
        uri = URI.parse("#{billing_url}/api/guide")
        response = Net::HTTP.get_response(uri)
        if response.is_a?(Net::HTTPSuccess)
          parsed = JSON.parse(response.body)
          return { pages: [], content: parsed["content"].to_s }
        end
      rescue => e
        Rails.logger.warn("[GuidesController] Guide fetch failed: #{e.message}")
      end

      { pages: [], content: local_guide_content }
    end

    def local_guide_content
      path = Rails.root.join("docs/onboarding/guide.md")
      path.exist? ? File.read(path) : ""
    end
end
