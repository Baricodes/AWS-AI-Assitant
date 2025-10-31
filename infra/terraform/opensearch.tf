# OpenSearch Serverless Collection for Vector Search

# Security Policy (Encryption)
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.collection_name}-encryption"
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource = [
          "collection/${var.collection_name}"
        ]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = true
  })
}

# Network Policy - Public access
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.collection_name}-network"
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/${var.collection_name}"
          ]
          ResourceType = "collection"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

# Data Access Policy - Allow current account to manage indices
resource "aws_opensearchserverless_access_policy" "data_access" {
  name = "${var.collection_name}-data-access"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/${var.collection_name}"
          ]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
          ResourceType = "collection"
        },
        {
          Resource = [
            "index/${var.collection_name}/*"
          ]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
          ResourceType = "index"
        }
      ]
      Principal = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }
  ])
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# OpenSearch Serverless Collection
resource "aws_opensearchserverless_collection" "kb_vector" {
  name = var.collection_name
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
    aws_opensearchserverless_access_policy.data_access
  ]
}

# Note: For OpenSearch Serverless, indices are created programmatically through your application
# using the OpenSearch API, not through Terraform. The index configuration below should be
# implemented in your Python application code when initializing the vector store.
#
# Index Configuration Template (to be used in application code):
# {
#   "mappings": {
#     "properties": {
#       "embedding": {
#         "type": "knn_vector",
#         "dimension": 1024,
#         "space_type": "cosinesimil",
#         "mode": "on_disk",
#         "compression_level": "16x",
#         "method": {
#           "name": "hnsw",
#           "engine": "faiss",
#           "parameters": {
#             "m": 16,
#             "ef_construction": 100
#           }
#         }
#       },
#       "chunk_text": { "type": "text" },
#       "doc_id": { "type": "keyword" },
#       "chunk_id": { "type": "integer" },
#       "title": { "type": "text" },
#       "section": { "type": "text" },
#       "source": { "type": "keyword" },
#       "s3_key": { "type": "keyword" },
#       "url": { "type": "keyword" },
#       "tags": { "type": "keyword" },
#       "token_count": { "type": "integer" },
#       "created_at": { "type": "date" },
#       "updated_at": { "type": "date" }
#     }
#   },
#   "settings": {
#     "index.knn": true
#   }
# }
