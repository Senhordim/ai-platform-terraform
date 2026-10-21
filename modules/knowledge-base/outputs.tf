output "knowledge_base_id" {
  description = "ID da knowledge base."
  value       = aws_bedrockagent_knowledge_base.this.id
}

output "knowledge_base_arn" {
  description = "ARN da knowledge base."
  value       = aws_bedrockagent_knowledge_base.this.arn
}

output "data_source_id" {
  description = "ID do data source S3."
  value       = aws_bedrockagent_data_source.documents.data_source_id
}

output "documents_bucket" {
  description = "Bucket de documentos."
  value       = module.documents_bucket.id
}

output "documents_bucket_arn" {
  description = "ARN do bucket de documentos."
  value       = module.documents_bucket.arn
}

output "collection_arn" {
  description = "ARN da coleção vetorial."
  value       = aws_opensearchserverless_collection.this.arn
}

output "aoss_vpc_endpoint_id" {
  description = "ID do VPC endpoint do OpenSearch Serverless."
  value       = aws_opensearchserverless_vpc_endpoint.this.id
}
