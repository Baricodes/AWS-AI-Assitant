"""Query processor Lambda: vector search in OpenSearch and answer via Bedrock."""

import json
import logging
import os

import boto3
from botocore.config import Config as BotoConfig
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

# Configure logging (buffered per invocation; see handler below)
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()

class BufferedLogHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self._records = []
        self.setFormatter(logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s'))

    def emit(self, record):
        try:
            self._records.append(self.format(record))
        except Exception:
            # Avoid secondary exceptions from logging
            pass

    def get_value(self):
        return "\n".join(self._records)

logger = logging.getLogger(__name__)

BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")
OS_REGION = os.environ.get("OPENSEARCH_REGION", "us-east-1")
EMBED_MODEL_ID = os.environ.get(
    "EMBED_MODEL_ID",
    "amazon.titan-embed-text-v2:0",
)
# example; use what's enabled in the account/region
GEN_MODEL_ID = os.environ.get(
    "GEN_MODEL_ID",
    "anthropic.claude-3-5-sonnet-20241022-v2:0",
)
GEN_INFERENCE_PROFILE_ID = os.environ.get("GEN_INFERENCE_PROFILE_ID")
INDEX = os.environ.get("OPENSEARCH_INDEX", "kb_chunks")
ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]

bedrock = boto3.client(
    "bedrock-runtime",
    region_name=BEDROCK_REGION,
    config=BotoConfig(
        connect_timeout=3,
        read_timeout=25,
        retries={"max_attempts": 3, "mode": "standard"},
    ),
)

session = boto3.Session(region_name=OS_REGION)
creds = session.get_credentials()
awsauth = AWSV4SignerAuth(creds, "aoss", region=OS_REGION)

os_client = OpenSearch(
    hosts=[{"host": ENDPOINT.replace("https://", ""), "port": 443}],
    http_auth=awsauth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection,
)

CORS_ALLOW_ORIGIN = os.environ.get("CORS_ALLOW_ORIGIN", "*")
CORS_HEADERS = {
    "Access-Control-Allow-Origin": CORS_ALLOW_ORIGIN,
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
}

def _response(status, body_obj=None, headers=None):
    base_headers = {"Content-Type": "application/json", **CORS_HEADERS}
    if headers:
        base_headers.update(headers)
    return {
        "statusCode": status,
        "headers": base_headers,
        "body": json.dumps(body_obj) if body_obj is not None else "",
    }

def ensure_index_exists():
    """Create the vector index if it doesn't exist."""
    try:
        if os_client.indices.exists(index=INDEX):
            logger.info("Index %s already exists", INDEX)
            return
        
        logger.info("Creating index %s", INDEX)
        index_config = {
            "settings": {
                "index.knn": True
            },
            "mappings": {
                "properties": {
                    "embedding": {
                        "type": "knn_vector",
                        "dimension": 1024,
                        "space_type": "cosinesimil",
                        "mode": "on_disk",
                        "compression_level": "16x",
                        "method": {
                            "name": "hnsw",
                            "engine": "faiss",
                            "parameters": {
                                "m": 16,
                                "ef_construction": 100
                            }
                        }
                    },
                    "chunk_text": {"type": "text"},
                    "doc_id": {"type": "keyword"},
                    "chunk_id": {"type": "integer"},
                    "title": {"type": "text"},
                    "section": {"type": "text"},
                    "source": {"type": "keyword"},
                    "s3_key": {"type": "keyword"},
                    "url": {"type": "keyword"},
                    "tags": {"type": "keyword"},
                    "token_count": {"type": "integer"},
                    "created_at": {"type": "date"},
                    "updated_at": {"type": "date"}
                }
            }
        }
        
        os_client.indices.create(index=INDEX, body=index_config)
        logger.info("Successfully created index %s", INDEX)
        
    except Exception as e:
        logger.error("Error ensuring index exists: %s", str(e))
        # Don't raise the error - the Lambda should continue even if index creation
        # fails as it might already exist or be created by another instance

def embed(text):
    """Generate an embedding for the provided text via Bedrock."""
    logger.info(
        "Generating embedding: model=%s, text_length=%d",
        EMBED_MODEL_ID,
        len(text),
    )
    try:
        body = json.dumps({"inputText": text})
        resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID, body=body)
        payload = json.loads(resp['body'].read())
        embedding = payload["embedding"]
        logger.info(
            "Successfully generated embedding: dimension=%d", len(embedding)
        )
        return embedding
    except Exception as e:
        logger.error("Embedding failed: %s - %s", type(e).__name__, str(e))
        raise

def search(vec, k=5):
    """Perform a kNN vector search in OpenSearch."""
    logger.info(
        "Searching OpenSearch: index=%s, k=%d, vector_dim=%d",
        INDEX,
        k,
        len(vec),
    )
    query = {
      "knn": {
        "embedding": {
          "vector": vec,
          "k": k
        }
      }
    }
    res = os_client.search(index=INDEX, body={"size": k, "query": query})
    hits = res.get("hits", {}).get("hits", [])
    total_field = res.get("hits", {}).get("total")
    total_hits = (
        total_field.get("value") if isinstance(total_field, dict) else total_field
    )
    sources = [
        h["_source"].get("s3_key") or h["_source"].get("source") for h in hits
    ]
    logger.info(
        "Search completed: total_hits=%s, returned=%d, sources=%s",
        total_hits,
        len(hits),
        sources,
    )
    return [
        {
            "text": h.get("_source", {}).get("chunk_text", ""),
            "source": (
                h.get("_source", {}).get("s3_key")
                or h.get("_source", {}).get("source")
            ),
            "score": h.get("_score"),
        }
        for h in hits
    ]

def answer_with_context(question, contexts):
    """Generate an answer using retrieved contexts via Bedrock."""
    # Use inference profile ID if available, otherwise fall back to model ID
    model_id_to_use = GEN_INFERENCE_PROFILE_ID if GEN_INFERENCE_PROFILE_ID else GEN_MODEL_ID
    logger.info(
        (
            "Generating answer: model=%s, question_length=%d, "
            "context_count=%d"
        ),
        model_id_to_use,
        len(question),
        len(contexts),
    )
    system = (
      "You are an AWS tutor. Only answer using the provided Context. "
      "If the Context is insufficient or off-topic, say you don't know. "
      "Always include citations as [Snippet N] where N matches the provided snippets. "
      "Never use external knowledge."
    )
    context_blob = "\n\n".join(
        [f"Snippet {i+1}:\n{c['text']}" for i, c in enumerate(contexts)]
    )

    prompt = f"{system}\n\nQuestion:\n{question}\n\nContext:\n{context_blob}\n\nAnswer:"
    # Build request body - Anthropic requires anthropic_version field
    request_body = {
      "messages": [{"role":"user","content":[{"type":"text","text":prompt}]}],
      "max_tokens": 500
    }
    # Add anthropic_version for Anthropic models
    if "anthropic" in model_id_to_use.lower():
        request_body["anthropic_version"] = "bedrock-2023-05-31"
    body = json.dumps(request_body)
    try:
        # Use inference profile ID if available (required for on-demand models),
        # otherwise use the direct model ID
        resp = bedrock.invoke_model(modelId=model_id_to_use, body=body)
        payload = json.loads(resp['body'].read())
        # Parse response based on model type, guard against missing keys
        answer = None
        if "anthropic" in model_id_to_use.lower():
            content = payload.get("content") or []
            if content and isinstance(content, list) and "text" in content[0]:
                answer = content[0]["text"]
        else:
            output = payload.get("output") or []
            if (
                output and isinstance(output, list)
                and output[0].get("content")
                and isinstance(output[0]["content"], list)
                and output[0]["content"][0].get("text") is not None
            ):
                answer = output[0]["content"][0]["text"]
        if answer is None:
            raise ValueError("Unexpected model response format")
        logger.info("Successfully generated answer: answer_length=%d", len(answer))
        return answer
    except Exception as e:
        logger.error("Answer generation failed: %s - %s", type(e).__name__, str(e))
        raise

def handler(event, ctx):
    """AWS Lambda handler for query answering over vector search."""
    # Install buffered logging per invocation
    root_logger = logging.getLogger()
    for h in list(root_logger.handlers):
        root_logger.removeHandler(h)
    buf_handler = BufferedLogHandler()
    root_logger.addHandler(buf_handler)
    root_logger.setLevel(getattr(logging, log_level, logging.INFO))

    logger.info("Lambda invocation started for query processing")

    try:
        # Ensure the index exists before processing queries
        ensure_index_exists()

        # Handle CORS preflight for HTTP API v2
        method = (event.get("requestContext", {}).get("http", {}) or {}).get("method", "").upper()
        if method == "OPTIONS":
            return {"statusCode": 204, "headers": CORS_HEADERS, "body": ""}

        body = json.loads(event.get("body") or "{}")
        question = body.get("question", "").strip()
        # Basic input limit to avoid excessive embedding payloads
        if len(question) > 4000:
            question = question[:4000]
        if not question:
            logger.error(
                "Validation failed: question is required but was empty or missing"
            )
            return _response(400, {"error": "question required"})

        logger.info(
            "Query received: question='%s...' (length=%d)", question[:100], len(question)
        )

        qvec = embed(question)
        logger.info("Question embedding generation complete")

        contexts = search(qvec, k=5)
        logger.info("Search completed: found %d contexts", len(contexts))

        answer = answer_with_context(question, contexts)
        logger.info("Answer generation complete")

        logger.info("Lambda invocation completed successfully")
        return _response(200, {
            "answer": answer,
            "sources": [
                {"snippet_index": i + 1, **c} for i, c in enumerate(contexts)
            ],
        })
    except Exception as e:
        logger.error("Unhandled error: %s - %s", type(e).__name__, str(e))
        # If DEBUG_PUBLIC_ERRORS is set, include a summarized error for quicker troubleshooting
        if os.environ.get("DEBUG_PUBLIC_ERRORS", "false").lower() in ("1", "true", "yes"): 
            try:
                return _response(500, {
                    "error": "internal_error",
                    "error_type": type(e).__name__,
                    "message": str(e)[:500]
                })
            except Exception:
                pass
        return _response(500, {"error": "internal_error"})
    finally:
        # Emit the buffered logs as a single CloudWatch event
        try:
            combined = buf_handler.get_value()
            if combined:
                print(combined)
        except Exception:
            pass
