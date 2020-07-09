terraform {
  required_version = "> 0.12.0"

  backend "s3" {
    bucket         = "pttp-ci-infrastructure-client-core-tf-state"
    dynamodb_table = "pttp-ci-infrastructure-client-core-tf-lock-table"
    region         = "eu-west-2"
  }
}

provider "aws" {
  version = "~> 2.68"
  alias   = "env"
  assume_role {
    role_arn = var.assume_role
  }
}

provider "tls" {
  version = "> 2.1"
}
provider "local" {
  version = "~> 1.4"
}
provider "template" {
  version = "~> 2.1"
}
provider "random" {
  version = "~> 2.2.1"
}

data "aws_region" "current_region" {}

module "label" {
  source  = "cloudposse/label/null"
  version = "0.16.0"

  namespace = "pttp"
  stage     = terraform.workspace
  name      = "infra"
  delimiter = "-"

  tags = {
    "business-unit" = "MoJO"
    "application"   = "infrastructure",
    "is-production" = tostring(var.is-production),
    "owner"         = var.owner_email

    "environment-name" = "global"
    "source-code"      = "https://github.com/ministryofjustice/pttp-infrastructure"
  }
}

# module "bootstrap" {
#   source                      = "./modules/bootstrap"
#   shared_services_account_arn = var.shared_services_account_arn
#   prefix = ""
# }

resource "random_string" "random" {
  length  = 10
  upper   = false
  special = false
}

module "logging_vpc" {
  source     = "./modules/vpc"
  prefix     = module.label.id
  region     = data.aws_region.current_region.id
  cidr_block = var.logging_cidr_block

  providers = {
    aws = aws.env
  }
}

module "ost_vpc_peering" {
  source  = "./modules/vpc_peering"
  enabled = var.enable_peering

  source_route_table_ids = module.logging_vpc.private_route_table_ids
  source_vpc_id          = module.logging_vpc.vpc_id

  target_aws_account_id = var.ost_aws_account_id
  target_vpc_cidr_block = var.ost_vpc_cidr_block
  target_vpc_id         = var.ost_vpc_id

  tags = module.label.tags

  providers = {
    aws = aws.env
  }
}

module "customLoggingApi" {
  source = "./modules/custom_logging_api"
  prefix = module.label.id
  region = data.aws_region.current_region.id
  sns_topic_arn = module.sns-notification.topic-arn

  providers = {
    aws = aws.env
  }
}

module "logging" {
  source     = "./modules/logging"
  vpc_id     = module.logging_vpc.vpc_id
  subnet_ids = module.logging_vpc.private_subnets
  prefix     = module.label.id
  tags       = module.label.tags

  providers = {
    aws = aws.env
  }
}

module "sns-notification" {
  source = "./modules/sns-notification"
  emails = ["emile.swarts@digital.justice.gov.uk"]
  topic-name = "critical-notifications"

  providers = {
    aws = aws.env
  }
}

module "cloudtrail" {
  source = "./modules/cloudtrail"
  prefix = module.label.id
  region = data.aws_region.current_region.id
  tags   = module.label.tags

  providers = {
    aws = aws.env
  }
}

module "vpc_flow_logs" {
  source = "./modules/vpc_flow_logs"
  prefix = module.label.id
  region = data.aws_region.current_region.id
  tags   = module.label.tags
  vpc_id = module.logging_vpc.vpc_id

  providers = {
    aws = aws.env
  }
}

module "functionbeat_config" {
  source = "./modules/function_beats_config"

  prefix             = module.label.id
  deploy_bucket      = module.logging.beats_deploy_bucket
  deploy_role_arn    = module.logging.beats_role_arn
  security_group_ids = [module.logging.beats_security_group_id]

  subnet_ids = module.logging_vpc.private_subnets

  sqs_log_queue = module.customLoggingApi.custom_log_queue_arn

  log_groups = [
    "/cormac/test/1",
    "/cormac/test/2"
  ]

  destination_url      = var.ost_url
  destination_username = var.ost_username
  destination_password = var.ost_password
}
