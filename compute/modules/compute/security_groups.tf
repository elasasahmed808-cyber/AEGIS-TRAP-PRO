data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB - HTTP only"
  vpc_id      = var.vpc_id
}
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "DocuMind EC2"
  vpc_id      = var.vpc_id
}
resource "aws_security_group" "jenkins" {
  name        = "${var.name_prefix}-jenkins"
  description = "Jenkins - no inbound (SSM port-forward only)"
  vpc_id      = var.vpc_id
}
resource "aws_security_group" "quarantine" {
  name        = "${var.name_prefix}-quarantine"
  description = "Quarantine - no inbound, egress only to S3 (evidence)"
  vpc_id      = var.vpc_id
}

# ALB
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.app.id
}

# EC2 app: 8080 from ALB only
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}
# Allow the app to talk to the outside world for downloading updates and reaching AI services like Bedrock through htpps
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_egress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# Allow Jenkins to talk to the outside world for downloading plugins and receiving deployment commands
resource "aws_vpc_security_group_egress_rule" "jenkins_https" {
  security_group_id = aws_security_group.jenkins.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_egress_rule" "jenkins_http" {
  security_group_id = aws_security_group.jenkins.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# Quarantine: egress only to S3 via the gateway endpoint prefix list
resource "aws_vpc_security_group_egress_rule" "quarantine_s3" {
  security_group_id = aws_security_group.quarantine.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.s3.id
}
