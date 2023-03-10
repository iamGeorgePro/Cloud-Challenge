provider "aws" {
  region = "us-east-1"
}

# Bucket
resource "aws_s3_bucket" "tf_state_bucket" {

  bucket = "cloud-resume-challenge2"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_object" "cloud-resume-challenge2" {
  bucket = aws_s3_bucket.tf_state_bucket.id
  key    = "index.html"
  source = "${path.module}./01 - Website Front-End/index.html"
  content_type = "text/html"
}

resource "aws_s3_object" "cloud-resume-challenge" {
  bucket = aws_s3_bucket.tf_state_bucket.id
  key    = "custom.css"
  source = "${path.module}./01 - Website Front-End/custom.css"
  content_type = "text/css"
}

# add more resources for other files if needed


provider "archive" {}


data "archive_file" "zip" {
  type        = "zip"
  source_file = "${path.module}./02 - Website Back-End/lambda_update_view_count.py"
  output_path = "${path.module}./02 - Website Back-End/update_view_count.zip"
}

# ----------------------------------------------------------------
# ////////       S3 - add bucket policy       ////////
# ----------------------------------------------------------------

resource "aws_s3_bucket_policy" "my-bucket-policy" {
  bucket = aws_s3_bucket.tf_state_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "PublicReadGetObject",
        Effect = "Allow",
        Principal = "*",
        Action = [
          "s3:GetObject"
        ],
        Resource = [
          "${aws_s3_bucket.tf_state_bucket.arn}/*"
        ]
      }
    ]
  })
}



# ----------------------------------------------------------------
# ////////       S3 - Remote Backend for State File       ////////
# ----------------------------------------------------------------



# Bucket Access Control List
resource "aws_s3_bucket_acl" "tf_state_bucket_acl" {
  bucket = aws_s3_bucket.tf_state_bucket.id
  acl    = "public-read"
}

/* # Bucket Block Public Access
resource "aws_s3_bucket_public_access_block" "tf_state_bucket_block_public_access" {
  bucket = aws_s3_bucket.tf_state_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
} */

# Bucket Versioning
resource "aws_s3_bucket_versioning" "tf_state_bucket_versioning" {
  bucket = aws_s3_bucket.tf_state_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}


# --------------------------------------
# ////////       DynamoDB       ////////
# --------------------------------------

# Table
resource "aws_dynamodb_table" "view-count-table" {
  name           = "view-count-table"
  billing_mode   = "PROVISIONED"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "count_id" # Partition key

  attribute {
    name = "count_id"
    type = "S" # Partition key data type
  }
}


# ------------------------------------
# ////////       Lambda       ////////
# ------------------------------------

# Execution Role
resource "aws_iam_role" "iam_lambda_role" {
  name = "iam_lambda_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# Policy for Execution Role
resource "aws_iam_role_policy" "lambda_access_to_dynamodb_cloudwatch" {
  name   = "dynamodb_lambda_policy"
  role   = aws_iam_role.iam_lambda_role.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:*",
        "dynamodb:*"
      ],
      "Resource": "${aws_dynamodb_table.view-count-table.arn}"
    }
  ]
}
EOF
}

# Function
resource "aws_lambda_function" "lambda-view-counter-function" {
  function_name = "lambda-view-counter-function"

  filename         = data.archive_file.zip.output_path # "update_view_count.zip"
  source_code_hash = data.archive_file.zip.output_base64sha256

  role    = aws_iam_role.iam_lambda_role.arn
  handler = "lambda_update_view_count.lambda_handler"
  runtime = "python3.9"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.view-count-table.id # Reference name of dynamodb table
    }
  }
}


# -----------------------------------------
# ////////       API Gateway       ////////
# -----------------------------------------

# REST API
resource "aws_api_gateway_rest_api" "api-to-lambda-view-count" {
  name        = "api-to-lambda-view-count"
  description = "Gateway -> Lambda -> DynamoDB"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# API Resource (path end for URL)
resource "aws_api_gateway_resource" "api-resource" {
  parent_id   = aws_api_gateway_rest_api.api-to-lambda-view-count.root_resource_id
  path_part   = "count"
  rest_api_id = aws_api_gateway_rest_api.api-to-lambda-view-count.id
}

# Request Method
resource "aws_api_gateway_method" "api-post-method" {
  authorization = "NONE"
  http_method   = "POST"
  resource_id   = aws_api_gateway_resource.api-resource.id
  rest_api_id   = aws_api_gateway_rest_api.api-to-lambda-view-count.id
}

# Integration (link to Lambda function)
resource "aws_api_gateway_integration" "api-lambda-integration" {
  rest_api_id             = aws_api_gateway_rest_api.api-to-lambda-view-count.id
  resource_id             = aws_api_gateway_resource.api-resource.id
  http_method             = aws_api_gateway_method.api-post-method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.lambda-view-counter-function.invoke_arn
}

# Deployment (to stage for use)
resource "aws_api_gateway_deployment" "api-deployment" {
  rest_api_id = aws_api_gateway_rest_api.api-to-lambda-view-count.id

  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.api-resource.id,
      aws_api_gateway_method.api-post-method.id,
      aws_api_gateway_integration.api-lambda-integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Stage
resource "aws_api_gateway_stage" "api-stage" {
  deployment_id = aws_api_gateway_deployment.api-deployment.id
  rest_api_id   = aws_api_gateway_rest_api.api-to-lambda-view-count.id
  stage_name    = "prod"
}

# Permission (from Lambda to API)
resource "aws_lambda_permission" "lambda-permission-to-api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = "lambda-view-counter-function"
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.api-to-lambda-view-count.execution_arn}/${aws_api_gateway_stage.api-stage.stage_name}/${aws_api_gateway_method.api-post-method.http_method}/${aws_api_gateway_resource.api-resource.path_part}"
}

/* # --------------------------------------------------------------
# ////////       Create aws_acm_certificate   ////////
# --------------------------------------------------------------

resource "aws_acm_certificate" "my_certificate" {
  domain_name       = "www.georgekwabena.website"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# --------------------------------------------------------------
# ////////       Create  aws_cloudfront_distribution  ////////
# --------------------------------------------------------------

resource "aws_cloudfront_distribution" "my_distribution" {
  origin {
    domain_name = "${aws_s3_bucket.tf_state_bucket.bucket_domain_name}"
    origin_id   = "tf_state_bucket"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  enabled = true

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]
    target_origin_id = "tf_state_bucket"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  aliases = [
    "www.georgekwabena.site"
  ]

  default_root_object = "index.html"

  price_class = "PriceClass_200"

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.my_certificate.arn
    ssl_support_method  = "sni-only"
  }
} */





# --------------------------------------------------------------
# ////////       Enable CORS (API Gateway Cont'd)       ////////
# --------------------------------------------------------------


module "api-gateway-enable-cors" {
  source  = "squidfunk/api-gateway-enable-cors/aws"
  version = "0.3.3"

  api_id          = aws_api_gateway_rest_api.api-to-lambda-view-count.id
  api_resource_id = aws_api_gateway_resource.api-resource.id
}