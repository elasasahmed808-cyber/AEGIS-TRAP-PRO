# DocuMind Terraform (Compute + Bedrock)

## Layout
- `modules/bedrock`  – guardrail (optional), `proj-prod-bedrock-logs` bucket, CloudWatch log group, invocation logging config
- `modules/compute`  – IAM (app, Jenkins, canary users), SGs, launch templates (app + Jenkins), ASG 2/2/4, ALB + decoy rules, Jenkins instance
- `documind-app/`    – push this folder's content to your GitHub repo (Jenkinsfile + `app/`). Terraform also uploads `app/` as a seed `documind/latest.tar.gz` so first boot deploys without Jenkins.

## Prereqs (from other modules)
VPC, public/private subnets, NAT, S3 gateway endpoint, KMS key, buckets: documents, build-artifacts, logging.
The logging bucket policy must allow the regional ELB principal to write to `alb/*` (ALB access logs).
The KMS key policy must allow the app/Jenkins roles via IAM (or set `create_asg_kms_grant = true` once the ASG service-linked role exists).

## Use
    cp terraform.tfvars.example terraform.tfvars   # edit
    terraform init && terraform plan && terraform apply

## Already-existing roles/policies
If the Bedrock/Jenkins roles already exist in AWS, import before apply, e.g.:
    terraform import 'module.compute.aws_iam_role.jenkins' <existing-jenkins-role-name>
    terraform import 'module.compute.aws_iam_role.app' <existing-app-role-name>
(or rename them in `modules/compute/iam.tf`).

## Jenkins
No inbound ports. Reach the UI with SSM port forwarding:
    aws ssm start-session --target <jenkins_instance_id> --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080
Then create a Pipeline job pointing at the GitHub repo (Jenkinsfile in repo root).

## Decoy/Canary
ALB decoy paths -> 404 (logged). `/opt/documind/.env.bak` (root, 600) holds canary key 2. Canary user 1 secret is in the sensitive output `canary_user_1_secret`.
