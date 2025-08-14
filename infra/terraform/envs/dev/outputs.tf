output "ecr_repo_url" { value = aws_ecr_repository.api.repository_url }
output "vpc_id" { value = aws_vpc.mwe.id }
output "public_subnet_ids" { value = [for s in aws_subnet.public : s.id] }
output "private_subnet_ids" { value = [for s in aws_subnet.private : s.id] }
output "ecs_cluster_name" { value = aws_ecs_cluster.this.name }
output "data_bucket" { value = aws_s3_bucket.data.bucket }
output "github_role_arn" { value = aws_iam_role.gha_deploy.arn }
output "alb_dns_name" {
  value = aws_lb.api_alb.dns_name
}
