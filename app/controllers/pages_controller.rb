class PagesController < ApplicationController
  def home
  end

  def product
    @product = params[:product]
    @content = t("products.#{@product}")
    @releases = load_releases(@product)
  end

  private

  def load_releases(product)
    path = Rails.root.join("config/releases_data.json")
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path), symbolize_names: true)
    data[product.to_sym]
  rescue
    nil
  end
end
