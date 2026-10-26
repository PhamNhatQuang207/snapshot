# Values CI needs (Task 10) to publish the website, stored in SSM Parameter Store.
# They change on every `make up` (new bucket contents, new CloudFront ID and domain),
# so CI reads them at run time instead of hard-coding them.

resource "aws_ssm_parameter" "web_bucket" {
  name  = "/${var.name}/web_bucket"
  type  = "String"
  value = aws_s3_bucket.web.bucket
}

resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name  = "/${var.name}/cloudfront_distribution_id"
  type  = "String"
  value = aws_cloudfront_distribution.this.id
}

resource "aws_ssm_parameter" "cloudfront_domain" {
  name  = "/${var.name}/cloudfront_domain"
  type  = "String"
  value = aws_cloudfront_distribution.this.domain_name
}
