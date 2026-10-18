resource "aws_lb" "app" {
  name                       = "${var.name_prefix}-documind"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true

  access_logs {
    bucket  = var.logging_bucket_name
    prefix  = "alb/${var.name_prefix}"
    enabled = true
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.name_prefix}-documind"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP" # HTTP only, no 443 listener

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Decoy / honeypot paths - answered by the ALB, never reach the app
resource "aws_lb_listener_rule" "decoy" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/.env", "/admin*", "/phpmyadmin*", "/wp-login.php"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}
