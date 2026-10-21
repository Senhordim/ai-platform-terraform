output "vpc_id" {
  description = "ID da VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR da VPC."
  value       = aws_vpc.this.cidr_block
}

output "workload_subnet_ids" {
  description = "Subnets privadas de workload (sem rota para IGW)."
  value       = aws_subnet.workload[*].id
}

output "endpoint_subnet_ids" {
  description = "Subnets dos VPC endpoints."
  value       = aws_subnet.endpoints[*].id
}

output "workload_security_group_id" {
  description = "Security group padrão dos workloads."
  value       = aws_security_group.workload.id
}

output "endpoints_security_group_id" {
  description = "Security group dos VPC endpoints."
  value       = aws_security_group.endpoints.id
}

output "vpc_endpoint_ids" {
  description = "IDs dos VPC endpoints (interface + gateway S3)."
  value = merge(
    { for k, v in aws_vpc_endpoint.interface : k => v.id },
    { s3 = aws_vpc_endpoint.s3.id },
  )
}

output "execute_api_vpce_id" {
  description = "ID do VPC endpoint execute-api (resource policy do API Gateway privado)."
  value       = try(aws_vpc_endpoint.interface["execute-api"].id, null)
}

output "execute_api_vpce_dns_name" {
  description = "DNS regional do VPC endpoint execute-api (routing_domain dos targets do Gateway)."
  value       = try(aws_vpc_endpoint.interface["execute-api"].dns_entry[0].dns_name, null)
}

output "egress_enabled" {
  description = "Se o caminho de egress via Network Firewall foi criado."
  value       = local.egress_enabled
}
