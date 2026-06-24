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


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    logger.info("Gateway invoked.")

    # The caller's request arrives as a JSON string in the HTTP body.
    try:
        data = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Body must be valid JSON."})

    prompt = data.get("prompt", "")
    if not prompt:
        return _response(400, {"error": "Missing 'prompt' in request body."})

    logger.info("Received a prompt of length %d.", len(prompt))

    # Call the model THROUGH the guardrail: Bedrock checks the input,
    # runs Claude, then checks the output — all in this one call.
    try:
        result = bedrock.converse(
            modelId=MODEL_ID,
            messages=[
                {"role": "user", "content": [{"text": prompt}]}
            ],
            guardrailConfig={
                "guardrailIdentifier": GUARDRAIL_ID,
                "guardrailVersion": GUARDRAIL_VERSION,
            },
        )
    except Exception:
        logger.exception("Bedrock call failed.")
        return _response(502, {"error": "Upstream model error."})

    # Whatever text came back (the answer, OR the guardrail's block message).
    answer = result["output"]["message"]["content"][0]["text"]

    # Did the guardrail step in?
    if result.get("stopReason") == "guardrail_intervened":
        logger.warning("Guardrail blocked this request.")
        return _response(200, {"status": "blocked", "message": answer})

    logger.info("Returning an answer of length %d.", len(answer))
    return _response(200, {"status": "ok", "answer": answer})
