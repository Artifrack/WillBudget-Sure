# frozen_string_literal: true

class Api::Billing::AvatarsController < ApplicationController
  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade

  def index
    unless authorized?
      return render json: { error: "unauthorized" }, status: :unauthorized
    end

    user_ids = Array(params[:user_ids]).map(&:to_i).uniq.select(&:positive?)
    return render json: { avatars: {} } if user_ids.empty?

    attachments = ActiveStorage::Attachment
      .where(record_type: "User", name: "profile_image", record_id: user_ids)
      .includes(:blob)

    avatars = {}
    attachments.each do |a|
      next unless a.blob
      avatars[a.record_id.to_s] = rails_blob_url(a.blob)
    end

    render json: { avatars: avatars }
  end

  private

    def authorized?
      key = ENV["BILLING_API_KEY"].presence
      return false unless key
      request.headers["Authorization"] == "Bearer #{key}"
    end
end
