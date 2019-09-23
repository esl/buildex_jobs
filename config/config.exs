use Mix.Config

config :buildex_common, :admin_node, :"admin@127.0.0.1"

import_config "#{Mix.env()}.exs"
