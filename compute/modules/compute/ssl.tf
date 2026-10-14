# Needs providers: hashicorp/tls, hashicorp/dns, hashicorp/aws
#
# WHY SELF-SIGNED: ACM public certs must be validated via DNS CNAME or e-mail to
# the domain owner. You don't own nip.io, so ACM can never validate it.
# Workaround: generate a cert, IMPORT it into ACM, attach it to the ALB.

# Pick one of the ALB's public IPs and turn it into a nip.io name (dash format = one DNS label)
data "dns_a_record_set" "alb" {
  host = aws_lb.app.dns_name
}

locals {
  alb_ip       = sort(data.dns_a_record_set.alb.addrs)[0]
  nip_hostname = "${replace(local.alb_ip, ".", "-")}.nip.io"
}

resource "tls_private_key" "nip" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "nip" {
  private_key_pem       = tls_private_key.nip.private_key_pem
  validity_period_hours = 8760
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]

  subject {
    common_name = local.nip_hostname
  }
  dns_names = [local.nip_hostname]
}

resource "aws_acm_certificate" "nip" {
  private_key      = tls_private_key.nip.private_key_pem
  certificate_body = tls_self_signed_cert.nip.cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

output "app_url" {
  value = "https://${local.nip_hostname}"
}
