# ④ Conhecimento (RAG) — Bedrock Knowledge Bases sobre OpenSearch Serverless.
# - Bucket de documentos (CMK kb, versionado, sem acesso público).
# - Coleção VECTORSEARCH com políticas de criptografia (CMK), rede (só VPC
#   endpoint + serviço Bedrock) e dados (role da KB + administradores).
# - Índice vetorial via awscc (o provider aws não tem recurso de índice).
# - Knowledge Base + data source S3. Filtro por permissão de origem: cada
#   documento leva um sidecar <arquivo>.metadata.json com atributos como
#   `allowed_groups`, `source_system` e `classification`; o agente aplica
#   `retrievalConfiguration.vectorSearchConfiguration.filter` com os grupos
#   do operador (vindos do token) em toda consulta.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  partition       = data.aws_partition.current.partition
  region          = data.aws_region.current.region
  collection_name = substr(replace(lower("${var.name_prefix}-kb"), "_", "-"), 0, 32)
  index_name      = "bedrock-kb-default-index"

  embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"
  kb_name             = "${var.name_prefix}-kb"

  vector_field   = "bedrock-knowledge-base-default-vector"
  text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
  metadata_field = "AMAZON_BEDROCK_METADATA"
}

# ------------------------------------------------------ Documentos (S3) ----
module "documents_bucket" {
  source = "../s3-secure-bucket"

  name                     = "${var.bucket_prefix}-kb-documents"
  kms_key_arn              = var.kb_kms_key_arn
  deny_unencrypted_uploads = true
  access_log_bucket        = var.access_log_bucket
  force_destroy            = var.force_destroy
}

# ---------------------------------------------- OpenSearch Serverless ----
resource "aws_opensearchserverless_vpc_endpoint" "this" {
  name               = substr("${var.name_prefix}-aoss", 0, 32)
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  security_group_ids = [var.security_group_id]
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.collection_name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }]
    AWSOwnedKey = false
    KmsARN      = var.kb_kms_key_arn
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.collection_name}-net"
  type = "network"
  policy = jsonencode([{
    Description = "Acesso apenas via VPC endpoint e pelo serviço Bedrock (ingestão/consulta da KB)"
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.collection_name}"]
      },
      {
        ResourceType = "dashboard"
        Resource     = ["collection/${local.collection_name}"]
      },
    ]
    AllowFromPublic = false
    SourceVPCEs     = [aws_opensearchserverless_vpc_endpoint.this.id]
    SourceServices  = ["bedrock.amazonaws.com"]
  }])
}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.collection_name}-data"
  type = "data"
  policy = jsonencode([{
    Description = "KB role (leitura/escrita) e administradores (gestão do índice)"
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.collection_name}"]
        Permission = [
          "aoss:CreateCollectionItems",
          "aoss:DescribeCollectionItems",
          "aoss:UpdateCollectionItems",
        ]
      },
      {
        ResourceType = "index"
        Resource     = ["index/${local.collection_name}/*"]
        Permission = [
          "aoss:CreateIndex",
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
          "aoss:UpdateIndex",
          "aoss:WriteDocument",
        ]
      },
    ]
    Principal = concat([aws_iam_role.kb.arn], var.aoss_admin_principal_arns)
  }])
}

resource "aws_opensearchserverless_collection" "this" {
  name             = local.collection_name
  type             = "VECTORSEARCH"
  description      = "Vetores da knowledge base da plataforma de agentes"
  standby_replicas = var.standby_replicas

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

# Índice vetorial. awscc_opensearchserverless_collection_index (CloudFormation
# AWS::OpenSearchServerless::CollectionIndex).
# TODO(validar no 1º apply): formato exato de index_schema aceito pelo recurso
# (JSON de settings+mappings do OpenSearch). Se falhar, crie o índice pelo
# pipeline a partir de um runner dentro da VPC (a network policy bloqueia
# acesso de fora) e remova este recurso.
resource "awscc_opensearchserverless_collection_index" "this" {
  collection_index_id = aws_opensearchserverless_collection.this.id
  index_name          = local.index_name
  index_schema = jsonencode({
    settings = {
      index = {
        knn                        = true
        "knn.algo_param.ef_search" = 512
      }
    }
    mappings = {
      properties = {
        (local.vector_field) = {
          type      = "knn_vector"
          dimension = var.embedding_dimensions
          method = {
            name       = "hnsw"
            engine     = "faiss"
            space_type = "l2"
            parameters = {}
          }
        }
        (local.text_field) = {
          type  = "text"
          index = true
        }
        (local.metadata_field) = {
          type  = "text"
          index = false
        }
        allowed_groups = { type = "keyword" }
        source_system  = { type = "keyword" }
        classification = { type = "keyword" }
      }
    }
  })

  depends_on = [aws_opensearchserverless_access_policy.data]
}

# ---------------------------------------------------------------- KB role --
data "aws_iam_policy_document" "kb_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"]
    }
  }
}

resource "aws_iam_role" "kb" {
  name               = "${var.name_prefix}-knowledge-base"
  assume_role_policy = data.aws_iam_policy_document.kb_assume.json
}

data "aws_iam_policy_document" "kb" {
  statement {
    sid       = "EmbeddingModel"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.embedding_model_arn]
  }

  statement {
    sid       = "VectorStore"
    actions   = ["aoss:APIAccessAll"]
    resources = [aws_opensearchserverless_collection.this.arn]
  }

  statement {
    sid       = "ListDocuments"
    actions   = ["s3:ListBucket"]
    resources = [module.documents_bucket.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "ReadDocuments"
    actions   = ["s3:GetObject"]
    resources = ["${module.documents_bucket.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "DecryptDocumentsAndIngestion"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kb_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "kb" {
  name   = "knowledge-base"
  role   = aws_iam_role.kb.id
  policy = data.aws_iam_policy_document.kb.json
}

# ------------------------------------------------------- Knowledge Base ----
resource "aws_bedrockagent_knowledge_base" "this" {
  name        = local.kb_name
  description = "Base de conhecimento (procedimentos e normativos) da central de atendimento"
  role_arn    = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = local.embedding_model_arn
      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions          = var.embedding_dimensions
          embedding_data_type = "FLOAT32"
        }
      }
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.this.arn
      vector_index_name = local.index_name
      field_mapping {
        vector_field   = local.vector_field
        text_field     = local.text_field
        metadata_field = local.metadata_field
      }
    }
  }

  depends_on = [
    aws_iam_role_policy.kb,
    awscc_opensearchserverless_collection_index.this,
  ]
}

resource "aws_bedrockagent_data_source" "documents" {
  name                 = "${local.kb_name}-s3"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this.id
  description          = "Documentos em S3 com sidecar .metadata.json (permissão de origem)"
  data_deletion_policy = "RETAIN"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = module.documents_bucket.arn
      inclusion_prefixes = var.document_prefixes
    }
  }

  server_side_encryption_configuration {
    kms_key_arn = var.kb_kms_key_arn
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = var.chunk_max_tokens
        overlap_percentage = var.chunk_overlap_percentage
      }
    }
  }
}
