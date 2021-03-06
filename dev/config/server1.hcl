# Increase log verbosity
log_level = "DEBUG"

# Setup data dir
data_dir = "/tmp/server1"

# Enable the server
server {
    enabled = true

    # Self-elect, should be 3 or 5 for production
    bootstrap_expect = 1
    
    encrypt = "cg8StVXbQJ0gPvMd9o7yrg=="
}

# Require TLS
tls {
  http = true
  rpc  = true

  ca_file   = "nomad/ssl/nomad-ca.pem"
  cert_file = "nomad/ssl/server.pem"
  key_file  = "nomad/ssl/server-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
