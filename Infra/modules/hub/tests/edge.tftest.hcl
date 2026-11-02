# Tests apply against a mocked AWS provider; nothing here needs credentials.

mock_provider "aws" {
  mock_data "aws_elb_service_account" {
    defaults = {
      arn = "arn:aws:iam::033677994240:root"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:111111111111:loadbalancer/app/b4hub-test/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:111111111111:targetgroup/b4hub-test-hub/0123456789abcdef"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-2:111111111111:certificate/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:us-east-2:111111111111:regional/webacl/b4hub-test-web-acl/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  environment = "test"
  alarm_email = "ops@example.com"
}

run "waf_has_two_rules_and_no_body_rules" {
  command = apply

  assert {
    condition     = length(aws_wafv2_web_acl.hub.rule) == 2
    error_message = "the web ACL has exactly two rules"
  }

  assert {
    condition     = length([for r in aws_wafv2_web_acl.hub.rule : r if length(r.statement[0].managed_rule_group_statement) > 0 && r.statement[0].managed_rule_group_statement[0].name == "AWSManagedRulesAmazonIpReputationList"]) == 1
    error_message = "the IP reputation list is one of the rules"
  }

  assert {
    condition     = length([for r in aws_wafv2_web_acl.hub.rule : r if length(r.statement[0].managed_rule_group_statement) > 0 && r.statement[0].managed_rule_group_statement[0].name != "AWSManagedRulesAmazonIpReputationList"]) == 0
    error_message = "no managed rule group other than the IP reputation list (no body inspection: the hub takes 32 MiB bodies)"
  }

  assert {
    condition     = length([for r in aws_wafv2_web_acl.hub.rule : r if length(r.statement[0].rate_based_statement) > 0 && r.statement[0].rate_based_statement[0].limit == 2000 && r.statement[0].rate_based_statement[0].aggregate_key_type == "IP"]) == 1
    error_message = "one rate-based rule, 2000 requests per IP"
  }

  assert {
    condition     = length(aws_wafv2_web_acl.hub.default_action[0].allow) == 1 && aws_wafv2_web_acl.hub.scope == "REGIONAL"
    error_message = "default allow, regional scope"
  }
}

run "idle_timeout_120" {
  command = apply

  assert {
    condition     = aws_lb.this.idle_timeout == 120 && aws_lb.this.drop_invalid_header_fields == true
    error_message = "idle timeout 120 and invalid headers dropped"
  }

  assert {
    condition     = aws_lb.this.load_balancer_type == "application" && aws_lb.this.internal == false
    error_message = "internet-facing application load balancer"
  }
}

run "health_check_readyz" {
  command = apply

  assert {
    condition     = aws_lb_target_group.hub.health_check[0].path == "/readyz" && aws_lb_target_group.hub.health_check[0].interval == 10
    error_message = "health check is /readyz every 10 seconds"
  }

  assert {
    condition     = aws_lb_target_group.hub.health_check[0].healthy_threshold == 2 && aws_lb_target_group.hub.health_check[0].unhealthy_threshold == 3 && aws_lb_target_group.hub.health_check[0].matcher == "200"
    error_message = "healthy 2, unhealthy 3, matcher 200"
  }

  assert {
    condition     = aws_lb_target_group.hub.target_type == "ip" && aws_lb_target_group.hub.port == 8080 && aws_lb_target_group.hub.deregistration_delay == "60"
    error_message = "ip targets on 8080, 60 second deregistration delay"
  }
}

run "http_redirects" {
  command = apply

  assert {
    condition     = aws_lb_listener.http.port == 80 && length(aws_lb_listener.http.default_action) == 1
    error_message = "port 80 has a single default action"
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect" && aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301" && aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"
    error_message = "port 80 only redirects to HTTPS with a 301"
  }
}

run "https_listener" {
  command = apply

  assert {
    condition     = aws_lb_listener.https.port == 443 && aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
    error_message = "443 uses the TLS 1.3 policy"
  }

  assert {
    condition     = aws_lb_listener.https.default_action[0].type == "forward"
    error_message = "443 forwards to the hub target group"
  }
}

run "acm_dns_validation" {
  command = apply

  assert {
    condition     = aws_acm_certificate.hub.validation_method == "DNS" && aws_acm_certificate.hub.domain_name == "hub.b4.run"
    error_message = "DNS-validated certificate for the hostname"
  }
}

run "alb_logs_bucket" {
  command = apply

  assert {
    condition     = aws_s3_bucket.alb_logs.bucket == "b4hub-test-alb-logs"
    error_message = "log bucket is named for the environment"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.alb_logs.rule[0].expiration[0].days == 30
    error_message = "logs expire after 30 days"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.alb_logs.block_public_acls && aws_s3_bucket_public_access_block.alb_logs.block_public_policy && aws_s3_bucket_public_access_block.alb_logs.ignore_public_acls && aws_s3_bucket_public_access_block.alb_logs.restrict_public_buckets
    error_message = "the log bucket blocks all public access"
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.alb_logs.rule : r.apply_server_side_encryption_by_default[0].sse_algorithm]) == "AES256"
    error_message = "SSE-S3 (ELB logs do not support KMS)"
  }

  assert {
    condition     = aws_lb.this.access_logs[0].bucket == aws_s3_bucket.alb_logs.id && aws_lb.this.access_logs[0].enabled == true
    error_message = "the load balancer writes access logs to the bucket"
  }
}
