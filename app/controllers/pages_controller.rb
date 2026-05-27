class PagesController < ApplicationController
  def home
  end

  def product
    @product = params[:product]
    @content = t("products.#{@product}")
  end
end
