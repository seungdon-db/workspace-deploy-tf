# Define locals to configure deployment

locals {
  vpc_cidr = "10.10.0.0/16"
  root_bucket_name = "seungdon-tf-root"
  prefix = "db-dev-ws"
  tags = {
    Owner = "seungdon Choi"
    Environment = "Databricks development"
    }
  force_destroy = true #destroy root bucket when deleting stack?

  pl_service_relay = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0dc0e98a5800db5c4" # korea SSC relay endpoint
  pl_service_workspace = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0babb9bde64f34d7e" # korea workspace endpoint
}


# Create S3 root bucket
resource "aws_s3_bucket" "this" {
  bucket = local.root_bucket_name
  acl    = "private"

  force_destroy = local.force_destroy

  versioning {
    enabled = false
  }

  tags = merge(local.tags, {
    Name = local.root_bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "this" {
  statement {
    effect = "Allow"
    actions = ["s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:PutObject",
    "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.this.arn}/*",
      aws_s3_bucket.this.arn]
    principals {
      identifiers = ["arn:aws:iam::414351767826:root"]
      type        = "AWS"
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.this.json
}


# Create networking VPC resources

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "3.11.0"

  name = local.prefix
  cidr = local.vpc_cidr
  azs  = data.aws_availability_zones.available.names
  tags = local.tags

  enable_dns_hostnames = true

  enable_nat_gateway = true
  single_nat_gateway = true
  one_nat_gateway_per_az = false
  
  create_igw = true

  public_subnets = [cidrsubnet(local.vpc_cidr,3,0)]
  private_subnets = [cidrsubnet(local.vpc_cidr,3,1),
  cidrsubnet(local.vpc_cidr,3,2),
  cidrsubnet(local.vpc_cidr,3,3)
  ]
}

# Databricks Security Group
resource "aws_security_group" "databricks_sg" {
    
  vpc_id = module.vpc.vpc_id
  
  egress {
            from_port = 443
            to_port = 443
            protocol = "tcp"
            cidr_blocks = ["0.0.0.0/0"]
        }
  egress {
            from_port = 3306
            to_port = 3306
            protocol = "tcp"
            cidr_blocks = ["0.0.0.0/0"]
        }
  egress {
            from_port = 6666
            to_port = 6666
            protocol = "tcp"
            cidr_blocks = ["0.0.0.0/0"]
        }

  egress {
            self = true
            from_port = 0
            to_port = 65535
            protocol = "tcp"
    }
  egress {
            self = true
            from_port = 0
            to_port = 65535
            protocol = "udp"
    }

  ingress {
            self = true
            from_port = 0
            to_port = 65535
            protocol = "tcp"
    }
  ingress {
            self = true
            from_port = 0
            to_port = 65535
            protocol = "udp"
    }

  tags = local.tags
}


# create service endpoints for AWS services
# S3 endpoint
resource "aws_vpc_endpoint" "s3" {
  service_name = "com.amazonaws.${var.region}.s3"
  vpc_id = module.vpc.vpc_id
  route_table_ids = module.vpc.private_route_table_ids
  tags = local.tags
  vpc_endpoint_type = "Gateway"
}

# Kinesis endpoint
resource "aws_vpc_endpoint" "kinesis" {
  service_name = "com.amazonaws.${var.region}.kinesis-streams"
  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  tags = local.tags
  vpc_endpoint_type = "Interface"
  security_group_ids = [aws_security_group.databricks_sg.id]
  private_dns_enabled = true
}

# STS endpoint
resource "aws_vpc_endpoint" "sts" {
  service_name = "com.amazonaws.${var.region}.sts"
  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  tags = local.tags
  vpc_endpoint_type = "Interface"
  security_group_ids = [aws_security_group.databricks_sg.id]
  private_dns_enabled = true
}

resource "aws_security_group_rule" "s3_endpoint_rule" {
  type = "egress"
  from_port = 0
  to_port = 0
  protocol = -1
  security_group_id = aws_security_group.databricks_sg.id
  prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]

  depends_on = [aws_vpc_endpoint.s3]
}

# Set up Private Link

resource "aws_subnet" "pl_net" {
    vpc_id = module.vpc.vpc_id
    cidr_block = cidrsubnet(cidrsubnet(local.vpc_cidr,3,4),6,0)
    availability_zone = data.aws_availability_zones.available.names[1] #"eu-west-1b"
    tags = merge(
            {
            Name = "PrivateLink Subnet"
            },
            local.tags
        )
}

resource "aws_route_table" "pl_rt" {
  vpc_id = module.vpc.vpc_id
}

resource "aws_route_table_association" "pl_rt" {
    subnet_id = aws_subnet.pl_net.id
    route_table_id = aws_route_table.pl_rt.id
}

resource "aws_security_group" "pl_group" {
  name = "Private Link security group"
  description = "Dedicated group for Private Link endpoints"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "HTTPS ingress"
    from_port = 443
    to_port = 443
    protocol = "tcp"
    
    security_groups = [aws_security_group.databricks_sg.id]
  }

   ingress {
    description = "SCC ingress"
    from_port = 6666
    to_port = 6666
    protocol = "tcp"
    
    security_groups = [aws_security_group.databricks_sg.id]
  }

   egress {
    description = "HTTPS egress"
    from_port = 443
    to_port = 443
    protocol = "tcp"
    
    security_groups = [aws_security_group.databricks_sg.id]
  }

   egress {
    description = "SCC egress"
    from_port = 6666
    to_port = 6666
    protocol = "tcp"
    
    security_groups = [aws_security_group.databricks_sg.id]
  }

  tags = local.tags
}

resource "aws_vpc_endpoint" "workspace" {
  vpc_id = module.vpc.vpc_id
  service_name = local.pl_service_workspace
  vpc_endpoint_type = "Interface"

  security_group_ids = [aws_security_group.pl_group.id]

  
  #Select the Enable DNS Hostnames and DNS Resolution options at the VPC level for both types of VPC endpoints
  subnet_ids = [aws_subnet.pl_net.id]
  private_dns_enabled = true # set to true after registration

  tags = local.tags
}

resource "aws_vpc_endpoint" "relay" {
  vpc_id = module.vpc.vpc_id
  service_name = local.pl_service_relay
  vpc_endpoint_type = "Interface"

  security_group_ids = [aws_security_group.pl_group.id]

  
  #Select the Enable DNS Hostnames and DNS Resolution options at the VPC level for both types of VPC endpoints
  subnet_ids = [aws_subnet.pl_net.id]
  private_dns_enabled =  true # set to true after registration

  tags = local.tags
}

# Databricks objects
resource "databricks_mws_credentials" "this" {
  provider         = databricks.accounts
  credentials_name = "seungdon-tf-credentials"
  account_id       = var.databricks_account_id
  role_arn         = var.cross_account_arn
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.accounts
  account_id                 = var.databricks_account_id
  storage_configuration_name = "seungdon-tf-storage"
  bucket_name                = aws_s3_bucket.this.bucket
}


resource "databricks_mws_vpc_endpoint" "workspace" {
  provider = databricks.accounts
  account_id = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.workspace.id
  vpc_endpoint_name = "Workspace endpoint for ${module.vpc.vpc_id}"
  region = var.region
  depends_on = [
    aws_vpc_endpoint.workspace
  ]
}

resource "databricks_mws_vpc_endpoint" "relay" {
  provider = databricks.accounts
  account_id = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.relay.id
  vpc_endpoint_name = "VPC Relay endpoint for ${module.vpc.vpc_id}"
  region = var.region
  depends_on = [
    aws_vpc_endpoint.relay
  ]
}

resource "databricks_mws_private_access_settings" "this" {
  provider = databricks.accounts
  account_id = var.databricks_account_id
  private_access_settings_name = "Private Access for seungdon"
  region = var.region
  private_access_level = "ACCOUNT"
  public_access_enabled = true 
}

resource "databricks_mws_networks" "this" {
  provider = databricks.accounts
  account_id = var.databricks_account_id
  network_name = "${local.prefix}-network"
  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  security_group_ids = [aws_security_group.databricks_sg.id]

  vpc_endpoints {
    dataplane_relay = [databricks_mws_vpc_endpoint.relay.vpc_endpoint_id]
    rest_api = [databricks_mws_vpc_endpoint.workspace.vpc_endpoint_id]
  }

  depends_on = [
    aws_vpc_endpoint.relay,
    aws_vpc_endpoint.workspace
  ]
}


resource "databricks_mws_workspaces" "this" {
  provider = databricks.accounts
  account_id = var.databricks_account_id
  workspace_name = local.prefix
  deployment_name = local.prefix
  aws_region = var.region

  credentials_id = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id = databricks_mws_networks.this.network_id
  private_access_settings_id = databricks_mws_private_access_settings.this.private_access_settings_id
  pricing_tier = "ENTERPRISE"
  depends_on                 = [databricks_mws_networks.this]
}

# Output

output "databricks_host" {
  value = databricks_mws_workspaces.this.workspace_url
}
