import Config

config :logger, level: :info

# Phoenix's request log stays on: it is the cheapest record of HTTP traffic
# there is, and the pod logs already ship. A PHOENIX_REQUEST_LOG switch used
# to be read here (#210), where a value set on the deployment never arrived:
# this file is evaluated when the release is built, not when it boots.
