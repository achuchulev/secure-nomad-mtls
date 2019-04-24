## Prerequisites

- git
- terraform
- own or control the registered domain name for the certificate 
- have a DNS record that associates your domain name and your server’s public IP address
- Cloudflare subscription as it is used to manage DNS records automatically
- AWS subscription
- ssh key
- Debian based AMI

## How to run

- Get the repo

```
https://github.com/achuchulev/secure-nomad-mtls.git
cd secure-nomad-mtls/dev
```

- Create `terraform.tfvars` file

```
access_key = "your_aws_access_key"
secret_key = "your_aws_secret_key"
ami = "some_aws_ami_id" # Debian based AMI like Ubuntu Xenial or Bionic
instance_type = "instance_type"
subnet_id = "subnet_id"
vpc_security_group_ids = ["security_group/s_id/s"]
public_key = "your_public_ssh_key"
cloudflare_email = "you@email.com"
cloudflare_token = "your_cloudflare_token"
cloudflare_zone = "your.domain" # example: nomadlab.com
subdomain_name = "subdomain_name" # example: lab
```

```
Note: Security group in AWS should allow https on port 443.
```

- Initialize terraform

```
terraform init
```

- Deploy nginx and nomad instances

```
terraform plan
terraform apply
```

- `Terraform apply` will:
  - create new instance on AWS
  - copy all configuration files from `config/` to user's home directory `~/`
  - install nomad
  - install cfssl (Cloudflare's PKI and TLS toolkit)
  - generate the selfsigned certificates for Nomad cluster 
  - install nginx
  - configure nginx
  - install certbot
  - automatically enable HTTPS on website with EFF's Certbot, deploying Let's Encrypt certificate
  - check for certificate expiration and automatically renew Let’s Encrypt certificate
  - start nomad server and client
  
## Access Nomad

#### via CLI

Nomad CLI defaults to communicating via HTTP instead of HTTPS. As Nomad CLI also searches environment variables for default values, the process can be simplified exporting environment variables like shown below:

```
$ export NOMAD_ADDR=https://your.dns.name
```

and then useing cli commands as usual will work fine.

for example:

```
$ nomad node status
$ nomad run nginx.nomad
$ nomad status nginx
```

#### via WEB UI console

Open web browser, access nomad web console using your instance dns name for URL and verify that connection is secured and SSL certificate is valid  
  
## Config details

### Create selfsigned certificates for Nomad cluster

The first step to configuring TLS for Nomad is generating certificates. In order to prevent unauthorized cluster access, Nomad requires all certificates be signed by the same Certificate Authority (CA). This should be a private CA and not a public one as any certificate signed by this CA will be allowed to communicate with the cluster.

```
Note!
      Nomad certificates may be signed by intermediate CAs as long as the root CA is the same. Append all intermediate CAs to the cert_file.
```

#### Certificate Authority

This guide will use *cfssl* for CA to generate a private CA certificate and key:

```
$ # Generate the CA's private key and certificate
$ cfssl print-defaults csr | cfssl gencert -initca - | cfssljson -bare nomad-ca
```

The CA key (nomad-ca-key.pem) will be used to sign certificates for Nomad nodes and must be kept private. The CA certificate (nomad-ca.pem) contains the public key necessary to validate Nomad certificates and therefore must be distributed to every node that requires access.

#### Node Certificates

Nomad certificates are signed with their region and role such as:

- *client.global.nomad* for a client node in the global region
- *server.us-west.nomad* for a server node in the us-west region

Create (or download) the following configuration file as cfssl.json to increase the default certificate expiration time:

```
{
  "signing": {
    "default": {
      "expiry": "87600h",
      "usages": [
        "signing",
        "key encipherment",
        "server auth",
        "client auth"
      ]
    }
  }
}
```

#### Generate a certificate for the Nomad server, client and CLI

```
$ # Generate a certificate for the Nomad server
$ echo '{}' | cfssl gencert -ca=nomad-ca.pem -ca-key=nomad-ca-key.pem -config=cfssl.json \
    -hostname="server.global.nomad,localhost,127.0.0.1" - | cfssljson -bare server

# Generate a certificate for the Nomad client
$ echo '{}' | cfssl gencert -ca=nomad-ca.pem -ca-key=nomad-ca-key.pem -config=cfssl.json \
    -hostname="client.global.nomad,localhost,127.0.0.1" - | cfssljson -bare client

# Generate a certificate for the CLI
$ echo '{}' | cfssl gencert -ca=nomad-ca.pem -ca-key=nomad-ca-key.pem -profile=client \
    - | cfssljson -bare cli
```

Using localhost and 127.0.0.1 as subject alternate names (SANs) allows tools like curl to be able to communicate with Nomad's HTTP API when run on the same host. Other SANs may be added including a DNS resolvable hostname to allow remote HTTP requests from third party tools.

You should now have the following files:

| Filename | Description |
| ------------- | -----|
| cli.csr | Nomad CLI certificate signing request|
| cli.pem | Nomad CLI certificate|
| cli-key.pem | Nomad CLI private key|
| client.csr | Nomad client node certificate signing request for the global region|
| client.pem | Nomad client node public certificate for the global region|
| client-key.pem | Nomad client node private key for the global region|
| cfssl.json | cfssl configuration|
| nomad-ca.csr | CA signing request|
| nomad-ca.pem | CA public certificate|
| nomad-ca-key.pem | CA private key. Keep safe!|
| server.csr | Nomad server node certificate signing request for the global region|
| server.pem | Nomad server node public certificate for the global region|
| server-key.pem | Nomad server node private key for the global region|

Each Nomad node should have the appropriate key (-key.pem) and certificate (.pem) file for its region and role. In addition each node needs the CA's public certificate (nomad-ca.pem).

### Configure and run Nomad with TLS

Nomad must be configured to use the newly-created key and certificates for (mutual) mTLS.

#### server configuration

Create (or download) server1.hcl configuration file

```
# Increase log verbosity
log_level = "DEBUG"

# Setup data dir
data_dir = "/tmp/server1"

# Enable the server
server {
  enabled = true

  # Self-elect, should be 3 or 5 for production
  bootstrap_expect = 1
}

# Require TLS
tls {
  http = true
  rpc  = true

  ca_file   = "/path/to/nomad-ca.pem"
  cert_file = "/path/to/server.pem"
  key_file  = "/path/to/server-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
```

#### client configuration

Create (or download) client1.hcl configuration file

```
# Increase log verbosity
log_level = "DEBUG"

# Setup data dir
data_dir = "/tmp/client1"

# Enable the client
client {
  enabled = true

  # For demo assume we are talking to server1. For production,
  # this should be like "nomad.service.consul:4647" and a system
  # like Consul used for service discovery.
  servers = ["127.0.0.1:4647"]
}

# Modify our port to avoid a collision with server1
ports {
  http = 5656
}

# Require TLS
tls {
  http = true
  rpc  = true

  ca_file   = "/path/to/nomad-ca.pem"
  cert_file = "/path/to/client.pem"
  key_file  = "/path/to/client-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
```

### Run Nomad in dev mode with mTLS

```
$ # In one terminal...
$ nomad agent -config /path/to/server1.hcl

$ # ...and in another
$ nomad agent -config /path/to/client1.hcl
```

### Setup nginx as a reverse-proxy and issue a trusted certificate for frontend

#### Overwrite nginx default configuration within `/etc/nginx/sites-available/default` with the one below

```
server {

    listen 80 default_server;
    server_name localhost;

    location / {

        proxy_pass https://127.0.0.1:4646;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /path/to/nomad-ca.pem;
        proxy_ssl_certificate /path/to/cli.pem;
        proxy_ssl_certificate_key /path/to/cli-key.pem;
        proxy_ssl_name server.global.nomad; 
    }
}
```

#### Enable HTTPS on nginx with EFF's Certbot automatically, deploying Let's Encrypt trusted certificate

```
sudo certbot --nginx --non-interactive --agree-tos -m ${var.cloudflare_email} -d ${var.subdomain_name}.${var.cloudflare_zone} --redirect
```

#### Create cron job to check and renew public certificate on expiration

```
crontab <<EOF
0 12 * * * /usr/bin/certbot renew --quiet
EOF
```

## Server Gossip

At this point all of Nomad's RPC and HTTP communication is secured with mTLS. However, Nomad servers also communicate with a gossip protocol Serf, that does not use TLS:

- *HTTP* - Used to communicate between CLI and Nomad agents. Secured by mTLS.
- *RPC* - Used to communicate between Nomad agents. Secured by mTLS.
- *Serf* - Used to communicate between Nomad servers. Secured by a shared key.

The Nomad CLI includes a _operator keygen_ command for generating a new secure gossip encryption key

```
$ nomad operator keygen
cg8StVXbQJ0gPvMd9o7yrg==
```

Put the same generated key into every server's configuration file server1.hcl or command line arguments:

```
server {
  enabled = true

  # Self-elect, should be 3 or 5 for production
  bootstrap_expect = 1

  # Encrypt gossip communication
  encrypt = "cg8StVXbQJ0gPvMd9o7yrg=="
}
```