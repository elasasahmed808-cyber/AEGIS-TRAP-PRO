output "alb_dns_name" { value = module.compute.alb_dns_name }
output "asg_name" { value = module.compute.asg_name }
output "jenkins_instance_id" { value = module.compute.jenkins_instance_id }
output "quarantine_sg_id" { value = module.compute.quarantine_sg_id }
output "app_role_arn" { value = module.compute.app_role_arn }
output "jenkins_role_arn" { value = module.compute.jenkins_role_arn }
output "canary_user_1_access_key_id" { value = module.compute.canary_1_access_key_id }
output "canary_user_1_secret" {
  value     = module.compute.canary_1_secret
  sensitive = true
}
