defmodule ElixirLS.LanguageServer.Fixtures.BuildErrors.Mixfile do
  use Mix.Project

  def project do
    [app: :build_errors,
     version: "0.1.0"]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    []
  end
end
