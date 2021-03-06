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
data "aws_caller_identity" "shared_services_account" {}

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
  enable_api_gateway_logs = var.enable_api_gateway_logs

  providers = {
    aws = aws.env
  }
}

module "alarms" {
  source                        = "./modules/alarms"
  enable_critical_notifications = var.enable_critical_notifications
  emails                        = var.critical_notification_recipients
  topic-name                    = "critical-notifications"
  prefix                        = module.label.id
  custom_log_queue_name         = module.customLoggingApi.custom_log_queue_name
  custom_log_api_gateway_name   = module.customLoggingApi.custom_log_api_gateway_name
  beats_dead_letter_queue_name  = module.customLoggingApi.dlq_custom_log_queue_name
  cloudwatch_function_name      = module.functionbeat_config.cloudwatch_name
  sqs_function_name             = module.functionbeat_config.sqs_name
  kinesis_function_name         = module.functionbeat_config.kinesis_name
  kinesis_stream_name           = module.shared_services_log_destination.kinesis_stream_name

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

module "cloudtrail" {
  source                                       = "./modules/cloudtrail"
  enable_cloudtrail_log_shipping_to_cloudwatch = var.enable_cloudtrail_log_shipping_to_cloudwatch
  prefix                                       = module.label.id
  region                                       = data.aws_region.current_region.id
  tags                                         = module.label.tags

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

  prefix                  = module.label.id
  deploy_bucket           = module.logging.beats_deploy_bucket
  deploy_role_arn         = module.logging.beats_role_arn
  deploy_role_kinesis_arn = module.logging.beats_role_kinesis_arn
  security_group_ids      = [module.logging.beats_security_group_id]
  subnet_ids              = module.logging_vpc.private_subnets

  sqs_log_queue               = module.customLoggingApi.custom_log_queue_arn
  beats_dead_letter_queue_arn = module.customLoggingApi.dlq_custom_log_queue_arn
  kinesis_stream_arn          = module.shared_services_log_destination.kinesis_stream_arn

  log_groups = [
    "PaloAltoNetworksFirewalls",
    "${module.label.id}-cloudtrail-log-group",
    "${module.label.id}-vpc-flow-logs-log-group"
  ]

  destination_url      = var.ost_url
  destination_username = var.ost_username
  destination_password = var.ost_password
}

module "firewall_roles" {
  source                      = "./modules/firewall_roles"
  prefix                      = module.label.id
  shared_services_account_arn = data.aws_caller_identity.shared_services_account.account_id
  providers = {
    aws = aws.env
  }
}

module "route_53" {
  source                           = "./modules/route_53"
  prefix                           = module.label.id
  env                              = var.env
  enable_api_gateway_custom_domain = var.enable_api_gateway_custom_domain
  api_gateway_dns                  = module.customLoggingApi.base_api_url

  providers = {
    aws = aws.env
  }
}

module "shared_services_log_destination" {
  source                                 = "./modules/shared_services_log_destination_stream"
  prefix                                 = module.label.id
  region                                 = data.aws_region.current_region.id
  shared_services_account_arn            = data.aws_caller_identity.shared_services_account.account_id
  enable_shared_services_log_destination = var.enable_shared_services_log_destination

  providers = {
    aws = aws.env
  }
}

module "api_gateway_load_test" {
  source = "./modules/api_gateway_load_test"

  enable_load_testing = var.enable_load_testing

  api_key = module.customLoggingApi.custom_logging_api_key
  api_url = module.customLoggingApi.base_api_url

  // The maximum rate we can achieve on ec2 t2-micros is 67 per second for 60 seconds
  // 100 instances gives us 4k requests per second for a minute
  arrival_rate   = 40
  instance_count = 200
  duration       = 60

  prefix = module.label.id

  providers = {
    aws = aws.env
  }
}
