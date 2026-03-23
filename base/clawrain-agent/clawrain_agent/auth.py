"""API key authentication middleware."""
from fastapi import Request, HTTPException


class AgentAuth:
    def __init__(self, api_key: str):
        self.api_key = api_key

    async def __call__(self, request: Request):
        # Allow /health without auth (for uptime monitors)
        if request.url.path == "/health":
            return

        key = request.headers.get("x-agent-key") or ""
        if not key:
            # Also accept Bearer token
            auth = request.headers.get("authorization") or ""
            if auth.startswith("Bearer "):
                key = auth[7:]

        if key != self.api_key:
            raise HTTPException(status_code=401, detail="Invalid or missing API key")
