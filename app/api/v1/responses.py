"""
Responses API 路由 - 兼容 OpenAI /v1/responses
"""

from typing import Any, Dict, List, Optional, Union

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel, Field, field_validator

from app.core.auth import verify_api_key
from app.services.grok.chat import ChatService
from app.services.grok.model import ModelService
from app.core.exceptions import ValidationException
from app.services.quota import enforce_daily_quota


router = APIRouter(tags=["Responses"])


VALID_ROLES = ["developer", "system", "user", "assistant"]


class ResponseInputItem(BaseModel):
    """Responses API input message item"""
    role: str
    content: Union[str, List[Dict[str, Any]]]

    @field_validator("role")
    @classmethod
    def validate_role(cls, v):
        if v not in VALID_ROLES:
            raise ValueError(f"role must be one of {VALID_ROLES}")
        return v


class ResponseRequest(BaseModel):
    """Responses API request body"""
    model: str = Field(..., description="Model name")
    input: Union[str, List[ResponseInputItem]] = Field(..., description="Input messages or string prompt")
    stream: Optional[bool] = Field(None, description="Enable streaming")
    instructions: Optional[str] = Field(None, description="System instructions (prepended as system message)")

    model_config = {
        "extra": "ignore"
    }


def _convert_input_to_messages(request: ResponseRequest) -> List[Dict[str, Any]]:
    """
    Convert Responses API input format to Chat Completions messages format.

    - string input -> single user message
    - list input -> convert each ResponseInputItem to message dict
    - if instructions present, prepend as system message
    """
    messages = []

    # Prepend system instructions if provided
    if request.instructions:
        messages.append({"role": "system", "content": request.instructions})

    if isinstance(request.input, str):
        # Simple string prompt
        messages.append({"role": "user", "content": request.input})
    else:
        # List of message items
        for item in request.input:
            messages.append(item.model_dump())

    return messages


def validate_response_request(request: ResponseRequest):
    """Validate request parameters"""
    # Validate model
    if not ModelService.valid(request.model):
        raise ValidationException(
            message=f"The model `{request.model}` does not exist or you do not have access to it.",
            param="model",
            code="model_not_found"
        )

    # Validate input
    if isinstance(request.input, str):
        if not request.input.strip():
            raise ValidationException(
                message="Input cannot be empty",
                param="input",
                code="empty_input"
            )
    elif isinstance(request.input, list):
        if not request.input:
            raise ValidationException(
                message="Input cannot be an empty array",
                param="input",
                code="empty_input"
            )


@router.post("/responses")
async def create_response(request: ResponseRequest, api_key: Optional[str] = Depends(verify_api_key)):
    """Responses API - OpenAI compatible"""

    # Validate
    validate_response_request(request)

    # Daily quota (best-effort)
    await enforce_daily_quota(api_key, request.model)

    # Convert input to messages format
    messages = _convert_input_to_messages(request)

    is_stream = request.stream if request.stream is not None else False

    # Detect video model
    model_info = ModelService.get(request.model)
    if model_info and model_info.is_video:
        from app.services.grok.media import VideoService

        result = await VideoService.completions(
            model=request.model,
            messages=messages,
            stream=is_stream,
            thinking=None
        )
    else:
        result = await ChatService.completions(
            model=request.model,
            messages=messages,
            stream=is_stream,
            thinking=None
        )

    if isinstance(result, dict):
        # Non-streaming: convert chat.completion to response format
        from app.services.grok.processor import ResponsesCollectFormatter
        formatted = ResponsesCollectFormatter.format(result, request.model)
        return JSONResponse(content=formatted)
    else:
        # Streaming: wrap the chat SSE stream into responses SSE format
        from app.services.grok.processor import ResponsesStreamFormatter
        formatter = ResponsesStreamFormatter(request.model)
        return StreamingResponse(
            formatter.format(result),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "Connection": "keep-alive"}
        )


__all__ = ["router"]
