class FamilyMerchantsController < ApplicationController
  before_action :set_merchant, only: %i[edit update destroy suggest_logo]

  def index
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.merchants"), nil ] ]
    @active_tab = params.fetch(:tab, "family")
    @q = params[:q].to_s.strip

    # Show all merchants for this family
    @all_family_merchants = Current.family.merchants.alphabetically
    @all_provider_merchants = Current.family.assigned_merchants_for(Current.user).where(type: "ProviderMerchant").alphabetically

    if @q.present?
      pattern = "%#{@q.downcase}%"
      @all_family_merchants = @all_family_merchants.where("LOWER(name) LIKE ?", pattern)
      @all_provider_merchants = @all_provider_merchants.where("LOWER(name) LIKE ?", pattern)
    end

    # Show recently unlinked ProviderMerchants (within last 30 days)
    # Exclude merchants that are already assigned to transactions (they appear in provider_merchants)
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: Current.family)
      .recently_unlinked
      .pluck(:merchant_id)
    assigned_ids = @all_provider_merchants.pluck(:id)
    @unlinked_merchants = ProviderMerchant.where(id: recently_unlinked_ids - assigned_ids).alphabetically

    @enhanceable_count = @all_provider_merchants.where(website_url: [ nil, "" ]).count
    @llm_available = Provider::Registry.get_provider(:openai).present?

    @pagy_family_merchants, @family_merchants = pagy(@all_family_merchants, page_param: :family_page, limit: safe_per_page)
    @pagy_provider_merchants, @provider_merchants = pagy(@all_provider_merchants, page_param: :provider_page, limit: safe_per_page)

    render layout: "settings"
  end

  def new
    @family_merchant = FamilyMerchant.new(family: Current.family)
  end

  def create
    @family_merchant = FamilyMerchant.new(merchant_params.merge(family: Current.family))

    if @family_merchant.save
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @merchant.is_a?(ProviderMerchant)
      if merchant_params[:name].present? && merchant_params[:name] != @merchant.name
        # Name changed — convert ProviderMerchant to FamilyMerchant for this family only
        @family_merchant = @merchant.convert_to_family_merchant_for(Current.family, merchant_params)
        respond_to do |format|
          format.html { redirect_to family_merchants_path, notice: t(".converted_success") }
          format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
        end
      else
        # Only website changed — update the ProviderMerchant directly
        @merchant.update!(merchant_params.slice(:website_url))
        @merchant.generate_logo_url_from_website!
        respond_to do |format|
          format.html { redirect_to family_merchants_path, notice: t(".success") }
          format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
        end
      end
    elsif @merchant.update(merchant_params)
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid => e
    @family_merchant = e.record
    render :edit, status: :unprocessable_entity
  end

  def destroy
    if @merchant.is_a?(ProviderMerchant)
      # Unlink from family's transactions only (don't delete the global merchant)
      @merchant.unlink_from_family(Current.family)
      redirect_to family_merchants_path, notice: t(".unlinked_success")
    else
      @merchant.destroy!
      redirect_to family_merchants_path, notice: t(".success")
    end
  end

  def new_provider
    # Renders a modal form; submit goes to create_provider
  end

  # GET /family_merchants/search?q=...
  # Returns top-10 global merchants by txn count matching the query.
  # Called client-side only when local search returns 0 results.
  def search
    q = params[:q].to_s.strip
    return render json: [] if q.length < 2

    merchants = Merchant
      .where(type: "ProviderMerchant", family_id: nil, merged_into_id: nil)
      .where("LOWER(name) LIKE ?", "%#{q.downcase}%")
      .joins("LEFT JOIN transactions ON transactions.merchant_id = merchants.id")
      .select("merchants.id, merchants.name, merchants.logo_url, merchants.website_url, COUNT(transactions.id) AS txn_count")
      .group("merchants.id")
      .order("txn_count DESC")
      .limit(10)

    render json: merchants.map { |m|
      { id: m.id, name: m.name, logo_url: m.logo_url, website_url: m.website_url, txn_count: m.txn_count.to_i }
    }
  end

  # POST /family_merchants/create_provider
  # Always creates a FamilyMerchant first. If a URL is provided and AI verifies it as a
  # legitimate business, the merchant is immediately converted to a ProviderMerchant in-place
  # (type flip via update_columns). If personal:true, skips AI and stays as FamilyMerchant.
  # AI rejections are logged to billing for super-admin review and promotion.
  def create_provider
    name = params[:name].to_s.strip
    raw_url = params[:url].to_s.strip.presence
    url = raw_url&.then { |u| u.sub(/\Ahttps?:\/\//i, "").sub(/\Awww\./i, "").sub(/\/.*\z/, "") }.presence
    personal = params[:personal].to_s == "true"

    if name.blank?
      return respond_to do |format|
        format.json { render json: { error: "name required" }, status: :unprocessable_entity }
        format.html { redirect_to new_provider_family_merchants_path, alert: "Name is required" }
      end
    end

    existing = ProviderMerchant.find_by("LOWER(name) = ?", name.downcase)
    if existing
      return respond_to do |format|
        format.json { render json: { id: existing.id, name: existing.name, logo_url: existing.logo_url, type: "provider" } }
        format.html { redirect_to family_merchants_path, notice: "#{existing.name} already exists as a provider merchant" }
      end
    end

    # Step 1: always create as FamilyMerchant (personal payees stop here)
    merchant = FamilyMerchant.create!(
      name: name,
      website_url: personal ? nil : url,
      family: Current.family
    )

    unless personal
      verified = url && billing_verify_url(name, url)

      if verified
        # Step 2a: AI approved — convert FamilyMerchant to ProviderMerchant in-place
        # update_columns bypasses STI/model validations so family_id can be set to NULL
        merchant.update_columns(
          type: "ProviderMerchant",
          source: "willbudget",
          provider_merchant_id: "wb_u_#{SecureRandom.hex(8)}",
          family_id: nil,
          updated_at: Time.current
        )
        merchant = Merchant.find(merchant.id)
        merchant.generate_logo_url_from_website! rescue nil
      elsif url.present?
        # Step 2b: AI rejected — stays as FamilyMerchant, logged for super-admin review
        billing_log_rejected_merchant(name, url, merchant.id)
      end
    end

    respond_to do |format|
      format.json { render json: { id: merchant.id, name: merchant.name, logo_url: merchant.logo_url, type: merchant.is_a?(ProviderMerchant) ? "provider" : "family" } }
      format.html { redirect_to family_merchants_path, notice: t(".success", default: "Merchant added successfully") }
      format.turbo_stream { redirect_to family_merchants_path, notice: t(".success", default: "Merchant added successfully") }
    end
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to new_provider_family_merchants_path, alert: e.message }
    end
  end

  def suggest_logo
    unless @merchant.is_a?(ProviderMerchant)
      return render json: { error: "Logo suggestions are only for provider merchants" }, status: :unprocessable_entity
    end
    image_data = params[:image_data].to_s
    unless image_data.start_with?("data:image/")
      return render json: { error: "Invalid image data" }, status: :unprocessable_entity
    end
    billing_url = ENV["BILLING_SERVICE_URL"].presence
    return render json: { error: "Billing service not configured" }, status: :service_unavailable unless billing_url
    begin
      uri = URI.parse("#{billing_url}/api/logo-suggestion")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 3
      http.read_timeout = 20
      req = Net::HTTP::Post.new(uri.path, "Authorization" => "Bearer #{ENV["BILLING_API_KEY"]}", "Content-Type" => "application/json")
      req.body = { merchantId: @merchant.id, familyId: Current.family.id, imageData: image_data }.to_json
      resp = http.request(req)
      render json: JSON.parse(resp.body), status: resp.code.to_i
    rescue => e
      Rails.logger.warn("[FamilyMerchants] suggest_logo failed: #{e.message}")
      render json: { error: e.message }, status: :service_unavailable
    end
  end

  def enhance
    cache_key = "enhance_provider_merchants:#{Current.family.id}"

    already_running = !Rails.cache.write(cache_key, true, expires_in: 10.minutes, unless_exist: true)

    if already_running
      return redirect_to family_merchants_path, alert: t(".already_running")
    end

    EnhanceProviderMerchantsJob.perform_later(Current.family)
    redirect_to family_merchants_path, notice: t(".success")
  end

  def merge
    @merchants = all_family_merchants
  end

  def perform_merge
    # Scope lookups to merchants valid for this family (FamilyMerchants + assigned ProviderMerchants)
    valid_merchants = all_family_merchants

    target = valid_merchants.find_by(id: params[:target_id])
    unless target
      return redirect_to merge_family_merchants_path, alert: t(".target_not_found")
    end

    sources = valid_merchants.where(id: params[:source_ids])
    unless sources.any?
      return redirect_to merge_family_merchants_path, alert: t(".invalid_merchants")
    end

    merger = Merchant::Merger.new(
      family: Current.family,
      target_merchant: target,
      source_merchants: sources
    )

    if merger.merge!
      redirect_to merge_family_merchants_path, notice: t(".success", count: merger.merged_count)
    else
      redirect_to merge_family_merchants_path, alert: t(".no_merchants_selected")
    end
  rescue Merchant::Merger::UnauthorizedMerchantError => e
    redirect_to merge_family_merchants_path, alert: e.message
  end

  private
    def set_merchant
      # Find merchant that either belongs to family OR is assigned to family's transactions
      @merchant = Current.family.merchants.find_by(id: params[:id]) ||
                  Current.family.assigned_merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def billing_verify_url(name, url)
      billing_url = ENV["BILLING_SERVICE_URL"].presence
      return false unless billing_url
      uri = URI.parse("#{billing_url}/api/verify-merchant-url")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 2
      http.read_timeout = 8
      req = Net::HTTP::Post.new(uri.path, "Authorization" => "Bearer #{ENV["BILLING_API_KEY"]}", "Content-Type" => "application/json")
      req.body = { name: name, url: url }.to_json
      resp = http.request(req)
      JSON.parse(resp.body)["verified"] == true
    rescue => e
      Rails.logger.warn("[FamilyMerchants] billing verify failed: #{e.message}")
      false
    end

    def billing_log_rejected_merchant(name, url, family_merchant_id = nil)
      billing_url = ENV["BILLING_SERVICE_URL"].presence
      return unless billing_url
      Thread.new do
        begin
          uri = URI.parse("#{billing_url}/api/log-rejected-merchant")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 2
          http.read_timeout = 5
          req = Net::HTTP::Post.new(uri.path, "Authorization" => "Bearer #{ENV["BILLING_API_KEY"]}", "Content-Type" => "application/json")
          req.body = { name: name, url: url, family_id: Current.family&.id, user_id: Current.user&.id, family_merchant_id: family_merchant_id&.to_s }.to_json
          http.request(req)
        rescue => e
          Rails.logger.warn("[FamilyMerchants] billing log rejected failed: #{e.message}")
        end
      end
    end

    def merchant_params
      # Handle both family_merchant and provider_merchant param keys
      key = params.key?(:family_merchant) ? :family_merchant : :provider_merchant
      params.require(key).permit(:name, :color, :website_url, :logo_url)
    end

    def all_family_merchants
      family_merchant_ids = Current.family.merchants.pluck(:id)
      provider_merchant_ids = Current.family.assigned_merchants.where(type: "ProviderMerchant").pluck(:id)
      combined_ids = (family_merchant_ids + provider_merchant_ids).uniq

      Merchant.where(id: combined_ids)
              .order(Arel.sql("LOWER(COALESCE(name, ''))"))
    end
end
