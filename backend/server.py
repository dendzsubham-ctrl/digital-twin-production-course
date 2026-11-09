

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict
import json
import uuid
from datetime import datetime
import boto3
from botocore.exceptions import ClientError
from context import prompt

# Load environment variables
load_dotenv()

app = FastAPI()

# --------------------------------------------------
# Configure CORS
# --------------------------------------------------

cors_origins_env = os.getenv(
    "CORS_ORIGINS",
    "http://localhost:3000"
)

origins = [
    origin.strip().rstrip("/")
    for origin in cors_origins_env.split(",")
    if origin.strip()
]

# Diagnostic logging for AWS CloudWatch
print("CORS_ORIGINS from Lambda:", repr(cors_origins_env))
print("Parsed allowed origins:", repr(origins))

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# --------------------------------------------------
# Initialize AWS Bedrock client
# --------------------------------------------------

AWS_REGION = os.getenv(
    "DEFAULT_AWS_REGION",
    "ap-southeast-2"
)

bedrock_client = boto3.client(
    service_name="bedrock-runtime",
    region_name=AWS_REGION
)

# Bedrock model selection
BEDROCK_MODEL_ID = os.getenv(
    "BEDROCK_MODEL_ID",
    "global.amazon.nova-2-lite-v1:0"
)

print("Bedrock region:", AWS_REGION)
print("Bedrock model:", BEDROCK_MODEL_ID)

# --------------------------------------------------
# Memory storage configuration
# --------------------------------------------------

USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

# Initialize S3 client if needed
if USE_S3:
    s3_client = boto3.client(
        "s3",
        region_name=AWS_REGION
    )

# --------------------------------------------------
# Request and response models
# --------------------------------------------------

class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


class Message(BaseModel):
    role: str
    content: str
    timestamp: str


# --------------------------------------------------
# Memory management functions
# --------------------------------------------------

def get_memory_path(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """Load conversation history from storage"""

    if USE_S3:
        try:
            response = s3_client.get_object(
                Bucket=S3_BUCKET,
                Key=get_memory_path(session_id)
            )

            return json.loads(
                response["Body"].read().decode("utf-8")
            )

        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise

    else:
        file_path = os.path.join(
            MEMORY_DIR,
            get_memory_path(session_id)
        )

        if os.path.exists(file_path):
            with open(file_path, "r", encoding="utf-8") as f:
                return json.load(f)

        return []


def save_conversation(
    session_id: str,
    messages: List[Dict]
):
    """Save conversation history to storage"""

    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )

    else:
        os.makedirs(MEMORY_DIR, exist_ok=True)

        file_path = os.path.join(
            MEMORY_DIR,
            get_memory_path(session_id)
        )

        with open(file_path, "w", encoding="utf-8") as f:
            json.dump(messages, f, indent=2)


# --------------------------------------------------
# AWS Bedrock inference
# --------------------------------------------------

def call_bedrock(
    conversation: List[Dict],
    user_message: str
) -> str:
    """Call Amazon Bedrock using conversation history"""

    # Build conversation messages in Bedrock format
    messages = []

    # Add previous conversation history
    for msg in conversation[-10:]:

        if msg.get("role") not in ["user", "assistant"]:
            continue

        if not msg.get("content"):
            continue

        messages.append({
            "role": msg["role"],
            "content": [
                {"text": msg["content"]}
            ]
        })

    # Add current user message
    messages.append({
        "role": "user",
        "content": [
            {"text": user_message}
        ]
    })

    try:
        # Call Bedrock using the Converse API
        response = bedrock_client.converse(
            modelId=BEDROCK_MODEL_ID,

            # System instructions/personality
            system=[
                {"text": prompt()}
            ],

            # Conversation history and current message
            messages=messages,

            # Model inference parameters
            inferenceConfig={
                "maxTokens": 2000,
                "temperature": 0.7,
                "topP": 0.9
            }
        )

        # Extract generated response
        content_blocks = response["output"]["message"]["content"]

        assistant_response = next(
            (
                block["text"]
                for block in content_blocks
                if "text" in block
            ),
            None
        )

        if assistant_response is None:
            raise ValueError("Bedrock returned an empty response.")

        return assistant_response

    except ClientError as e:

        error_code = e.response["Error"]["Code"]

        print(f"Bedrock error ({error_code}): {str(e)}")

        if error_code == "ValidationException":
            raise HTTPException(
                status_code=400,
                detail="Invalid request format for Bedrock."
            )

        elif error_code == "AccessDeniedException":
            raise HTTPException(
                status_code=403,
                detail="Access denied to Amazon Bedrock. Check IAM permissions and model access."
            )

        elif error_code == "ResourceNotFoundException":
            raise HTTPException(
                status_code=404,
                detail="Bedrock model or inference profile was not found."
            )

        else:
            raise HTTPException(
                status_code=502,
                detail="Amazon Bedrock inference failed."
            )


# --------------------------------------------------
# API endpoints
# --------------------------------------------------

@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API (Powered by Amazon Bedrock)",
        "memory_enabled": True,
        "storage": "S3" if USE_S3 else "local",
        "ai_model": BEDROCK_MODEL_ID
    }


@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "use_s3": USE_S3,
        "bedrock_model": BEDROCK_MODEL_ID
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):

    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Call Bedrock for response
        assistant_response = call_bedrock(
            conversation,
            request.message
        )

        # Update conversation history
        conversation.append({
            "role": "user",
            "content": request.message,
            "timestamp": datetime.now().isoformat()
        })

        conversation.append({
            "role": "assistant",
            "content": assistant_response,
            "timestamp": datetime.now().isoformat()
        })

        # Save conversation
        save_conversation(session_id, conversation)

        return ChatResponse(
            response=assistant_response,
            session_id=session_id
        )

    except HTTPException:
        raise

    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}")

        raise HTTPException(
            status_code=500,
            detail="An internal server error occurred."
        )


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    """Retrieve conversation history"""

    try:
        conversation = load_conversation(session_id)

        return {
            "session_id": session_id,
            "messages": conversation
        }

    except Exception as e:
        print(f"Error retrieving conversation: {str(e)}")

        raise HTTPException(
            status_code=500,
            detail="Could not retrieve conversation history."
        )


# --------------------------------------------------
# Local development
# --------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000
    )
