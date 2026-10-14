

locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "documind"
  }
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
  create_asg_kms_grant        = var.create_asg_kms_grant
  app_source_dir              = "${path.root}/documind-app/app"
  apmix_api_key_value           = var.apmix_api_key_value
}
