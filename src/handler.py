import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Build the Bedrock client once (reused across calls = faster + cheaper).
bedrock = boto3.client("bedrock-runtime")

# Config handed in by Terraform via environment variables.
MODEL_ID = os.environ["MODEL_ID"]
GUARDRAIL_ID = os.environ["GUARDRAIL_ID"]
GUARDRAIL_VERSION = os.environ["GUARDRAIL_VERSION"]


def _log(event_type, request_id, **fields):
    """Emit ONE structured JSON line. Metadata only — never the prompt text."""
    logger.info(json.dumps(
        {"event": event_type, "request_id": request_id, **fields}))


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    request_id = context.aws_request_id

    try:
        data = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        _log("BAD_REQUEST", request_id, reason="invalid_json")
        return _response(400, {"error": "Body must be valid JSON."})

    prompt = data.get("prompt", "")
    if not prompt:
        _log("BAD_REQUEST", request_id, reason="missing_prompt")
        return _response(400, {"error": "Missing 'prompt' in request body."})

    _log("REQUEST", request_id, prompt_length=len(prompt))

    try:
        result = bedrock.converse(
            modelId=MODEL_ID,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            guardrailConfig={
                "guardrailIdentifier": GUARDRAIL_ID,
                "guardrailVersion": GUARDRAIL_VERSION,
            },
        )
    except Exception:
        logger.exception("Bedrock call failed.")
        _log("UPSTREAM_ERROR", request_id)
        return _response(502, {"error": "Upstream model error."})

    answer = result["output"]["message"]["content"][0]["text"]

    if result.get("stopReason") == "guardrail_intervened":
        _log("GUARDRAIL_BLOCK", request_id, prompt_length=len(prompt))
        return _response(200, {"status": "blocked", "message": answer})

    usage = result.get("usage", {})
    _log("ANSWER", request_id,
         answer_length=len(answer),
         input_tokens=usage.get("inputTokens"),
         output_tokens=usage.get("outputTokens"),
         total_tokens=usage.get("totalTokens"))
    return _response(200, {"status": "ok", "answer": answer})
