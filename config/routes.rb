Rails.application.routes.draw do
  root "pages#home"
  get "/products/:product", to: "pages#product", as: :product
end