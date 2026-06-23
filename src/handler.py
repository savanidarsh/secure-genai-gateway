import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    logger.info("Gateway invoked.")

    # Pull the user's prompt out of the incoming request.
    prompt = event.get("prompt", "")

    # Phase 3 is just the skeleton: we acknowledge the request.
    # Inspection (injection/PII/toxicity) and Bedrock come in later phases.
    logger.info("Received a prompt of length %d.", len(prompt))

    body = {
        "status": "ok",
        "message": "Gateway received your request.",
        "prompt_length": len(prompt),
    }

    return {
        "statusCode": 200,
        "body": json.dumps(body),
    }
