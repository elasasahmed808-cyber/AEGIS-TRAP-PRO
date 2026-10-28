output "alb_dns_name" { value = aws_lb.app.dns_name }
output "asg_name" { value = aws_autoscaling_group.app.name }
output "jenkins_asg_name" { value = aws_autoscaling_group.jenkins.name }
output "jenkins_url" { value = "https://${local.nip_hostname}/jenkins" }
output "jenkins_trigger_token_param" { value = aws_ssm_parameter.jenkins_trigger_token.name }
output "quarantine_sg_id" { value = aws_security_group.quarantine.id }
output "app_role_arn" { value = aws_iam_role.app.arn }
output "jenkins_role_arn" { value = aws_iam_role.jenkins.arn }
output "canary_1_access_key_id" { value = aws_iam_access_key.canary["1"].id }
output "canary_1_secret" {
  value     = aws_iam_access_key.canary["1"].secret
  sensitive = true
}
output "app_url_https" { value = "https://${local.nip_hostname}" }
