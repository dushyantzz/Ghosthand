# OpenJev "oneshot JSON" Implementation

### Reference Repositories:
- **SiliconLabAI/OpenJev** (The repository this JSON logic is based on): https://github.com/SiliconLabAI/OpenJev
- **razorback16/openjev** (The heavy vLLM python repository): https://github.com/razorback16/openjev

---

### Our Implementation (Groq API + JSON Structured Outputs)
**API Provider:** Groq
**Base URL:** `https://api.groq.com/openai/v1/chat/completions`
**Model Name:** `qwen/qwen3.8-27b`

Here is the exact Python logic we injected into `main.py` to create a hallucination-free, high-speed decision engine using the SiliconLabAI methodology:

```python
import httpx
import logging
from typing import Optional

logger = logging.getLogger(__name__)

async def _route_with_openjev(prompt: str, evidence: str, groq_api_key: str, router_timeout_s: float, router_system_prompt: str, jev_criteria: str) -> Optional[str]:
    """Hosted OpenJev on Groq (using JSON structured outputs to prevent hallucination)"""
    
    if not groq_api_key:
        logger.warning("[Router] OpenJev selected but GROQ_API_KEY is not set.")
        return None
        
    # Append the strict JSON instruction to the system prompt
    system_prompt = f"{router_system_prompt}\n{jev_criteria}\n\nYou MUST respond with a valid JSON object containing exactly one key 'intent' whose value is exactly one of the allowed categories."
    
    # Truncate evidence to 4000 chars for safety/speed
    short_evidence = (evidence or "")[:4000] 
    user_content = f"{short_evidence}\nUser Message: {prompt}" if short_evidence else prompt
    
    # ---------------------------------------------------------
    # HARDCODED FAST-PATHS
    # Instantly intercepts known edge-cases 
    # ---------------------------------------------------------
    prompt_lower, evidence_lower = prompt.lower(), (evidence or "").lower()
    
    for name in ("github", "slack"):
        if name in prompt_lower and name in evidence_lower:
            return "CHAT"
            
    for name in ("bluetooth", "wifi", "volume", "brightness"):
        if name in prompt_lower:
            return "COMPUTER_USE"
    # ---------------------------------------------------------

    # The Groq JSON Payload
    payload = {
        "model": "qwen/qwen3.8-27b",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content}
        ],
        "temperature": 0.0,
        "response_format": {"type": "json_object"}
    }
    
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.groq.com/openai/v1/chat/completions",
                headers={"Authorization": f"Bearer {groq_api_key}"},
                json=payload,
                timeout=router_timeout_s
            )
            resp.raise_for_status()
            result = resp.json()
            answer_text = result["choices"][0]["message"]["content"]
            
            # Parse the strict JSON output
            try:
                import json
                answer = json.loads(answer_text).get("intent", "")
            except Exception:
                answer = answer_text
                
            return _normalize_intent(answer)
            
    except Exception as err:
        logger.warning(f"[Router] OpenJev on Groq failed ({type(err).__name__}: {err}) — falling back")
        return None
```
