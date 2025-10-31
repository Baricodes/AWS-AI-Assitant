"""Document ingestion Lambda: chunks text, embeds via Bedrock, indexes to OpenSearch."""

import hashlib
import json
import logging
import os
import textwrap

import boto3
from botocore.exceptions import ClientError
from opensearchpy import OpenSearch, RequestsHttpConnection

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
            pass

    def get_value(self):
        return "\n".join(self._records)

logger = logging.getLogger(__name__)

BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")
EMBED_MODEL_ID = os.environ.get(
    "EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0"
)
# e.g., https://<id>.<region>.aoss.amazonaws.com
OPENSEARCH_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]
OPENSEARCH_INDEX = os.environ.get("OPENSEARCH_INDEX", "kb_chunks")

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

# For serverless auth, use SigV4 via boto credentials; opensearch-py supports
# that via AWSV4SignerAuth in aws-requests-auth.
from requests_aws4auth import AWS4Auth

session = boto3.Session()
credentials = session.get_credentials()
awsauth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    BEDROCK_REGION,
    "aoss",
    session_token=credentials.token,
)

os_client = OpenSearch(
    hosts=[{"host": OPENSEARCH_ENDPOINT.replace("https://", ""), "port": 443}],
    http_auth=awsauth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection,
)

def ensure_index_exists():
    """Create the vector index if it doesn't exist."""
    try:
        if os_client.indices.exists(index=OPENSEARCH_INDEX):
            logger.info("Index %s already exists", OPENSEARCH_INDEX)
            return
        
        logger.info("Creating index %s", OPENSEARCH_INDEX)
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
        
        os_client.indices.create(index=OPENSEARCH_INDEX, body=index_config)
        logger.info("Successfully created index %s", OPENSEARCH_INDEX)
        
    except Exception as e:
        logger.error("Error ensuring index exists: %s", str(e))
        # Don't raise the error - the Lambda should continue even if index creation
        # fails as it might already exist or be created by another instance

def chunk_text(text, max_len=1200):
    """Simple character-based chunker."""
    chunks = textwrap.wrap(text, max_len)
    logger.debug(
        "Chunked text: input length=%d, chunks=%d, max_len=%d",
        len(text),
        len(chunks),
        max_len,
    )
    return chunks

def embed(text, dimensions=None, normalize=None, model_id=None):
    """Return embedding (list of floats) for text.

    dimensions: Optional override for output dims (e.g., 256/512/1024).
    normalize: Optional normalization flag.
    model_id: Optional model override.
    """
    model_id = model_id or EMBED_MODEL_ID

    logger.info(
        (
            "Invoking Bedrock runtime for embedding: model=%s, region=%s, "
            "text_length=%d, dimensions=%s, normalize=%s"
        ),
        model_id,
        BEDROCK_REGION,
        len(text),
        str(dimensions),
        str(normalize),
    )

    native_request = {"inputText": text}
    if dimensions is not None:
        native_request["dimensions"] = int(dimensions)
    if normalize is not None:
        native_request["normalize"] = bool(normalize)

    body = json.dumps(native_request)

    try:
        # include contentType/accept if you want explicit headers
        resp = bedrock.invoke_model(modelId=model_id, body=body)
        raw = resp["body"].read()
        payload = json.loads(raw)
        if "embedding" in payload:
            embedding = payload["embedding"]
            logger.info(
                "Successfully generated embedding: dimension=%d", len(embedding)
            )
            return embedding
        # defensive: some models use different keys or nested outputs
        if "outputs" in payload and isinstance(payload["outputs"], list):
            # try to find embedding in outputs
            for output_item in payload["outputs"]:
                if isinstance(output_item, dict) and "embedding" in output_item:
                    embedding = output_item["embedding"]
                    logger.info(
                        (
                            "Successfully generated embedding from outputs: "
                            "dimension=%d"
                        ),
                        len(embedding),
                    )
                    return embedding
        error_msg = (
            "No 'embedding' found in model response: "
            + json.dumps(payload)[:1000]
        )
        logger.error(error_msg)
        raise RuntimeError(error_msg)
    except ClientError as e:
        # give the caller maximum useful info without leaking creds
        error_info = e.response.get("Error", {})
        logger.error("Bedrock invoke_model ClientError: %s", error_info)
        raise
    except Exception as e:
        logger.error("Embed failed: %s - %s", type(e).__name__, str(e))
        raise

def index_chunk(doc_id, chunk_id, chunk_text_value, vec, meta):
    """Index a single chunk into OpenSearch."""
    logger.debug(
        (
            "Indexing chunk: doc_id=%s, chunk_id=%s, text_length=%d, "
            "embedding_dim=%d"
        ),
        doc_id,
        str(chunk_id),
        len(chunk_text_value),
        len(vec),
    )
    body = {
        "doc_id": doc_id,
        "chunk_id": chunk_id,
        "chunk_text": chunk_text_value,
        "embedding": vec,
        **meta,
    }
    # doc_id and chunk_id are in the body, so we can query by those fields
    os_client.index(index=OPENSEARCH_INDEX, body=body)
    logger.info(
        "Successfully indexed chunk: doc_id=%s, chunk_id=%s", doc_id, str(chunk_id)
    )

def handler(event, context):
    """AWS Lambda handler for ingesting S3 documents into OpenSearch."""
    # Install buffered logging per invocation
    root_logger = logging.getLogger()
    for h in list(root_logger.handlers):
        root_logger.removeHandler(h)
    buf_handler = BufferedLogHandler()
    root_logger.addHandler(buf_handler)
    root_logger.setLevel(getattr(logging, log_level, logging.INFO))

    logger.info(
        "Lambda invocation started: record_count=%d",
        len(event.get("Records", [])),
    )

    try:
        # Ensure the index exists before processing documents
        ensure_index_exists()

        # Expect event from S3 put trigger
        records = event.get("Records", [])
        for record_idx, record in enumerate(records):
            bucket = record["s3"]["bucket"]["name"]
            key = record["s3"]["object"]["key"]
            logger.info(
                "Processing S3 record %d/%d: bucket=%s, key=%s",
                record_idx + 1,
                len(records),
                bucket,
                key,
            )

            obj = s3.get_object(Bucket=bucket, Key=key)
            text = obj["Body"].read().decode("utf-8", errors="ignore")
            logger.info("Document loaded: key=%s, text_size=%d bytes", key, len(text))

            doc_id = hashlib.md5(key.encode()).hexdigest()
            logger.debug("Generated doc_id: %s for key: %s", doc_id, key)
            meta = {"source": "s3", "s3_key": key}

            chunks = chunk_text(text)
            logger.info(
                "Chunking complete: doc_id=%s, total_chunks=%d", doc_id, len(chunks)
            )

            for i, chunk_text_value in enumerate(chunks):
                logger.info(
                    "Processing chunk %d/%d for doc_id=%s", i + 1, len(chunks), doc_id
                )
                vec = embed(chunk_text_value)
                index_chunk(doc_id, i, chunk_text_value, vec, meta)

            logger.info(
                "Successfully processed document: doc_id=%s, chunks_indexed=%d",
                doc_id,
                len(chunks),
            )

        logger.info("Lambda invocation completed successfully")
        return {"ok": True}
    finally:
        try:
            combined = buf_handler.get_value()
            if combined:
                print(combined)
        except Exception:
            pass
