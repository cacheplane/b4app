# DNS validation only. The zone lives at Vercel, so the owner adds the records
# from the acm_validation_records output by hand; the validation resource
# waits for them (up to an hour).
resource "aws_acm_certificate" "hub" {
  domain_name       = var.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "hub" {
  certificate_arn = aws_acm_certificate.hub.arn

  timeouts {
    create = "60m"
  }
}
