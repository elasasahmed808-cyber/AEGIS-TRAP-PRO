

locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "documind"
  }
}

module "bedrock" {
  source = "./modules/bedrock"

  name_prefix                = local.name_prefix
  region                     = var.region
  logs_bucket_name           = var.bedrock_logs_bucket_name
  create_guardrail           = var.create_guardrail
  existing_guardrail_id      = var.existing_guardrail_id
  existing_guardrail_version = var.existing_guardrail_version
}

module "compute" {
  source = "./modules/compute"

  name_prefix                 = local.name_prefix
  region                      = var.region
  vpc_id                      = var.vpc_id
  public_subnet_ids           = var.public_subnet_ids
  private_subnet_ids          = var.private_subnet_ids
  documents_bucket_name       = var.documents_bucket_name
  build_artifacts_bucket_name = var.build_artifacts_bucket_name
  logging_bucket_name         = var.logging_bucket_name
  ami_id                      = var.ami_id
  app_instance_type           = var.app_instance_type
  jenkins_instance_type       = var.jenkins_instance_type
  bedrock_profile_regions     = var.bedrock_profile_regions
  bedrock_model_id            = var.bedrock_model_id
  bedrock_model_arns          = var.bedrock_model_arns
  guardrail_id                = module.bedrock.guardrail_id
  guardrail_arn               = module.bedrock.guardrail_arn
  guardrail_version           = module.bedrock.guardrail_version
  create_asg_kms_grant        = var.create_asg_kms_grant
  app_source_dir              = "${path.root}/documind-app/app"
}
